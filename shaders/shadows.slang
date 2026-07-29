import bindless;
import types;

// 9 imad (+ 6 iops with final shuffle) -- https://vkguide.dev
uint3 pcg_3d(uint3 v) {

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

struct Shadow_Params {
    Image2DArray<f32> depth;
    SamplerComparison sampler;
}

float shadow_calc(Shadow_Params params, float4 shadow_coord, float cascade, float2 offset = 0.0,
                  float bias) {
  // perform perspective divide
  float3 proj_coords = shadow_coord.xyz / shadow_coord.w;

  let shadow = params.depth.sample_cmp_level_zero(
      params.sampler, Vec3(proj_coords.xy + offset, cascade),
      proj_coords.z - bias);

  return shadow;
}

float filter_pcf(Shadow_Params params, float2 screen_pos, float4 shadow_coord, float cascade,
                 float bias, float slope_bias, float NoL) {
  int2 texDim;
  int elems;
  params.depth.get_dimensions(texDim.x, texDim.y, elems);

  let proj_coords = shadow_coord.xyz / shadow_coord.w;

  if (proj_coords.x < 0 || proj_coords.x > 1) {
    return 1.f;
  }

  if (proj_coords.y < 0 || proj_coords.y > 1) {
    return 1.f;
  }

  if (proj_coords.z < 0 || proj_coords.z > 1) {
    return 1.f;
  }

  float scale = 1.5f;
  float dx = scale * 1.0 / float(texDim.x);
  float dy = scale * 1.0 / float(texDim.y);

  float shadow_factor = 0.0;
  int count = 0;
  int range = 2;

  uint4 u = uint4(uint2(screen_pos), uint(screen_pos.x) ^ uint(screen_pos.y),
                  uint(screen_pos.x) + uint(screen_pos.y));
  float3 rand = pcg_3d(u.xyz);
  rand = normalize(rand);

  float2 dirA = normalize(rand.xy);
  float2 dirB = normalize(float2(-dirA.y, dirA.x));

  dirA *= dx;
  dirB *= dy;

  // Clamp the slope term: tan(acos(NoL)) -> infinity at grazing NoL, which biases the receiver
  // past its occluder and reads "lit" deep inside shadowed interiors (bright speckles on
  // normal-mapped edges in dark rooms). 5 ~= NoL 0.2, so tuned cascade biases are unchanged
  // above that; below it the direct term is killed by its own NoL factor anyway.
  float totalBias = bias + slope_bias * min(tan(acos(NoL)), 5.0);

  for (int x = -range; x <= range; x++) {
    for (int y = -range; y <= range; y++) {
      shadow_factor +=
          shadow_calc(params, shadow_coord, cascade, dirA * x + dirB * y, totalBias);
      count++;
    }
  }

  return shadow_factor / count;
}
