import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereLutPush pc;

[numthreads(8, 8, 1)]
[shader("compute")]
void compute_main(Vec3u32 tid : SV_DispatchThreadID) {
  if (tid.x >= 32 || tid.y >= 32)
    return;
  Atmosphere a = pc.global.atmosphere;
  f32 mu = f32(tid.x) / 31.0 * 2.0 - 1.0;
  f32 h = f32(tid.y) / 31.0;
  Vec3 origin = Vec3(0, ATM_GROUND + clamp(h * h * 100.0, 0.002, 99.999), 0);
  Vec3 sun = Vec3(sqrt(max(0.0, 1 - mu * mu)), mu, 0);
  Vec3 luminance = Vec3(0), feedback = Vec3(0);
  // Isotropic higher-order scattering, integrated over a deterministic sphere.
  for (u32 j = 0; j < 32; ++j) {
    f32 y = 1 - 2 * (f32(j) + 0.5) / 32.0;
    f32 phi = f32(j) * 2.39996323;
    Vec3 dir = Vec3(sqrt(1 - y * y) * cos(phi), y, sqrt(1 - y * y) * sin(phi));
    f32 ground = atmosphere_ground_distance(origin, dir);
    f32 distance = ground >= 0 ? ground : atmosphere_top_distance(origin, dir);
    Vec3 T = Vec3(1), L = Vec3(0), F = Vec3(0);
    for (u32 i = 0; i < 24; ++i) {
      f32 dt = distance / 24.0;
      Vec3 p = origin + dir * ((f32(i) + 0.5) * dt);
      Vec3 R, M, E;
      atmosphere_medium(a, p, R, M, E);
      Vec3 integral = T * atmosphere_step_integral(E, dt);
      L += integral * (R + M) * atmosphere_sun_transmittance(a, p, sun) /
           (4 * ATM_PI);
      F += integral * (R + M);
      T *= exp(-E * dt);
    }
    if (ground >= 0) {
      Vec3 p = normalize(origin + dir * ground) * (ATM_GROUND + 0.002);
      L += T * a.ground_albedo * atmosphere_sun_transmittance(a, p, sun) *
           max(0.0, dot(normalize(p), sun)) / ATM_PI;
      F += T * a.ground_albedo;
    }
    luminance += L / 32.0;
    feedback += F / 32.0;
  }
  pc.output.store(tid.xy, Vec4(luminance / max(Vec3(0.001), 1 - feedback), 1));
}
