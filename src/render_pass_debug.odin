package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
Image_Id :: gfx.Image_Id

@(shader_shared)
GPUDebugRTPushConstants :: struct #max_field_align(16) {
	global:    gfx.Ptr(GPUGlobalData),
	instances: gfx.Ptr(GPURenderInstance),
	materials: gfx.Ptr(GPUMaterial),
	tlas:      vk.DeviceAddress `AccelerationStructure`,
	out_image: Image_Id `RWImage2D`,
}

init_debug_rt_rp :: proc() {
	game.render_state.debug_rt_pipeline = add_compute_shader({"shaders/debug_rt.slang"}, "Debug_RT_Pipeline", GPUDebugRTPushConstants)
}

record_debug_rt_pass :: proc(cmd: gfx.Command_Buffer) {
    state := &game.render_state

	gfx.transition_image(cmd, state.resolve_image, .General)
	gfx.cmd_bind_pipeline(cmd, game.render_state.debug_rt_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDebugRTPushConstants {
			global = current_frame_game().global_buffer.ptr,
			instances = current_frame_game().instances_buffer.ptr,
			materials = game.render_state.material_store.materials_buffer.ptr,
			tlas = current_frame_game().rt.tlas.address,
			out_image = state.resolve_image,
		},
	)

	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(state.draw_extent.x) / 16.0)),
		u32(math.ceil(f32(state.draw_extent.y) / 16.0)),
		1,
	)
}
