import "../types";
import "../brdf";
import common;
import bindless;

#define PI 3.14159265359

static const u32 SAMPLE_COUNT = 1024;
static const u32 ROUGHNESS_LEVELS = 9;

struct PushConstants {
  u32 mip_level;
  u32 sample_count;
  ImageCube environment_map;
  RWImage2D prefiltered_map[ROUGHNESS_LEVELS];
};

[vk_push_constant] PushConstants pc;

// z = face index
[numthreads(16, 16, 1)]
[shader("compute")]
void compute_main(Vec3u32 dispatchThreadID: SV_DispatchThreadID) {
  let texel_coord = dispatchThreadID.xyz;

  Vec3u32 size;
  PrefilteredMap[0].GetDimensions(size.x, size.y, size.z);
  size.xy = size.xy >> pc.mip_level;

  if (texel_coord.x >= size.x || texel_coord.y >= size.y || texel_coord.z >= size.z) {
    return;
  }

  let coord = Vec3u32(texel_coord.x, size.y - texel_coord.y, texel_coord.z);
  let N = get_world_direction(coord, size.x);
  let V = N;

  let p_roughness = f32(pc.mip_level) / f32(ROUGHNESS_LEVELS - 1);

  Vec3 sum_prefilter = 0;
  f32 sum_NoL = 0;

  for (u32 i = 0; i < pc.sample_count; i++) {
    let Xi = hammersley(i, pc.sample_count);
    let H = importance_sample_ggx(Xi, N, p_roughness);
    let L  = normalize(2.0 * dot(V, H) * H - V);

    let NoL = max(dot(N, L), 0.0);
    if (NoL > 0.f) {
      sum_prefilter += clamp(EnvironmentMap.SampleLevel(L, pc.mip_level).rgb * NoL, 0.0, 10.0);
      sum_NoL += NoL;
    }
  }

  let prefiltered_color = sum_prefilter / sum_NoL;

  PrefilteredMap[pc.mip_level][texel_coord] = Vec4(prefiltered_color, 1.0);
}
