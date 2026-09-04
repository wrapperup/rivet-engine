import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereAerialPush pc;

[numthreads(4, 4, 4)]
[shader("compute")]
void compute_main(Vec3u32 tid : SV_DispatchThreadID) {
  if (any(tid >= Vec3u32(32)))
    return;
  Atmosphere a = pc.global.atmosphere;
  Vec3 dir = atmosphere_view_ray(pc.global, (Vec2(tid.xy) + 0.5) / 32.0);
  f32 depth = f32(tid.z) / 31.0;
  Vec3 T;
  Vec3 L = atmosphere_integrate(a, Vec3(0, ATM_GROUND + a.camera_height, 0),
                                dir, pc.global.sun_direction,
                                depth * depth * ATM_AERIAL_RANGE, 24, false, T);
  pc.scattering.store(tid, Vec4(L, 1));
  pc.transmittance.store(tid, Vec4(T, 1));
}
