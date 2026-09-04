import bindless;
import common;
import types;

// Hillaire-style LUT atmosphere. Distances are kilometres, coefficients are
// km^-1. See https://sebh.github.io/publications/egsr2020.pdf.
static const f32 ATM_PI = 3.14159265359;
static const f32 ATM_GROUND = 6360.0;
static const f32 ATM_TOP = 6460.0;
static const f32 ATM_AERIAL_RANGE = 32.0;

f32 atmosphere_top_distance(Vec3 p, Vec3 d) {
  f32 r = length(p), b = dot(p, d);
  return max(0.0, -b + sqrt(max(0.0, b * b + (ATM_TOP - r) * (ATM_TOP + r))));
}

f32 atmosphere_ground_distance(Vec3 p, Vec3 d) {
  f32 r = length(p), b = dot(p, d);
  f32 disc = b * b - (r - ATM_GROUND) * (r + ATM_GROUND);
  return b < 0.0 && disc >= 0.0 ? max(0.0, -b - sqrt(disc)) : -1.0;
}

void atmosphere_medium(Atmosphere a, Vec3 p, out Vec3 rayleigh, out Vec3 mie,
                       out Vec3 extinction) {
  f32 h = max(0.0, length(p) - ATM_GROUND);
  rayleigh =
      Vec3(0.005802, 0.013558, 0.033100) * exp(-h / 8.0) * a.rayleigh_density;
  f32 aerosol = exp(-h / 1.2) * a.mie_density;
  mie = Vec3(0.003996) * aerosol;
  f32 ozone = max(0.0, 1.0 - abs(h - 25.0) / 15.0) * a.ozone_density;
  extinction = rayleigh + Vec3(0.004440) * aerosol +
               Vec3(0.000650, 0.001881, 0.000085) * ozone;
}

Vec2 atmosphere_trans_uv(f32 r, f32 mu) {
  r = clamp(r, ATM_GROUND, ATM_TOP - 0.001);
  f32 H = sqrt(ATM_TOP * ATM_TOP - ATM_GROUND * ATM_GROUND);
  f32 rho = sqrt(max(0.0, (r - ATM_GROUND) * (r + ATM_GROUND)));
  f32 d = max(0.0, -r * mu + sqrt(max(0.0, r * r * mu * mu +
                                               (ATM_TOP - r) * (ATM_TOP + r))));
  Vec2 uv = saturate(
      Vec2((d - (ATM_TOP - r)) / max(rho + H - (ATM_TOP - r), 0.001), rho / H));
  return (uv * Vec2(255, 63) + 0.5) / Vec2(256, 64);
}

Vec3 atmosphere_sun_transmittance(Atmosphere a, Vec3 p, Vec3 sun) {
  if (atmosphere_ground_distance(p, sun) >= 0.0)
    return Vec3(0.0);
  return a.transmittance
      .sample_level(a.sampler,
                    atmosphere_trans_uv(length(p), dot(normalize(p), sun)), 0)
      .rgb;
}

Vec3 atmosphere_direct_sun(GlobalData *g, Vec3 world_pos) {
  f32 h =
      clamp((world_pos.y - g.atmosphere.ground_height) * 0.001, 0.002, 99.0);
  return g.sun_color * atmosphere_sun_transmittance(g.atmosphere,
                                                    Vec3(0, ATM_GROUND + h, 0),
                                                    g.sun_direction);
}

Vec2 atmosphere_multi_uv(Vec3 p, Vec3 sun) {
  f32 h = saturate((length(p) - ATM_GROUND) / 100.0);
  Vec2 uv = Vec2(dot(normalize(p), sun) * 0.5 + 0.5, sqrt(h));
  return (saturate(uv) * 31.0 + 0.5) / 32.0;
}

Vec3 atmosphere_multi(Atmosphere a, Vec3 p, Vec3 sun) {
  return a.multiple_scattering
      .sample_level(a.sampler, atmosphere_multi_uv(p, sun), 0)
      .rgb;
}

Vec3 atmosphere_step_integral(Vec3 extinction, f32 dt) {
  // The limit at zero extinction is dt (also supports a vacuum atmosphere).
  return Vec3(
      extinction.x > 1e-7 ? (1 - exp(-extinction.x * dt)) / extinction.x : dt,
      extinction.y > 1e-7 ? (1 - exp(-extinction.y * dt)) / extinction.y : dt,
      extinction.z > 1e-7 ? (1 - exp(-extinction.z * dt)) / extinction.z : dt);
}

Vec3 atmosphere_integrate(Atmosphere a, Vec3 origin, Vec3 dir, Vec3 sun,
                          f32 max_distance, u32 steps, bool ground_bounce,
                          out Vec3 transmittance) {
  f32 ground = atmosphere_ground_distance(origin, dir);
  f32 distance = min(atmosphere_top_distance(origin, dir), max_distance);
  if (ground >= 0.0)
    distance = min(distance, ground);
  f32 mu = dot(dir, sun);
  f32 phase_r = 3.0 * (1.0 + mu * mu) / (16.0 * ATM_PI);
  f32 g = 0.8;
  f32 phase_m =
      (1 - g * g) / (4 * ATM_PI * pow(max(1 + g * g - 2 * g * mu, 0.001), 1.5));
  transmittance = Vec3(1.0);
  Vec3 radiance = Vec3(0.0);
  for (u32 i = 0; i < steps; ++i) {
    f32 t0 = f32(i) / f32(steps), t1 = f32(i + 1) / f32(steps);
    f32 dt = (t1 * t1 - t0 * t0) * distance;
    Vec3 p = origin + dir * ((t0 * t0 + t1 * t1) * 0.5 * distance);
    Vec3 r, m, e;
    atmosphere_medium(a, p, r, m, e);
    Vec3 source =
        (r * phase_r + m * phase_m) * atmosphere_sun_transmittance(a, p, sun) +
        (r + m) * atmosphere_multi(a, p, sun);
    radiance += transmittance * source * atmosphere_step_integral(e, dt);
    transmittance *= exp(-e * dt);
  }
  if (ground_bounce && ground >= 0.0 && ground <= max_distance) {
    Vec3 p = origin + dir * ground;
    p = normalize(p) * (ATM_GROUND + 0.002);
    Vec3 irradiance = atmosphere_sun_transmittance(a, p, sun) *
                      max(0.0, dot(normalize(p), sun));
    radiance += transmittance * a.ground_albedo *
                (irradiance / ATM_PI + atmosphere_multi(a, p, sun));
  }
  return max(radiance, 0.0);
}

// Concentrate elevation samples around the geometric horizon. Azimuth is
// relative to the sun; a spherical clear atmosphere is symmetric on either side
// of it.
f32 atmosphere_horizon(Atmosphere a) {
  return -acos(ATM_GROUND / (ATM_GROUND + a.camera_height));
}

Vec3 atmosphere_sky_direction(Atmosphere a, Vec2 uv, Vec3 sun) {
  f32 horizon = atmosphere_horizon(a);
  f32 q = uv.y * 2.0 - 1.0;
  f32 elevation = horizon + (q < 0 ? (ATM_PI * 0.5 - horizon) * q * q
                                   : (-ATM_PI * 0.5 - horizon) * q * q);
  Vec3 forward = dot(sun.xz, sun.xz) > 1e-8 ? normalize(Vec3(sun.x, 0, sun.z))
                                            : Vec3(0, 0, 1);
  Vec3 right = cross(Vec3(0, 1, 0), forward);
  return cos(elevation) *
             (cos(uv.x * ATM_PI) * forward + sin(uv.x * ATM_PI) * right) +
         Vec3(0, sin(elevation), 0);
}

Vec3 atmosphere_sky(GlobalData *g, Vec3 dir) {
  f32 horizon = atmosphere_horizon(g.atmosphere);
  f32 elevation = asin(clamp(dir.y, -1.0, 1.0));
  f32 delta = elevation - horizon;
  f32 v = delta >= 0
              ? 0.5 - 0.5 * sqrt(saturate(delta / (ATM_PI * 0.5 - horizon)))
              : 0.5 + 0.5 * sqrt(saturate(-delta / (ATM_PI * 0.5 + horizon)));
  Vec3 sun = g.sun_direction;
  Vec2 forward = dot(sun.xz, sun.xz) > 1e-8 ? normalize(sun.xz) : Vec2(0, 1);
  f32 cos_phi =
      dot(dir.xz, dir.xz) > 1e-8 ? dot(normalize(dir.xz), forward) : 1.0;
  Vec2 uv = Vec2(acos(clamp(cos_phi, -1.0, 1.0)) / ATM_PI, v);
  uv = (uv * Vec2(191, 107) + 0.5) / Vec2(192, 108);
  return g.atmosphere.sky_view.sample_level(g.atmosphere.sampler, uv, 0).rgb *
         g.sun_color;
}

Vec3 atmosphere_view_ray(GlobalData *g, Vec2 uv) {
  // Infinite reversed-Z: unproject finite depths (z=0 lies at infinity).
  Vec4 near_p = mul(g.clip_to_world, Vec4(uv * 2 - 1, 1, 1));
  Vec4 mid_p = mul(g.clip_to_world, Vec4(uv * 2 - 1, 0.5, 1));
  return normalize(mid_p.xyz / mid_p.w - near_p.xyz / near_p.w);
}

Vec3 atmosphere_aerial(GlobalData *g, Vec3 world_pos, Vec3 color) {
  Vec4 clip = mul(g.view_to_clip, mul(g.world_to_view, Vec4(world_pos, 1)));
  Vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
  f32 km = length(world_pos - g.camera_pos) * 0.001;
  f32 z = (sqrt(saturate(km / ATM_AERIAL_RANGE)) * 31.0 + 0.5) / 32.0;
  Vec3 coord = Vec3(uv, z);
  Vec3 scattering = g.atmosphere.aerial_scattering
                        .sample_level(g.atmosphere.sampler, coord, 0)
                        .rgb;
  Vec3 trans = g.atmosphere.aerial_transmittance
                   .sample_level(g.atmosphere.sampler, coord, 0)
                   .rgb;
  return color * trans + scattering * g.sun_color * g.sky_color;
}
