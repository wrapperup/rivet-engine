import bindless;
import common;
import types;
import world_space;
import ddgi_common;

// Ray-traced reflection-probe capture: trace one ray per cube texel from the probe
// center and shade the hit (sun + shadow + DDGI indirect, env on miss), writing linear
// radiance into mip 0 of the cube (as a 2D array, 6 layers). Mips are blit afterwards.
// NOTE: the hit shading mirrors ddgi_trace.slang; unify into a shared helper later.

[vk_push_constant]
ReflectionCapturePush pc;

// Standard Vulkan cube face -> world direction. uv in [-1, 1].
Vec3 cube_face_dir(uint face, Vec2 uv) {
  switch (face) {
  case 0:  return Vec3( 1.0, -uv.y, -uv.x); // +X
  case 1:  return Vec3(-1.0, -uv.y,  uv.x); // -X
  case 2:  return Vec3( uv.x,  1.0,  uv.y); // +Y
  case 3:  return Vec3( uv.x, -1.0, -uv.y); // -Y
  case 4:  return Vec3( uv.x, -uv.y,  1.0); // +Z
  default: return Vec3(-uv.x, -uv.y, -1.0); // -Z
  }
}

[numthreads(8, 8, 1)]
[shader("compute")]
void compute_main(uint3 tid: SV_DispatchThreadID) {
  let face = tid.z;
  let size = pc.face_size;
  if (tid.x >= size || tid.y >= size) {
    return;
  }

  let uv = (Vec2(tid.xy) + 0.5) / float(size) * 2.0 - 1.0;
  let dir = normalize(cube_face_dir(face, uv));

  RayDesc r;
  r.Origin = pc.center;
  r.TMin = 0.0;
  r.Direction = dir;
  r.TMax = pc.ray_max;

  RayQuery<RAY_FLAG_NONE> q;
  q.TraceRayInline(pc.tlas.get(), RAY_FLAG_NONE, 0xFF, r);
  q.Proceed();

  Vec3 radiance;
  if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT && !q.CommittedTriangleFrontFace()) {
    radiance = Vec3(0.0); // backface: inside/behind geometry
  } else if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
    let hit_t = q.CommittedRayT();
    let hit_pos = pc.center + dir * hit_t;

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
    // Geometric normal (NOT negated, unlike ddgi_trace/mesh's vertex path — the ray-query
    // interpolated normal already points out of the front face toward the probe).
    let N = normalize(mul((float3x3)q.CommittedObjectToWorld3x4(), n_interp));

    var muv = Vec2(v0.uv_x, v0.uv_y) * bary.x + Vec2(v1.uv_x, v1.uv_y) * bary.y + Vec2(v2.uv_x, v2.uv_y) * bary.z;
    if (geo.material_index == 0) {
      muv = get_world_space_uv(hit_pos, N) / 4.0;
    }
    let vcolor = v0.color * bary.x + v1.color * bary.y + v2.color * bary.z;

    let material = pc.materials[geo.material_index];
    let albedo = material.base_color_id.sample_level(pc.global.default_sampler, muv, 0).xyz * vcolor.xyz;

    let l = normalize(pc.global.sun_direction);
    let ndotl = clamp(dot(N, l), 0.0, 1.0);

    float shadow = 1.0;
    if (ndotl > 0.0) {
      RayDesc sr;
      // Distance-scaled offset to avoid self-shadowing (matches ddgi_trace.slang).
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

    // Match the forward pass's GI brightness: same volume-array select + per-volume display
    // intensity as mesh.slang (NOT feedback, which is the DDGI bounce-recursion gain). The
    // "viewer" for the surface bias is the capture center (where this ray came from).
    let indirect = ddgi_sample_volumes(pc.global.ddgi_volumes, pc.global.num_ddgi_volumes, hit_pos, N, pc.center);
    radiance = albedo * (pc.global.sun_color * ndotl * shadow + indirect);
  } else {
    let env = pc.global.environment;
    radiance = pc.global.sky_color * env.env_map.sample_level(env.env_sampler, dir, 0).rgb;
  }

  pc.out_cube.store(uint3(tid.x, tid.y, face), Vec4(radiance, 1.0));
}
