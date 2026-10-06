float3 get_world_direction(uint3 coord, uint size) {
  float2 uv = 2.0 * float2(coord.xy) / float(size) - 1.0;

  switch (coord.z) {
  case 0: return normalize(float3(1.0, uv.y, -uv.x));
  case 1: return normalize(float3(-1.0, uv.yx));
  case 2: return normalize(float3(uv.x, 1.0, -uv.y));
  case 3: return normalize(float3(uv.x, -1.0, uv.y));
  case 4: return normalize(float3(uv, 1.0));
  case 5: return normalize(float3(-uv.x, uv.y, -1.0));
  }

  return 0.f;
}
