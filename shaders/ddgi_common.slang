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

static const float pi = 3.14159265358979;

// Mirrors DDGI_PROBE_IRR_TEXELS / DDGI_PROBE_DEPTH_TEXELS in src/entity_ddgi_volume.odin.
static const int DDGI_IRRADIANCE_PROBE_SIDE_LENGTH = 6;
static const int DDGI_VISIBILITY_PROBE_SIDE_LENGTH = 14;

static const float DDGI_IRRADIANCE_GAMMA = 5.0;

static const int STATE_OFF           = 0;
static const int STATE_ASLEEP        = 1;
static const int STATE_JUST_WOKE     = 2;
static const int STATE_AWAKE         = 3;
static const int STATE_JUST_VIGILANT = 4;
static const int STATE_VIGILANT      = 5;
static const int STATE_UNINITIALIZED = 6;

float square(float x) {
  return x * x;
}

Vec3 square(Vec3 x) {
  return x * x;
}

float pow3(float x) {
  return x * x * x;
}

float max_component(Vec3 v) {
  return max(v.x, max(v.y, v.z));
}

Vec2 ddgi_oct_encode(Vec3 dir) {
  Vec3 n = dir / (abs(dir.x) + abs(dir.y) + abs(dir.z));
  Vec2 e = n.z >= 0.0
      ? n.xy
      : (Vec2(1.0) - abs(Vec2(n.y, n.x))) * Vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
  return e;
}

Vec3 ddgi_oct_decode(Vec2 e) {
  Vec3 n = Vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
  float t = saturate(-n.z);
  n.x += n.x >= 0.0 ? -t : t;
  n.y += n.y >= 0.0 ? -t : t;
  return normalize(n);
}

// Spherical Fibonacci point set (golden-angle spiral).
Vec3 ddgi_spherical_fibonacci(int i, int n) {
  const float GOLDEN = 2.39996323; // golden angle (radians)
  float z = 1.0 - (2.0 * float(i) + 1.0) / float(n);
  float r = sqrt(max(0.0, 1.0 - z * z));
  float phi = float(i) * GOLDEN;
  return Vec3(r * cos(phi), r * sin(phi), z);
}

// PCG3D (Jarzynski and Olano 2020)
Mat3x3 ddgi_random_orientation(DDGIVolume ddgi_volume) {
  uint3 h = uint3(ddgi_volume.frame_index, ddgi_volume.frame_index * 0x9E3779B9u, ddgi_volume.frame_index ^ 0x85EBCA6Bu);

  h = h * 1664525u + 1013904223u;
  h.x += h.y * h.z; h.y += h.z * h.x; h.z += h.x * h.y;
  h ^= h >> 16u;
  h.x += h.y * h.z; h.y += h.z * h.x; h.z += h.x * h.y;
  Vec3 u = Vec3(h >> 8u) * (1.0 / 16777216.0);

  float a = sqrt(1.0 - u.x);
  float b = sqrt(u.x);
  Vec4 q = Vec4(a * sin(2.0 * pi * u.y), a * cos(2.0 * pi * u.y), b * sin(2.0 * pi * u.z), b * cos(2.0 * pi * u.z));
  return Mat3x3(
    1.0 - 2.0 * (q.y * q.y + q.z * q.z), 2.0 * (q.x * q.y - q.z * q.w),       2.0 * (q.x * q.z + q.y * q.w),
    2.0 * (q.x * q.y + q.z * q.w),       1.0 - 2.0 * (q.x * q.x + q.z * q.z), 2.0 * (q.y * q.z - q.x * q.w),
    2.0 * (q.x * q.z - q.y * q.w),       2.0 * (q.y * q.z + q.x * q.w),       1.0 - 2.0 * (q.x * q.x + q.y * q.y));
}

// DDGIVolume_updateProbes.glc and DDGIVolume_computeProbeOffsets.glc.
Vec3 ddgi_ray_direction(DDGIVolume ddgi_volume, int ray_index) {
  return mul(ddgi_random_orientation(ddgi_volume), ddgi_spherical_fibonacci(ray_index, ddgi_volume.rays_per_probe));
}

typealias ProbeIndex = int;
typealias GridCoord = int3;

GridCoord ddgi_probe_counts(DDGIVolume ddgi_volume) {
  return GridCoord(ddgi_volume.grid_counts[0], ddgi_volume.grid_counts[1], ddgi_volume.grid_counts[2]);
}

int ddgi_num_probes(DDGIVolume ddgi_volume) {
  GridCoord probe_counts = ddgi_probe_counts(ddgi_volume);
  return probe_counts.x * probe_counts.y * probe_counts.z;
}

// DDGIVolume.glsl: gridCoordToProbeIndex
ProbeIndex ddgi_grid_coord_to_probe_index(DDGIVolume ddgi_volume, GridCoord probe_coords) {
  GridCoord probe_counts = ddgi_probe_counts(ddgi_volume);
  return int(probe_coords.x + probe_coords.y * probe_counts.x + probe_coords.z * probe_counts.x * probe_counts.y);
}

// DDGIVolume.glsl: baseGridCoord
GridCoord ddgi_base_grid_coord(DDGIVolume ddgi_volume, Vec3 X) {
  // Implicit floor in the convert to int
  GridCoord un_offset_grid_coord = clamp(GridCoord((X - ddgi_volume.grid_origin) / ddgi_volume.probe_spacing),
                                         GridCoord(0, 0, 0),
                                         ddgi_probe_counts(ddgi_volume) - 1);
  return un_offset_grid_coord;
}

// DDGIVolume.glsl: probeIndexToGridCoord
GridCoord ddgi_probe_index_to_grid_coord(DDGIVolume L, ProbeIndex index) {
  GridCoord probe_counts = ddgi_probe_counts(L);

  /* Works for any # of probes */
  GridCoord i_pos;
  i_pos.x = index % probe_counts.x;
  i_pos.y = (index % (probe_counts.x * probe_counts.y)) / probe_counts.x;
  i_pos.z = index / (probe_counts.x * probe_counts.y);

  return i_pos;
}

int2 ddgi_probe_tile(DDGIVolume L, GridCoord c) {
  return int2(c.x + c.z * ddgi_probe_counts(L).x, c.y);
}

// DDGIVolume.glsl: readProbeOffset
Vec4 ddgi_read_probe_offset(DDGIVolume L, int2 texel_coord) {
  return L.offset.load(int3(texel_coord, 0));
}

// DDGIVolume.glsl: gridCoordToPositionNoOffset
Vec3 ddgi_grid_coord_to_position_no_offset(DDGIVolume L, GridCoord c) {
  return L.probe_spacing * Vec3(c) + L.grid_origin;
}

// DDGIVolume.glsl: gridCoordToPosition
Vec3 ddgi_grid_coord_to_position(DDGIVolume L, GridCoord c) {
  //Add per-probe offset
  int2 C = ddgi_probe_tile(L, c);

  Vec3 offset = ddgi_read_probe_offset(L, C).xyz; // readProbeOffset multiplies by probe step.
  return ddgi_grid_coord_to_position_no_offset(L, c) + offset;
}

// DDGIVolume.glsl: probeLocation
Vec3 ddgi_probe_location(DDGIVolume L, ProbeIndex index) {
  return ddgi_grid_coord_to_position(L, ddgi_probe_index_to_grid_coord(L, index));
}

// DDGIVolume.glsl: probeTextureCoordFromDirection
Vec2 ddgi_probe_texture_coord_from_direction(
    Vec3 dir,
    GridCoord probe_grid_coord,
    bool use_irradiance,
    DDGIVolume ddgi_volume) {
  GridCoord probe_counts = ddgi_probe_counts(ddgi_volume);
  int probe_side_length = use_irradiance ? DDGI_IRRADIANCE_PROBE_SIDE_LENGTH : DDGI_VISIBILITY_PROBE_SIDE_LENGTH;
  int probe_with_border_side = probe_side_length + 2;
  Vec2 inv_texture_size = 1.0 / Vec2(probe_counts.x * probe_counts.z * probe_with_border_side, probe_counts.y * probe_with_border_side);

  Vec2 signed_oct = ddgi_oct_encode(dir);
  Vec2 unsigned_oct = (signed_oct + 1.0f) * 0.5f;
  Vec2 oct_coord_normalized_to_texture_dimensions = (unsigned_oct * (float)probe_side_length) * inv_texture_size;

  Vec2 probe_top_left_position = Vec2(ddgi_probe_tile(ddgi_volume, probe_grid_coord) * probe_with_border_side) + Vec2(1, 1);

  Vec2 normalized_probe_top_left_position = Vec2(probe_top_left_position) * inv_texture_size;

  return Vec2(normalized_probe_top_left_position + oct_coord_normalized_to_texture_dimensions);
}

// DDGIVolume_updateProbes.glc: normalizedOctCoord
Vec2 ddgi_normalized_oct_coord(int2 oct_frag_coord, int probe_side_length) {
  // Add back the half pixel to get pixel center normalized coordinates
  return (Vec2(oct_frag_coord) + 0.5f) * (2.0f / float(probe_side_length)) - 1.0f;
}

// DDGIVolume.glsl: sampleOneDDGIVolume
/**
  Result.rgb = Irradiance3
  Result.a   = weight based on wsPosition vs. probe bounds
*/
// Deviations: no camera-locked volumes (so no cameraPos) and no debug parameters.
Vec4 ddgi_sample_one_ddgi_volume(
    DDGIVolume ddgi_volume,
    Vec3 ws_position,
    Vec3 offset_pos,
    Vec3 sample_direction,

    // Can we skip this volume if it has zero weight?
    bool skippable) {

  // Compute the weight for this volume relative to other volumes
  float volume_weight = 1.0;
  if (skippable) {
    // Compute the non-integer baseGridCoord. Use the unshifted position so that weights are consistent between
    // volumes. Use the geometric mean across all axes.
    Vec3 shifted_origin = ddgi_volume.grid_origin;

    Vec3 real_grid_coord = (ws_position - shifted_origin) / ddgi_volume.probe_spacing;
    for (int axis = 0; axis < 3; ++axis) {
      float a = real_grid_coord[axis];
      if (a < 1.0) {
        volume_weight *= clamp(a, 0.0, 1.0);
      } else if (a > float(ddgi_probe_counts(ddgi_volume)[axis]) - 2.0) {
        volume_weight *= clamp(float(ddgi_probe_counts(ddgi_volume)[axis]) - 1.0 - a, 0.0, 1.0);
      }
    }
    // Blending is improved without logarithmic fallof
    //volumeWeight = pow(volumeWeight, 1.0 / 3.0);
  }

  if (volume_weight == 0.0) {
    // Don't bother sampling, this volume won't be used
    return Vec4(0);
  }

  // Deviation: selfShadowBias is the volume's normal_bias.
  offset_pos *= ddgi_volume.normal_bias;

  // We're sampling at (wsPosition + offsetPos). This is inside of some grid cell, which
  // is bounded by 8 probes. Find the coordinate of the corner for the LOWEST probe (i.e.,
  // floor along x,y,z) and call that baseGridCoord. The other seven probes are offset by
  // +0 or +1 in grid space along each axis from this. We'll process them all in the main
  // loop below.
  //
  // This is all analogous to bilinear interpolation for texture maps, but we're doing it
  // in 3D, with visibility, and nonlinearly.
  GridCoord anchor_grid_coord = ddgi_base_grid_coord(ddgi_volume, ws_position + offset_pos);

  // Don't use the offset to compute trilinear.
  Vec3 base_probe_pos = ddgi_grid_coord_to_position_no_offset(ddgi_volume, anchor_grid_coord);

  // Weighted irradiance accumulated in RGB across probes. The Alpha channel contains the
  // sum of the weights, which is used for normalization at the end.
  Vec4 irradiance = Vec4(0);

  // `alpha` is how far from the floor(currentVertex) position. On [0, 1] for each axis.
  // Used for trilinear weighting.
  Vec3 alpha = clamp((ws_position + offset_pos - base_probe_pos) / ddgi_volume.probe_spacing, Vec3(0), Vec3(1));

  // Iterate over adjacent probe cage
  // Deviation: unrolled so the probes' texture fetches can overlap.
  [unroll]
  for (int i = 0; i < 8; ++i) {
    // Compute the offset grid coord and clamp to the probe grid boundary
    // Offset = 0 or 1 along each axis. Pull the offsets from the bits of the
    // loop index: x = bit 0, y = bit 1, z = bit 2
    GridCoord offset = int3(i, i >> 1, i >> 2) & int3(1);

    // Compute the trilinear weights based on the grid cell vertex to smoothly
    // transition between probes. Offset is binary, so we're
    // using 1-a when offset = 0 and a when offset = 1.
    Vec3 trilinear3 = max(Vec3(0.001), lerp(1.0 - alpha, alpha, Vec3(offset)));
    float trilinear = trilinear3.x * trilinear3.y * trilinear3.z;

    // Because of the phase offset applied for camera locked volumes,
    // we need to add the computed offset modulo the probecounts.
    // Deviation: no phase offsets, so the coordinate is clamped to the grid instead of wrapping around it.
    GridCoord probe_grid_coord = clamp(anchor_grid_coord + offset, GridCoord(0), ddgi_probe_counts(ddgi_volume) - 1);

    // Make cosine falloff in tangent plane with respect to the angle from the surface to the probe so that we never
    // test a probe that is *behind* the surface.
    // It doesn't have to be cosine, but that is efficient to compute and we must clip to the tangent plane.
    Vec3 probe_pos = ddgi_grid_coord_to_position(ddgi_volume, probe_grid_coord);

    float weight = 1.0;
    // Clamp all of the multiplies. We can't let the weight go to zero because then it would be
    // possible for *all* weights to be equally low and get normalized
    // up to 1/n. We want to distinguish between weights that are
    // low because of different factors.

    {
      // Computed without the biasing applied to the "dir" variable.
      // This test can cause reflection-map looking errors in the image
      // (stuff looks shiny) if the transition is poor.
      Vec3 true_direction_to_probe = normalize(probe_pos - ws_position);

      // The naive soft backface weight would ignore a probe when
      // it is behind the surface. That's good for walls. But for small details inside of a
      // room, the normals on the details might rule out all of the probes that have mutual
      // visibility to the point. So, we instead use a "wrap shading" test below inspired by
      // NPR work.

      // The small offset at the end reduces the "going to zero" impact
      // where this is really close to exactly opposite
      weight *= square((dot(true_direction_to_probe, sample_direction) + 1.0) * 0.5) + 0.2;
    }

    // Bias the position at which visibility is computed; this avoids performing a shadow
    // test *at* a surface, which is a dangerous location because that is exactly the line
    // between shadowed and unshadowed. If the normal bias is too small, there will be
    // light and dark leaks. If it is too large, then samples can pass through thin occluders to
    // the other side (this can only happen if there are MULTIPLE occluders near each other, a wall surface
    // won't pass through itself.)
    Vec3 probe_to_biased_point_direction = (ws_position + offset_pos) - probe_pos;
    float distance_to_biased_point = length(probe_to_biased_point_direction);
    probe_to_biased_point_direction *= 1.0 / distance_to_biased_point;

    {
      Vec2 tex_coord = ddgi_probe_texture_coord_from_direction(probe_to_biased_point_direction, probe_grid_coord, false, ddgi_volume);

      Vec2 temp = ddgi_volume.depth.sample_level(ddgi_volume.sampler, tex_coord, 0).xy;
      float mean_distance_to_occluder = temp.x;
      float variance = abs(square(temp.x) - temp.y);

      float chebyshev_weight = 1.0;
      if (distance_to_biased_point > mean_distance_to_occluder) {
        // In "shadow"

        // http://www.punkuser.net/vsm/vsm_paper.pdf; equation 5
        // Need the max in the denominator because biasing can cause a negative displacement
        chebyshev_weight = variance / (variance + square(distance_to_biased_point - mean_distance_to_occluder));

        // Increase contrast in the weight
        chebyshev_weight = max(pow3(chebyshev_weight), 0.0);
      }

      // Avoid visibility weights ever going all of the way to zero because when *no* probe has
      // visibility we need some fallback value.
      chebyshev_weight = max(0.05, chebyshev_weight);
      weight *= chebyshev_weight;
    }

    // Avoid zero weight
    weight = max(0.000001, weight);

    Vec2 tex_coord = ddgi_probe_texture_coord_from_direction(sample_direction, probe_grid_coord, true, ddgi_volume);

    {
      // A tiny bit of light is really visible due to log perception, so
      // crush tiny weights but keep the curve continuous.
      const float crush_threshold = 0.2;
      if (weight < crush_threshold) {
        weight *= square(weight) * (1.0 / square(crush_threshold));
      }
    }

    weight *= trilinear;

    Vec3 probe_irradiance = ddgi_volume.irradiance.sample_level(ddgi_volume.sampler, tex_coord, 0).rgb;

    // Decode the tone curve, but leave a gamma = 2 curve (=sqrt here) to approximate sRGB blending for the trilinear
    probe_irradiance = pow(probe_irradiance, Vec3(DDGI_IRRADIANCE_GAMMA * 0.5));

    irradiance += Vec4(weight * probe_irradiance, weight);
  }

  // Normalize by the sum of the weights
  irradiance.xyz *= 1.0 / irradiance.a;

  // Go back to linear irradiance
  irradiance.xyz = square(irradiance.xyz);

  // Was factored out of probes
  // Deviation: not applied. Callers (shade_indirect_diffuse) expect the probes' cosine-weighted mean radiance.

  return Vec4(irradiance.xyz, volume_weight);
}

//------------------------------------------------------------------------
// Engine entry points
//------------------------------------------------------------------------

// Deviation: a single volume, biased along the normal only.
Vec3 ddgi_sample(DDGIVolume* ddgi_volume, Vec3 ws_position, Vec3 normal) {
  return ddgi_sample_one_ddgi_volume(ddgi_volume[0], ws_position, normal, normal, false).rgb;
}
