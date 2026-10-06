import bindless;
import common;
import types;

// Smooth mesh normals keep receiver offsets continuous across shared edges.
Vec3 shadow_offset_receiver(Vec3 position, Vec3 mesh_normal,
                            Mat4x4 world_to_shadow, f32 depth_per_texel) {
  Vec3 N = normalize(mesh_normal);
  f32 world_texel =
      depth_per_texel / max(length(world_to_shadow[2].xyz), 1e-10);
  // Allow 1.5 texels for normal/face mismatch within the filter.
  return position + N * (1.5 * world_texel);
}

Vec2 shadow_receiver_gradient(Vec3 mesh_normal, Mat4x4 world_to_shadow) {
  // Inverse-transpose of the orthogonal world-to-shadow-UV transform.
  Vec3 x = world_to_shadow[0].xyz * 0.5;
  Vec3 y = world_to_shadow[1].xyz * 0.5;
  Vec3 z = world_to_shadow[2].xyz;
  Vec3 N = normalize(mesh_normal);
  f32 nz = dot(N, normalize(z));
  // Regularize the tangent plane continuously at light-grazing angles.
  f32 inverse_nz = nz / max(nz * nz, 0.0001);
  return -Vec2(dot(N, x) / dot(x, x), dot(N, y) / dot(y, y)) * length(z) *
         inverse_nz;
}

// PCG rotation from the original vkguide-style filter.
Vec3u32 pcg_3d(Vec3u32 v) {
  v = v * 1664525u + 1013904223u;

  v.x += v.y * v.z;
  v.y += v.z * v.x;
  v.z += v.x * v.y;

  v ^= v >> 16u;

  v.x += v.y * v.z;
  v.y += v.z * v.x;
  v.z += v.x * v.y;

  return v;
}

// Rotated 5x5 PCF: 25 hardware comparison samples spaced 1.5 texels apart.
f32 filter_pcf(Image2DArray<f32> shadow_map, SamplerComparison sampler,
               Vec2 screen_pos, Vec3 receiver, u32 cascade, Vec2 gradient,
               f32 depth_per_texel, f32 raster_subpixel_size) {
  int width, height, layers;
  shadow_map.get_dimensions(width, height, layers);
  if (any(receiver < 0.0) || any(receiver > 1.0))
    return 1.0;
  Vec2 size = Vec2(width, height);
  Vec2u32 pixel = Vec2u32(screen_pos);
  Vec3 random = normalize(Vec3(pcg_3d(Vec3u32(pixel, pixel.x ^ pixel.y))));
  Vec2 dir_a = normalize(random.xy);
  Vec2 dir_b = Vec2(-dir_a.y, dir_a.x);
  f32 precision_bias = max(8.0 * 1.192092896e-7 * max(abs(receiver.z), 0.125),
                           depth_per_texel * 0.025);
  // Include a half-texel slope margin for the hardware bilinear footprint.
  precision_bias += dot(abs(gradient), (0.5 + raster_subpixel_size) / size);
  f32 visibility = 0.0;
  for (int x = -2; x <= 2; ++x) {
    for (int y = -2; y <= 2; ++y) {
      Vec2 offset = (dir_a * f32(x) + dir_b * f32(y)) * 1.5 / size;
      f32 reference =
          min(1.0, receiver.z + dot(gradient, offset) - precision_bias);
      visibility += shadow_map.sample_cmp_level_zero(
          sampler, Vec3(receiver.xy + offset, f32(cascade)), reference);
    }
  }
  return visibility / 25.0;
}

static const Mat4x4 BIAS_MAT = {
  0.5, 0.0, 0.0, 0.5, //
  0.0, 0.5, 0.0, 0.5, //
  0.0, 0.0, 1.0, 0.0, //
  0.0, 0.0, 0.0, 1.0, //
};

f32 sample_shadow_cascade(GlobalData* g, Image2DArray<f32> shadow_map,
                          SamplerComparison shadow_sampler, u32 index,
                          Vec3 position, Vec3 normal, Vec2 screen_pos,
                          out f32 coverage) {
  let cascade = g.cascade_configs[index];
  let world_to_shadow = g.cascade_world_to_shadows[index];
  let offset = shadow_offset_receiver(position, normal, world_to_shadow,
                                      cascade.depth_per_texel);
  let projected = mul(BIAS_MAT, mul(world_to_shadow, Vec4(offset, 1)));
  let receiver = projected.xyz / projected.w;
  let gradient = shadow_receiver_gradient(normal, world_to_shadow);
  // Rotated square: 3*sqrt(2) texels, plus the bilinear comparison footprint.
  const float radius = 5.25;

  // The next cascade is fitted independently. Blend only where its complete
  // filter footprint is covered, fading out the blend near the map's edges.
  int width, height, layers;
  shadow_map.get_dimensions(width, height, layers);
  let edge = min(receiver, 1.0 - receiver);
  coverage =
      smoothstep(radius, radius + 1.0, min(edge.x * width, edge.y * height)) *
      smoothstep(0.0, 2.0 * cascade.depth_per_texel, edge.z);
  return filter_pcf(shadow_map, shadow_sampler, screen_pos, receiver,
                    index, gradient, cascade.depth_per_texel,
                    cascade.raster_subpixel_size);
}

f32 sample_shadow_cascades(GlobalData* g, Image2DArray<f32> shadow_map,
                           SamplerComparison shadow_sampler, u32 num_cascades,
                           Vec3 position, Vec3 normal, f32 view_z, Vec2 screen_pos) {
  u32 cascade_index = 0;
  for (u32 i = 0; i < num_cascades; i++) {
    if (view_z < -g.cascade_configs[i].split_dist) {
      cascade_index = i + 1;
    }
  }
  if (cascade_index >= num_cascades) {
    return 1.0;
  }

  let split = g.cascade_configs[cascade_index].split_dist;
  let previous_split = cascade_index > 0 ? g.cascade_configs[cascade_index - 1].split_dist : 0.0;
  // Crossfade over the last 15% of this cascade.
  let blend = smoothstep(split - 0.15 * (split - previous_split), split, -view_z);
  f32 coverage;
  f32 shadow = sample_shadow_cascade(g, shadow_map, shadow_sampler, cascade_index,
                                     position, normal, screen_pos, coverage);
  if (blend > 0.0) {
    f32 next_shadow = 1.0;
    coverage = 1.0;
    if (cascade_index + 1 < num_cascades) {
      next_shadow = sample_shadow_cascade(g, shadow_map, shadow_sampler, cascade_index + 1,
                                          position, normal, screen_pos, coverage);
    }
    // The final cascade fades to unshadowed at the existing shadow distance.
    shadow = lerp(shadow, next_shadow, blend * coverage);
  }
  return shadow;
}
