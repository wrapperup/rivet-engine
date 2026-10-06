package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
ImageId :: gfx.ImageId

@(shader_shared)
GPUDebugRTPushConstants :: struct #max_field_align(16) {
	global:    gfx.Ptr(GPUGlobalData),
	instances: gfx.Ptr(GPURenderInstance),
	materials: gfx.Ptr(GPUMaterial),
	tlas:      vk.DeviceAddress `AccelerationStructure`,
	out_image: ImageId `RWImage2D`,
}

init_debug_rt_rp :: proc() {
	game.render_state.debug_rt_pipeline = add_compute_shader(
		{"shaders/debug_rt.slang"},
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Debug_RT_Pipeline", module, GPUDebugRTPushConstants)
		},
	)
}

record_debug_rt_pass :: proc(cmd: gfx.CommandBuffer) {
	gfx.transition_image(cmd, gfx.r_ctx.resolve_image, .GENERAL)
	gfx.cmd_bind_pipeline(cmd, game.render_state.debug_rt_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDebugRTPushConstants {
			global = current_frame_game().global_buffer.ptr,
			instances = current_frame_game().instances_buffer.ptr,
			materials = game.render_state.material_store.materials_buffer.ptr,
			tlas = current_frame_game().rt.tlas.address,
			out_image = gfx.r_ctx.resolve_image,
		},
	)

	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.width) / 16.0)),
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.height) / 16.0)),
		1,
	)
}
