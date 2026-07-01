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
import world_space;
import ddgi_common;

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

  let origin = ddgi_probe_location(ddgi_volume, probe_id);

  RayDesc r;
  r.Origin = origin;
  r.TMin = ray_min_distance;
  r.Direction = direction;
  r.TMax = ray_max_distance;

  RayQuery<RAY_FLAG_NONE> q;
  q.TraceRayInline(pc.tlas.get(), RAY_FLAG_NONE, 0xFF, r);
  q.Proceed();

  // Hit distance is negative on a backface hit, which DDGIVolume_computeProbeOffsets.glc and
  // DDGIVolume_updateProbes.glc read.
  Vec3 radiance;
  float hit_t;
  if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT && !q.CommittedTriangleFrontFace()) {
    // Backface hits record zero irradiance ([2021] §4.1).
    radiance = Vec3(0.0);
    hit_t = -q.CommittedRayT();
  } else if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
    hit_t = q.CommittedRayT();
    let hit_pos = origin + direction * hit_t;

    let geo = pc.geometries[q.CommittedInstanceID()];
    let prim = q.CommittedPrimitiveIndex();
    let i0 = geo.index_buffer[prim * 3 + 0];
    let i1 = geo.index_buffer[prim * 3 + 1];
    let i2 = geo.index_buffer[prim * 3 + 2];
    let v0 = geo.vertex_buffer[i0];
    let v1 = geo.vertex_buffer[i1];
    let v2 = geo.vertex_buffer[i2];

    let bc = q.CommittedTriangleBarycentrics();
    let bary = Vec3(1.0 - bc.x - bc.y, bc.x, bc.y);
    let n_interp = v0.normal * bary.x + v1.normal * bary.y + v2.normal * bary.z;
    // Front-face hit: the interpolated normal already points out toward the ray origin; do
    // NOT negate (the old -n_interp pointed into the surface, killing sun + indirect bounce).
    let N = normalize(mul((float3x3)q.CommittedObjectToWorld3x4(), n_interp));

    var uv = Vec2(v0.uv_x, v0.uv_y) * bary.x + Vec2(v1.uv_x, v1.uv_y) * bary.y + Vec2(v2.uv_x, v2.uv_y) * bary.z;
    if (geo.material_index == 0) {
      uv = get_world_space_uv(hit_pos, N) / 4.0;
    }
    let vcolor = v0.color * bary.x + v1.color * bary.y + v2.color * bary.z;

    let material = pc.materials[geo.material_index];
    let albedo = material.base_color_id.sample_level(pc.global.default_sampler, uv, 0).xyz * vcolor.xyz;

    let l = normalize(pc.global.sun_direction);
    let ndotl = clamp(dot(N, l), 0.0, 1.0);

    // Shadow ray toward the sun (first-hit terminate).
    float shadow = 1.0;
    if (ndotl > 0.0) {
      RayDesc sr;
      // Offset off the surface to avoid self-shadowing; scale with hit distance since
      // ray-hit precision degrades with distance, plus a TMin floor.
      sr.Origin = hit_pos + N * (0.05 + hit_t * 0.005);
      sr.TMin = 0.01;
      sr.Direction = l;
      sr.TMax = 1e4;
      RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> sq;
      sq.TraceRayInline(pc.tlas.get(), RAY_FLAG_NONE, 0xFF, sr);
      sq.Proceed();
      if (sq.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
        shadow = 0.0;
      }
    }

    // Multiple bounces: shade the hit with the probes' own irradiance ([2019] §5.3).
    let indirect = ddgi_sample(pc.volume, hit_pos, N) * ddgi_volume.feedback;

    radiance = albedo * (pc.global.sun_color * ndotl * shadow + indirect);
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
