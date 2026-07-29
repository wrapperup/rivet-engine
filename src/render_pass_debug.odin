package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
GPUPtr :: gfx.GPUPtr
@(private = "file")
ImageId :: gfx.ImageId

@(shader_shared)
GPUDebugRTPushConstants :: struct #max_field_align(16) {
	global:     GPUPtr(GPUGlobalData),
	geometries: GPUPtr(GPUGeometry),
	materials:  GPUPtr(GPUMaterial),
	tlas:       vk.DeviceAddress `AccelerationStructure`,
	out_image:  ImageId `RWImage2D`,
}

init_debug_rt_rp :: proc() {
	game.render_state.debug_rt_pipeline = add_compute_shader(
		"shaders/debug_rt.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Debug_RT_Pipeline", module, GPUDebugRTPushConstants)
		},
	)
}

// Debug visualization: one ray per pixel against the per-frame scene TLAS, written
// into resolve_image. Proves the whole RT chain before DDGI is built on top.
debug_rt_pass :: proc(cmd: vk.CommandBuffer) {
	gfx.cmd_bind_pipeline(cmd, game.render_state.debug_rt_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDebugRTPushConstants {
			global = current_frame_game().global_buffer.ptr,
			geometries = current_frame_game().rt.geometries_buffer.ptr,
			materials = game.render_state.scene_resources.materials_buffer.ptr,
			tlas = current_frame_game().rt.tlas.address,
			out_image = game.render_state.temp_resources.resolved_image_id,
		},
	)

	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.width) / 16.0)),
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.height) / 16.0)),
		1,
	)
}
