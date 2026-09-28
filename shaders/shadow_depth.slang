import common;
import types;

struct VertexInput {
  u32 vertex_index : SV_VertexID;
};

[vk_push_constant]
DrawShadowDepthPushConstants pc;

struct V2PShadow {
  Vec4 pos : SV_Position;
}

[shader("vertex")]
V2PShadow vertex_main(VertexInput input) {
  let instance = pc.instances[pc.instance_index];
  let vertex = instance.vertex_buffer[input.vertex_index];

  let model_to_world = instance.model_to_world;
  let world_to_clip = pc.global_data.cascade_world_to_shadows[pc.cascade_index];

  V2PShadow output;
  output.pos =
      mul(world_to_clip, mul(model_to_world, Vec4(vertex.position, 1.0)));

  return output;
}
