import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereCubePush pc;

[numthreads(8, 8, 1)]
[shader("compute")]
void compute_main(Vec3u32 tid : SV_DispatchThreadID) {
  if (tid.x >= 256 || tid.y >= 256)
    return;
  Vec2 uv = (Vec2(tid.xy) + 0.5) / 256.0 * 2 - 1;
  Vec3 dir;
  switch (tid.z) {
  case 0:
    dir = Vec3(1, -uv.y, -uv.x);
    break;
  case 1:
    dir = Vec3(-1, -uv.y, uv.x);
    break;
  case 2:
    dir = Vec3(uv.x, 1, uv.y);
    break;
  case 3:
    dir = Vec3(uv.x, -1, -uv.y);
    break;
  case 4:
    dir = Vec3(uv.x, -uv.y, 1);
    break;
  default:
    dir = Vec3(-uv.x, -uv.y, -1);
    break;
  }
  // The sun disk is evaluated by direct lighting, never duplicated in IBL.
  pc.output.store(tid, Vec4(atmosphere_sky(pc.global, normalize(dir)), 1));
}
