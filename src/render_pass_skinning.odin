package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
GPUPtr :: gfx.GPUPtr

@(shader_shared)
GPUSkinningPushConstants :: struct #max_field_align(16) {
	input_vertex_buffer:  GPUPtr(Vertex),
	output_vertex_buffer: GPUPtr(Vertex),
	joint_matrices:       GPUPtr(Mat4x4),
	attrs:                GPUPtr(SkeletonVertexAttribute),
	vertex_count:         u32,
}

SkinningRenderPass :: struct {
	skinning_pipeline: ^gfx.ComputePipeline,
}

init_skinning_rp :: proc() {
	game.render_state.skinning_rp.skinning_pipeline = add_compute_shader(
		"shaders/skinning.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Skinning", module, GPUSkinningPushConstants)
		},
	)
}

skinning_pass :: proc(cmd: vk.CommandBuffer, instance: ^SkeletalMeshInstance) {
	gfx.cmd_bind_pipeline(cmd, game.render_state.skinning_rp.skinning_pipeline)

	gfx.cmd_push_constants(
		cmd,
		GPUSkinningPushConstants {
			input_vertex_buffer = instance.skel.buffers.vertex_buffer.ptr,
			output_vertex_buffer = instance.preskinned_vertex_buffers[gfx.current_frame_index()].ptr,
			attrs = instance.skel.buffers.skel_vert_attrs_buffer.ptr,
			joint_matrices = instance.joint_matrices_buffers[gfx.current_frame_index()].ptr,
			vertex_count = instance.skel.buffers.vertex_count,
		},
	)

	gfx.cmd_dispatch(cmd, u32(math.ceil(f32(instance.skel.buffers.vertex_count) / 64.0)))
}
