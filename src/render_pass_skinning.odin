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

init_skinning_instance :: proc(instance: ^SkeletalMeshInstance, animation: ^SkeletalAnimation) {
	init_skeleton_animator(&instance.animator, instance.skel, animation)

	for i in 0 ..< gfx.FRAME_OVERLAP {
		instance.joint_matrices_buffers[i] = gfx.create_buffer(
			Mat4x4,
			instance.skel.joint_count,
			.DynUniform,
		)
		instance.preskinned_vertex_buffers[i] = gfx.create_buffer(Vertex, instance.skel.buffers.vertex_count, .DynUniform)

		gfx.defer_destroy_buffer(&gfx.r_ctx.global_arena, instance.joint_matrices_buffers[i])
		gfx.defer_destroy_buffer(&gfx.r_ctx.global_arena, instance.preskinned_vertex_buffers[i])
	}
}

skinning_prepare :: proc(instances: []^SkeletalMeshInstance) {
	frame_index := gfx.current_frame_index()
	for instance in instances {
		sample_animation(&instance.animator, f32(game.live_time))
		gfx.write_buffer_slice(&instance.joint_matrices_buffers[frame_index], instance.animator.calc_joints[:])
	}
}

record_skinning_pass :: proc(cmd: vk.CommandBuffer, instances: []^SkeletalMeshInstance) {
	if len(instances) == 0 do return

	gfx.cmd_bind_pipeline(cmd, game.render_state.skinning_rp.skinning_pipeline)
	frame_index := gfx.current_frame_index()

	for instance in instances {
		output := instance.preskinned_vertex_buffers[frame_index]
		gfx.buffer_barrier(
			cmd,
			output,
			src_access = .VertexShaderRead,
			dst_access = .ComputeShaderWrite,
		)

		gfx.cmd_push_constants(
			cmd,
			GPUSkinningPushConstants {
				input_vertex_buffer = instance.skel.buffers.vertex_buffer.ptr,
				output_vertex_buffer = output.ptr,
				attrs = instance.skel.buffers.skel_vert_attrs_buffer.ptr,
				joint_matrices = instance.joint_matrices_buffers[frame_index].ptr,
				vertex_count = instance.skel.buffers.vertex_count,
			},
		)

		gfx.cmd_dispatch(cmd, u32(math.ceil(f32(instance.skel.buffers.vertex_count) / 64.0)))

		gfx.buffer_barrier(
			cmd,
			output,
			src_access = .ComputeShaderWrite,
			dst_access = .VertexShaderRead,
		)
	}
}
