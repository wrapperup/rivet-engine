import bindless;
import common;
import types;
import world_space;
import lights;

enum RTHitKind {
  Miss,
  Backface,
  Hit,
}

struct RTSurface {
  RTHitKind kind;
  f32 hit_t;
  Vec3 pos_ws;
  Vec3 normal;
  Vec3 normal_mapped;
  Vec3 albedo;
  u32 material_index;
}

RTSurface rt_trace_surface(RaytracingAccelerationStructure tlas, Geometry* geometries, Material* materials, GlobalData* g,
                           Vec3 origin, Vec3 dir, f32 tmin, f32 tmax) {
  return _rt_trace_surface(false, tlas, geometries, materials, g, origin, dir, tmin, tmax);
}

RTSurface rt_trace_surface_detailed(RaytracingAccelerationStructure tlas, Geometry* geometries, Material* materials, GlobalData* g,
                                    Vec3 origin, Vec3 dir, f32 tmin, f32 tmax) {
  return _rt_trace_surface(true, tlas, geometries, materials, g, origin, dir, tmin, tmax);
}

RTSurface _rt_trace_surface(bool detailed, RaytracingAccelerationStructure tlas, Geometry* geometries, Material* materials, GlobalData* g,
                            Vec3 origin, Vec3 dir, f32 tmin, f32 tmax) {
  RayDesc r;
  r.Origin = origin;
  r.TMin = tmin;
  r.Direction = dir;
  r.TMax = tmax;

  RayQuery<RAY_FLAG_NONE> q;
  q.TraceRayInline(tlas, RAY_FLAG_NONE, 0xFF, r);
  q.Proceed();

  RTSurface s;
  s.kind = RTHitKind.Miss;
  s.hit_t = 0.0;
  s.pos_ws = Vec3(0.0);
  s.normal = Vec3(0.0);
  s.normal_mapped = Vec3(0.0);
  s.albedo = Vec3(0.0);
  s.material_index = 0;

  if (q.CommittedStatus() != COMMITTED_TRIANGLE_HIT) {
    return s;
  }

  s.hit_t = q.CommittedRayT();
  if (!q.CommittedTriangleFrontFace()) {
    s.kind = RTHitKind.Backface;
    return s;
  }

  s.kind = RTHitKind.Hit;
  s.pos_ws = origin + dir * s.hit_t;

  let geo = geometries[q.CommittedInstanceID()];
  let prim = q.CommittedPrimitiveIndex();
  let i0 = geo.index_buffer[prim * 3 + 0];
  let i1 = geo.index_buffer[prim * 3 + 1];
  let i2 = geo.index_buffer[prim * 3 + 2];
  let v0 = geo.vertex_buffer[i0];
  let v1 = geo.vertex_buffer[i1];
  let v2 = geo.vertex_buffer[i2];

  let bc = q.CommittedTriangleBarycentrics();
  let bary = Vec3(1.0 - bc.x - bc.y, bc.x, bc.y);
  let o2w = (Mat3x3)q.CommittedObjectToWorld3x4();
  let n_interp = v0.normal * bary.x + v1.normal * bary.y + v2.normal * bary.z;
  s.normal = normalize(mul(o2w, n_interp));
  s.normal_mapped = s.normal;
  s.material_index = geo.material_index;

  let vcolor = v0.color * bary.x + v1.color * bary.y + v2.color * bary.z;
  var uv = Vec2(v0.uv_x, v0.uv_y) * bary.x + Vec2(v1.uv_x, v1.uv_y) * bary.y + Vec2(v2.uv_x, v2.uv_y) * bary.z;
  let material = materials[geo.material_index];

  if (detailed) {
    let n_raster = normalize(mul(o2w, -n_interp));
    var tangent = v0.tangent * bary.x + v1.tangent * bary.y + v2.tangent * bary.z;
    if (geo.material_index == 0) {
      tangent = get_world_space_tangent(n_raster);
      uv = get_world_space_uv(s.pos_ws, n_raster) / 4.0;
    }

    let T = normalize(mul(o2w, tangent.xyz));
    let B = cross(n_raster, T) * tangent.w;
    let tbn = Mat3x3(T, B, n_raster);

    // Compute shader: no derivatives, so explicit LOD 0 (sample_level, not sample).
    var tex_normal = material.normal_map_id.sample_level(g.default_sampler, uv, 0).rgb * 2.0 - 1.0;
    tex_normal.y *= -1;
    s.normal_mapped = normalize(mul(tex_normal, tbn));
  } else if (geo.material_index == 0) {
    uv = get_world_space_uv(s.pos_ws, s.normal) / 4.0;
  }

  s.albedo = material.base_color_id.sample_level(g.default_sampler, uv, 0).xyz * vcolor.xyz;
  return s;
}

// Offset off the surface to avoid self-shadowing; scale with hit distance since
// ray-hit precision degrades with distance, plus the shadow ray's TMin floor.
Vec3 rt_offset_origin(Vec3 pos_ws, Vec3 N, f32 hit_t) {
  return pos_ws + N * (0.05 + hit_t * 0.005);
}

// 1 = lit, 0 = occluded. First-hit-terminate ray query.
f32 rt_shadow_ray(RaytracingAccelerationStructure tlas, Vec3 origin, Vec3 dir, f32 tmax) {
  RayDesc sr;
  sr.Origin = origin;
  sr.TMin = 0.01;
  sr.Direction = dir;
  sr.TMax = tmax;
  RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> sq;
  sq.TraceRayInline(tlas, RAY_FLAG_NONE, 0xFF, sr);
  sq.Proceed();
  return sq.CommittedStatus() == COMMITTED_TRIANGLE_HIT ? 0.0 : 1.0;
}

Vec3 rt_point_lights(GlobalData* g, Vec3 pos_ws, Vec3 N) {
  Vec3 sum = Vec3(0.0);
  let env = g.environment;
  for (uint i = 0; i < env.point_lights.count; i++) {
    let light = env.point_lights[i];
    let to_light = light.world_pos - pos_ws;
    let dist = length(to_light);
    if (dist > light.radius) {
      continue;
    }
    let ndotl = saturate(dot(N, to_light / dist));
    let attenuation = get_square_falloff_attenuation(to_light, 1.0 / light.radius);
    sum += normalize(light.color) * (light.lumens * attenuation * ndotl);
  }
  return sum;
}

Vec3 rt_direct_lighting(RaytracingAccelerationStructure tlas, GlobalData* g, Vec3 pos_ws, Vec3 N, f32 hit_t, bool sun_shadow) {
  let l = normalize(g.sun_direction);
  let ndotl = clamp(dot(N, l), 0.0, 1.0);

  var shadow = 1.0;
  if (sun_shadow && ndotl > 0.0) {
    shadow = rt_shadow_ray(tlas, rt_offset_origin(pos_ws, N, hit_t), l, 1e4);
  }

  return g.sun_color * ndotl * shadow + rt_point_lights(g, pos_ws, N);
}
