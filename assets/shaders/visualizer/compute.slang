struct DrawIndirectCommand {
  uint32_t vertexCount;
  uint32_t instanceCount;
  uint32_t firstVertex;
  uint32_t firstInstance;
}

struct ComputeInput {
  uint group_index : SV_GroupIndex;
};

struct PushConstantData {
  uint8_t *voxel_buffer;
  DrawIndirectCommand *draw_commands;
  uint frame_time;
};

[vk_push_constant]
ConstantBuffer<PushConstantData> push_constants;

[numthreads(4, 4, 4)]
[shader("compute")]
void write_voxel_data(uint3 id: SV_DispatchThreadID) {
  uint index = id.x + (id.y * 32) + ((id.z * 32) * 32);

  var color = sin(id.x / 5.0 + push_constants.frame_time / 100.0);
  color += sin(id.y / 5.0 + push_constants.frame_time / 110.0);
  color += sin(id.z / 5.0 + push_constants.frame_time / 120.0);

  color /= 3.f;

  push_constants.voxel_buffer[index] = uint8_t((color + 1.f) * 8.f);
}

[numthreads(1, 1, 1)]
[shader("compute")]
void write_draw_cmd() {
  DrawIndirectCommand draw_cmd;

  draw_cmd.vertexCount = 36 * (32 * 32 * 32);
  draw_cmd.firstVertex = 0;
  draw_cmd.instanceCount = 1;
  draw_cmd.firstInstance = 0;

  push_constants.draw_commands[0] = draw_cmd;
}
