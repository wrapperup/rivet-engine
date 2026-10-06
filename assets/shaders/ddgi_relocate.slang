// DDGI, derived from:
//
// Majercik, Guertin, Nowrouzezahrai, McGuire. "Dynamic Diffuse Global Illumination with Ray-Traced
// Irradiance Fields". https://jcgt.org/published/0008/02/01/
// Majercik, Marrs, Spjut, McGuire. "Scaling Probe-Based Real-Time Dynamic Global Illumination for
// Production". https://jcgt.org/published/0010/02/01/
//
// Original source code: (https://jcgt.org/published/0010/02/01/supplement.zip)

import bindless;
import common;
import types;
import ddgi_common;

[vk_push_constant]
DDGIRelocatePush pc;

// DDGIVolume_computeProbeOffsets
[numthreads(64, 1, 1)]
[shader("compute")]
void compute_main(uint3 dispatch_id: SV_DispatchThreadID) {
  DDGIVolume ddgi_volume = pc.volume[0];

  int probe_idx = int(dispatch_id.x);
  if (probe_idx >= ddgi_num_probes(ddgi_volume)) {
    return;
  }

  int2 C = ddgi_probe_tile(ddgi_volume, ddgi_probe_index_to_grid_coord(ddgi_volume, probe_idx));

  Vec4 current_offset = bool(pc.first_frame)
      ? Vec4(Vec3(0), STATE_UNINITIALIZED) // Probes start uninitialized.
      : pc.probe_data.load(C);

  float inf = asfloat(0x7F800000u);

  int closest_backface_index = -1;
  float closest_backface_distance = inf;

  int closest_frontface_index = -1;
  float closest_frontface_distance = inf;

  int farthest_frontface_index = -1;
  float farthest_frontface_distance = 0;

  int backface_count = 0;

  // Worst case, view and normal contribute in the same direction, so need 2x self-shadow bias.
  Vec3 outer_bounds = normalize(ddgi_volume.probe_spacing) * (length(ddgi_volume.probe_spacing) + (2.0f * ddgi_volume.normal_bias));
  int flag = int(current_offset.w); // Assume normal probe: initially awake, not sleepless or tombstoned.

  if (flag == STATE_OFF) {
    // These rays were not traced.
    return;
  }
  // Deviation: on first_frame, probes that were off weren't traced this frame either, so this iteration
  // reads their previous rays.

  for (int i = 0; i < ddgi_volume.rays_per_probe; ++i) {
    // Distance is negative if we hit a backface
    float d_front = pc.radiance[probe_idx * ddgi_volume.rays_per_probe + i].w;
    float d_back = -d_front;

    //Backface test backface -> position.w < 0.0f
    if (d_back > 0.0f) {
      backface_count += 1;
      if (d_back < closest_backface_distance) {
        // This distance is negative on a backface hit
        closest_backface_distance = d_back;
        // Recompute ray direction
        closest_backface_index = i;
      }
    }

    if (d_front > 0.0f) {
      // Need to check all frontfaces to see if any are wihtin shading range.
      Vec3 front_face_direction = d_front * normalize(ddgi_ray_direction(ddgi_volume, i));
      if (all(abs(front_face_direction) < outer_bounds)) {
        // There is a static surface being shaded by this probe. Make it "just vigilant".
        flag = STATE_JUST_VIGILANT;
      }
      if (d_front < closest_frontface_distance) {
        closest_frontface_distance = d_front;
        closest_frontface_index = i;
      } else if (d_front > farthest_frontface_distance) {
        farthest_frontface_distance = d_front;
        farthest_frontface_index = i;
      }
    }
  }

  Vec3 full_offset = Vec3(inf);
  Vec3 offset_limit = ddgi_volume.relocation_max * ddgi_volume.probe_spacing;

  // If there's a close backface AND you see more than 25% backfaces, assume you're inside something.
  if (closest_backface_index != -1 && (float(backface_count) / ddgi_volume.rays_per_probe) > 0.25f) {
    // At this point, we were just in a wall, so set probe to "Off".
    flag = STATE_OFF;
    // We hit a backface
    Vec3 closest_backface_direction = closest_backface_distance * normalize(ddgi_ray_direction(ddgi_volume, closest_backface_index));

    // Solve for the maximum scaling possible on each axis.
    Vec3 positive_offset = (-current_offset.xyz + offset_limit) / closest_backface_direction;
    Vec3 negative_offset = (-current_offset.xyz - offset_limit) / closest_backface_direction;
    Vec3 combined_offset = Vec3(max(positive_offset.x, negative_offset.x), max(positive_offset.y, negative_offset.y), max(positive_offset.z, negative_offset.z));

    // Slightly bias this point to ensure we stay within bounds.
    const float epsilon = 1e-3; // Millimeter scale
    float scale_factor = (min(min(combined_offset.x, combined_offset.y), combined_offset.z) - epsilon);

    // If we can't move through the backface, don't move at all.
    full_offset = current_offset.xyz + closest_backface_direction * ((scale_factor <= 1.0f) ? 0.0f : scale_factor);
  }
  else if (closest_frontface_index == -1) {
    // Probe sees only backfaces and sky, so set probe to "Off".
    flag = STATE_OFF;
  }
  else if (closest_frontface_distance < 0.05f) {
    // We hit no backfaces and a close frontface (within 2 cm). Set to "Newly Vigilant".
    flag = STATE_JUST_VIGILANT;

    // Ensure that we never move through the farthest frontface
    // Move minimum distance to ensure not moving on a future iteration.
    Vec3 farthest_direction = min(0.2f, farthest_frontface_distance) * normalize(ddgi_ray_direction(ddgi_volume, farthest_frontface_index));

    // The farthest frontface may also be the closest if the probe can only
    // see one surface. If this is the case, don't move the probe.
    if (!(dot(farthest_direction, ddgi_ray_direction(ddgi_volume, closest_frontface_index)) > 0.5f)) {
      full_offset = current_offset.xyz + farthest_direction;
    }
  }

  // If we are adjusting offsets, add the offset.
  // Otherwise, just record the flag below.
  if (bool(pc.adjust_offsets)) {
    // Absolute maximum distance probe could be moved is 0.5 * probeSpacing
    // Clamp maximum distance we're willing to move to ddgiVolume.probeOffsetLimit to avoid degenerate cases.
    if (all(abs(full_offset) < offset_limit)) {
      // We are going to move, and therefore should be uninitialized
      flag = STATE_UNINITIALIZED;
      current_offset.xyz = full_offset;
    }
  } else {
    if (flag == STATE_UNINITIALIZED) {
      // Probe is still uninitialized: all flag setting
      // conditions failed, probe should sleep.
      // Deviation: there is no sleeping, so the probe wakes instead.
      flag = STATE_JUST_WOKE;
    }
  }

  current_offset.w = flag;
  pc.probe_data.store(C, current_offset);
}
