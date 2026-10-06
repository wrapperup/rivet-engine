import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereLutPush pc;

[numthreads(8, 8, 1)]
[shader("compute")]
void compute_main(Vec3u32 tid : SV_DispatchThreadID) {
  if (tid.x >= 256 || tid.y >= 64)
    return;
  Vec2 uv = Vec2(tid.xy) / Vec2(255, 63);
  f32 H = sqrt(ATM_TOP * ATM_TOP - ATM_GROUND * ATM_GROUND);
  f32 rho = H * uv.y;
  f32 r = sqrt(rho * rho + ATM_GROUND * ATM_GROUND);
  r = min(r, ATM_TOP - 0.001);
  f32 d = lerp(ATM_TOP - r, rho + H, uv.x);
  f32 mu = d > 0.0001
               ? clamp((H * H - rho * rho - d * d) / (2 * r * d), -1.0, 1.0)
               : 1.0;
  Vec3 origin = Vec3(0, r, 0), dir = Vec3(sqrt(max(0.0, 1 - mu * mu)), mu, 0);
  Vec3 depth = Vec3(0.0);
  for (u32 i = 0; i < 64; ++i) {
    Vec3 R, M, E;
    atmosphere_medium(pc.global.atmosphere,
                      origin + dir * (d * (f32(i) + 0.5) / 64.0), R, M, E);
    depth += E * (d / 64.0);
  }
  pc.output.store(tid.xy, Vec4(exp(-depth), 1));
}
