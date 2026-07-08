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
import ddgi_common;
import rt_common;

[vk_push_constant]
DDGITracePush pc;

// DDGIVolume_generateRays.glc
[numthreads(384, 1, 1)]
[shader("compute")]
void compute_main(uint3 group_id: SV_GroupID, uint3 thread_id: SV_GroupThreadID) {
  DDGIVolume ddgi_volume = pc.volume[0];

  int probe_id = int(group_id.x);
  int ray_id = int(thread_id.x);
  if (probe_id >= ddgi_num_probes(ddgi_volume) || ray_id >= ddgi_volume.rays_per_probe) {
    return;
  }

  float3 direction = mul(ddgi_random_orientation(ddgi_volume), ddgi_spherical_fibonacci(ray_id, ddgi_volume.rays_per_probe));

  int2 probe_flag_tex_coord = ddgi_probe_tile(ddgi_volume, ddgi_probe_index_to_grid_coord(ddgi_volume, probe_id));
  Vec4 probe_offset = ddgi_read_probe_offset(ddgi_volume, probe_flag_tex_coord);

  // Deviation: rays are limited to ray_max instead of infinity.
  float ray_max_distance = ddgi_volume.ray_max;

  // Don't generate rays for skipped probes.
  // Deviation: skipped probes are the ones that are off; there are no sleeping probes ([2021] §6.2).
  if (int(probe_offset.w) == STATE_OFF) {
    return;
  }

  // Don't bump the ray origin, as the probes cannot intersect themselves.
  // If we bump, we risk putting rays through walls when probes are close to walls.
  const float ray_min_distance = 0.000;

  let s = rt_trace_surface(pc.tlas.get(), pc.geometries, pc.materials, pc.global, ddgi_probe_location(ddgi_volume, probe_id), direction, ray_min_distance, ray_max_distance);

  // Hit distance is negative on a backface hit, which DDGIVolume_computeProbeOffsets.glc and
  // DDGIVolume_updateProbes.glc read.
  Vec3 radiance;
  float hit_t;
  if (s.kind == RTHitKind.Backface) {
    // Backface hits record zero irradiance ([2021] §4.1).
    radiance = Vec3(0.0);
    hit_t = -s.hit_t;
  } else if (s.kind == RTHitKind.Hit) {
    hit_t = s.hit_t;

    // Multiple bounces: shade the hit with the probes' own irradiance ([2019] §5.3).
    let indirect = ddgi_sample_irradiance(pc.global.ddgi_volumes, pc.global.num_ddgi_volumes, s.pos_ws, s.normal, s.normal) * ddgi_volume.feedback;

    let direct = rt_direct_lighting(pc.tlas.get(), pc.global, s.pos_ws, s.normal, s.hit_t, /*sun_shadow*/ true);
    radiance = s.albedo * (direct + indirect);
  } else {
    // Misses record an infinite distance, so they never count as frontfaces in DDGIVolume_computeProbeOffsets.glc.
    hit_t = asfloat(0x7F800000u);
    // sky miss
    let env = pc.global.environment;
    radiance = pc.global.sky_color * env.env_map.sample_level(env.env_sampler, direction, 0).rgb;
  }

  // firefly clamp
  if (ddgi_volume.max_radiance > 0.0) {
    let luma = dot(radiance, Vec3(0.2126, 0.7152, 0.0722));
    if (luma > ddgi_volume.max_radiance) {
      radiance *= ddgi_volume.max_radiance / luma;
    }
  }

  pc.radiance[probe_id * ddgi_volume.rays_per_probe + ray_id] = Vec4(radiance, hit_t);
}
