import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereLutPush pc;

[numthreads(8, 8, 1)]
[shader("compute")]
void compute_main(Vec3u32 tid : SV_DispatchThreadID) {
  if (tid.x >= 192 || tid.y >= 108)
    return;
  Atmosphere a = pc.global.atmosphere;
  Vec3 dir = atmosphere_sky_direction(a, Vec2(tid.xy) / Vec2(191, 107),
                                      pc.global.sun_direction);
  Vec3 T;
  Vec3 L =
      atmosphere_integrate(a, Vec3(0, ATM_GROUND + a.camera_height, 0), dir,
                           pc.global.sun_direction, 20000.0, 48, true, T);
  pc.output.store(tid.xy, Vec4(L, 1));
}
