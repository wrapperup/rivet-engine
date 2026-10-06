import types;

struct DrawIndirectCommand {
	u32 vertexCount;
	u32 instanceCount;
	u32 firstVertex;
	u32 firstInstance;
}

struct ComputeInput {
	u32 group_index : SV_GroupIndex;
};

struct VertexBuffer {
	u32 vertex_count;
	Vertex *vertices;
}

struct Vertex {
	Vec3 position;
	f32 uv_x;
	Vec3 normal;
	f32 uv_y;
	Vec4 color;
};

struct PushConstantData {
	DrawIndirectCommand *draw_commands;
	VertexBuffer *vertex_buffers;
	u32 entity_count;
};

[vk_push_constant]
ConstantBuffer<PushConstantData> push_constants;

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
