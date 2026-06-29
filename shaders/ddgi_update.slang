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
DDGIUpdatePush pc;

static const int RAYS_PER_PROBE = 192;
static const int BLOCK_SIZE = 64;

static const int IRRADIANCE_BLOCKS = (square_i(DDGI_IRRADIANCE_PROBE_SIDE_LENGTH) + BLOCK_SIZE - 1) / BLOCK_SIZE;

groupshared Vec4 ray_irradiance_and_dist[RAYS_PER_PROBE];
groupshared Vec4 ray_direction[RAYS_PER_PROBE];

static const int batch_size = RAYS_PER_PROBE / BLOCK_SIZE;

int square_i(int x) {
  return x * x;
}

// DDGIVolume_updateProbes.glc
[numthreads(BLOCK_SIZE, 1, 1)]
[shader("compute")]
void compute_main(uint3 group_id: SV_GroupID, uint3 local_invocation_id: SV_GroupThreadID) {
  DDGIVolume ddgi_volume = pc.volume[0];

  float max_distance = ddgi_volume.max_distance;
  const float visibility_sharpness = 50.0;
  float irradiance_hysteresis = ddgi_volume.hysteresis;
  float visibility_hysteresis = ddgi_volume.hysteresis;

  // blockID.x = probe index
  // blockID.z = texel subset. The first IRRADIANCE_BLOCKS blocks process irradiance texels, the rest visibility texels.
  int3 block_id = int3(group_id.xyz);

  // Probe being processed by this thread (this will be the same across the entire block)
  int probe_index = block_id.x;
  if (probe_index >= ddgi_num_probes(ddgi_volume)) {
    return;
  }

  int2 probe_tile = ddgi_probe_tile(ddgi_volume, ddgi_probe_index_to_grid_coord(ddgi_volume, probe_index));

  Vec4 current_offset = pc.probe_data.load(probe_tile);
  if (int(current_offset.w) == STATE_OFF) {
    return;
  }

  // This thread's linear ID in the block on [0, 63]
  int thread_id = int(local_invocation_id.x);

  // The first thread block process irradiance texels. The others process visibility texels.
  bool irradiance_block = block_id.z < IRRADIANCE_BLOCKS;

  // Set NewlyX probes to their resolved state.
  int flag = int(current_offset.w);
  // Newly X probes. When initializing, any probes in other states will not have had rays generated for them.
  if (int(current_offset.w) == STATE_JUST_WOKE || int(current_offset.w) == STATE_JUST_VIGILANT) {
    current_offset.w = current_offset.w + 1.0f;
  }
  pc.probe_data.store(probe_tile, current_offset);

  // Probes have 1-pix borders on all sides
  int2 corner_texel_coord;

  // Texel relative to the corner of the probe in the final texture.
  // Every thread processes 1 texel. For the irradiance probe, one (64 thread) block exactly
  // processes the whole probe. For the visibility probe, there are four blocks per probe.
  int2 relative_texel_coord;

  // This thread processes a single texel that corresponds to this direction on the sphere
  Vec3 probe_direction;

  int side_length = irradiance_block ? DDGI_IRRADIANCE_PROBE_SIDE_LENGTH : DDGI_VISIBILITY_PROBE_SIDE_LENGTH;

  corner_texel_coord = probe_tile * (side_length + 2) + int2(1, 1);

  // This branch is totally coherent for 8x8 res irradianceProbes
  if (irradiance_block) {
    int texel_index = block_id.z * BLOCK_SIZE + thread_id;
    relative_texel_coord.x = texel_index % DDGI_IRRADIANCE_PROBE_SIDE_LENGTH;
    // With k = 64, blockID.z is always 0
    relative_texel_coord.y = texel_index / DDGI_IRRADIANCE_PROBE_SIDE_LENGTH;
  } else {
    const int i = block_id.z - IRRADIANCE_BLOCKS;
    relative_texel_coord.x = (i * BLOCK_SIZE + thread_id) % DDGI_VISIBILITY_PROBE_SIDE_LENGTH;
    relative_texel_coord.y = (i * BLOCK_SIZE + thread_id) / DDGI_VISIBILITY_PROBE_SIDE_LENGTH;
  }

  probe_direction = ddgi_oct_decode(ddgi_normalized_oct_coord(relative_texel_coord, side_length));

  Vec4 result = Vec4(0);
  int probe_offset_in_absolute_rays = probe_index * RAYS_PER_PROBE;
  for (int batch_index = 0; batch_index < batch_size; ++batch_index) { // (= 4 if k == 64)
    // Read all the rays
    {
      int ray_index = batch_index * BLOCK_SIZE + thread_id;

      // Cooperatively read k hitDistances, and limit them so that they don't blow out
      // the variance on a miss or distant hit. If they are negative, that encodes a
      // backface that should be shortened.
      int offset_idx = probe_offset_in_absolute_rays + ray_index;

      float d = pc.radiance[offset_idx].w;

      // If d is negative [backface], then we preserve the sign of d so that later processing will still know that this
      // was a backface.
      ray_irradiance_and_dist[ray_index] = Vec4(pc.radiance[offset_idx].rgb, min(max_distance, abs(d)) * (d < 0 ? -0.2f : 1.0f));

      // Cooperatively read k ray directions [one read/thread]
      ray_direction[ray_index] = Vec4(ddgi_ray_direction(ddgi_volume, ray_index), 0.0f);

    } // load ray data
  }

  // Wait for all threads to finish shared memory writes.
  GroupMemoryBarrierWithGroupSync();

  // Deviation: threads past the probe's texels only load rays.
  if (relative_texel_coord.y >= side_length) {
    return;
  }

  Vec3 value;

  // Process RAYS_PER_PROBE rays at this pixel across warp
  if (irradiance_block) {
    for (int i = 0; i < RAYS_PER_PROBE; ++i) {
      float weight = max(0, dot(ray_direction[i].xyz, probe_direction));
      value = ray_irradiance_and_dist[i].rgb;
      result += Vec4(value * weight, weight);
    }
  } else {
    for (int i = 0; i < RAYS_PER_PROBE; ++i) {
      float weight = max(0, dot(ray_direction[i].xyz, probe_direction));
      weight = pow(weight, visibility_sharpness);
      // The distance may be negative (encoding a backface)
      // but because it is SQUARED before use, the sign doesn't
      // matter.
      float ray_dist = ray_irradiance_and_dist[i].w;
      value = Vec3(ray_dist, square(ray_dist), 0);
      result += Vec4(value * weight, weight);
    }
  }

  // For both irradiance and depth, one thread processes all rays for a single texel,
  // so we don't need a barrier here.

  // Normalize and avoid division by zero
  const float epsilon = 1e-9 * float(RAYS_PER_PROBE);
  result.xyz *= 1.0 / max(result.w, epsilon);

  float h = irradiance_block ? irradiance_hysteresis : visibility_hysteresis;

  // Hysteresis 0 if just woke or just vigilant
  if (flag == STATE_UNINITIALIZED || flag == STATE_JUST_WOKE || flag == STATE_JUST_VIGILANT) {
    h = 0.0f;
  }

  // If a probe just spawned, clear its old data.
  const Vec3 DEAD_PROBE_VALUE = Vec3(0);
  if (flag == STATE_UNINITIALIZED) {
    result.xyz = DEAD_PROBE_VALUE;
  }

  int2 texel_coord = corner_texel_coord + relative_texel_coord;

  const float significant_change_threshold = 0.25;
  float new_distribution_change_threshold = 0.8;
  if (!irradiance_block) {
    new_distribution_change_threshold *= max_distance;
  }
  // This branch will be coherent across a block
  if (irradiance_block) {
    Vec4 old_value = pc.irradiance.load(texel_coord);
    // Store gamma encoded for more perceptually linear EMWA
    result.rgb = pow(result.rgb, Vec3(1.0 / DDGI_IRRADIANCE_GAMMA));

    float change_magnitude = max_component(result.rgb - old_value.xyz);

    // Lower the hysteresis when a large change is detected
    if (abs(change_magnitude) > significant_change_threshold) {
      h = max(0, h - 0.15);
    }

    if (abs(change_magnitude) > new_distribution_change_threshold) {
      h = 0.0f;
    }

    pc.irradiance.store(texel_coord, Vec4(lerp(result.xyz, old_value.xyz, h), 1));
  } else {
    Vec2 old_value = pc.visibility.load(texel_coord).rg;

    pc.visibility.store(texel_coord, Vec4(lerp(result.rg, old_value, h), 0, 1));
  }
}
