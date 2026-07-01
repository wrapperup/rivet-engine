import bindless;
import brdf;
import common;
import types;

// Roughness prefilter for a reflection-probe cube: GGX importance-sample the captured cube
// (mip 0) into each roughness mip. Kernel matches tools/prefilter_env.slang; I/O is bindless
// (reads the cube via an ImageCube id, writes one mip via a 2D-array id). Dispatched per mip
// in reflection_probe_capture, replacing the box-blit.

[vk_push_constant]
ReflectionPrefilterPush pc;

// Standard Vulkan cube face -> world direction (matches reflection_capture.slang). uv in [-1,1].
Vec3 cube_face_dir(uint face, Vec2 uv) {
  switch (face) {
  case 0:  return Vec3( 1.0, -uv.y, -uv.x);
  case 1:  return Vec3(-1.0, -uv.y,  uv.x);
  case 2:  return Vec3( uv.x,  1.0,  uv.y);
  case 3:  return Vec3( uv.x, -1.0, -uv.y);
  case 4:  return Vec3( uv.x, -uv.y,  1.0);
  default: return Vec3(-uv.x, -uv.y, -1.0);
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
  let N = normalize(cube_face_dir(face, uv));
  let V = N;

  Vec3 sum = Vec3(0.0);
  float wsum = 0.0;
  for (uint i = 0; i < pc.sample_count; i++) {
    let Xi = hammersley(i, float(pc.sample_count));
    let H = importance_sample_ggx(Xi, N, pc.roughness);
    let L = normalize(2.0 * dot(V, H) * H - V);
    let NoL = max(dot(N, L), 0.0);
    if (NoL > 0.0) {
      sum += pc.src_cube.sample_level(pc.sampler, L, 0.0).rgb * NoL;
      wsum += NoL;
    }
  }

  let color = wsum > 0.0 ? sum / wsum : Vec3(0.0);
  pc.out_mip.store(uint3(tid.x, tid.y, face), Vec4(color, 1.0));
}
