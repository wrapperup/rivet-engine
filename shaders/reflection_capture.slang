import bindless;
import common;
import types;
import ddgi_common;
import rt_common;

// Ray-traced reflection-probe capture: trace one ray per cube texel from the probe
// center and shade the hit (sun + point lights + DDGI indirect, env on miss), writing
// linear radiance into mip 0 of the cube (as a 2D array, 6 layers). Mips are blit afterwards.

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

  let s = rt_trace_surface(pc.tlas.get(), pc.geometries, pc.materials, pc.global, pc.center, dir, 0.0, pc.ray_max);

  Vec3 radiance;
  if (s.kind == RTHitKind.Backface) {
    radiance = Vec3(0.0); // backface: inside/behind geometry
  } else if (s.kind == RTHitKind.Hit) {
    // Match the forward pass's GI brightness: same volume-array select + per-volume display
    // intensity as mesh.slang (NOT feedback, which is the DDGI bounce-recursion gain). The
    // "viewer" for the surface bias is the capture center (where this ray came from).
    let indirect = ddgi_sample_volumes(pc.global.ddgi_volumes, pc.global.num_ddgi_volumes, s.pos_ws, s.normal, pc.center);
    let direct = rt_direct_lighting(pc.tlas.get(), pc.global, s.pos_ws, s.normal, s.hit_t, /*sun_shadow*/ true);
    radiance = s.albedo * (direct + indirect);
  } else {
    let env = pc.global.environment;
    radiance = pc.global.sky_color * env.env_map.sample_level(env.env_sampler, dir, 0).rgb;
  }

  pc.out_cube.store(uint3(tid.x, tid.y, face), Vec4(radiance, 1.0));
}
