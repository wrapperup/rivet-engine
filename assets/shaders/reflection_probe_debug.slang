import bindless;
import common;
import types;

// Debug gizmo: a perfect mirror sphere at the reflection probe's capture point, sampling
// the captured cube along the reflection vector (mip 0 = perfectly specular). Renders into
// the HDR scene (linear out -> tonemapped downstream).
[vk_push_constant]
ReflectionProbeDebugPush pc;

struct V2F {
  Vec4 pos_cs : SV_Position;
  Vec3 normal_ws;
  Vec3 world_ws;
};

[shader("vertex")]
V2F vertex_main(uint vid: SV_VertexID) {
  let vert = pc.vertex_buffer[vid];
  let world = pc.center + vert.position * pc.radius;

  let world_to_clip = mul(pc.global.view_to_clip, pc.global.world_to_view);

  V2F o;
  o.pos_cs = mul(world_to_clip, Vec4(world, 1.0));
  o.normal_ws = normalize(vert.normal);
  o.world_ws = world;
  return o;
}

[shader("fragment")]
Vec4 fragment_main(V2F i) : SV_Target {
  let probe = pc.probe;
  let n = normalize(i.normal_ws);
  let v = normalize(pc.global.camera_pos - i.world_ws);
  let r = reflect(-v, n);
  let refl = probe.cube.sample_level(probe.sampler, r, 0.0).rgb * probe.intensity;
  return Vec4(refl, 1.0);
}
