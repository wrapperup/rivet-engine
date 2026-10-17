package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(shader_shared)
GPUPostProcessingPushConstants :: struct #max_field_align(16) {
	resolved_image:  gfx.Image_Id `RWImage2D`,
	tony_mc_mapface: gfx.Image_Id `Image3D<Vec3>`,
	sampler:         gfx.Sampler_Id `Sampler`,
}

PostProcessingRenderPass :: struct {
	tony_mc_mapface_id:  gfx.Image_Id,
	tonemapper_pipeline: ^gfx.Pipeline,
}

init_post_process_rp :: proc() {
	game.render_state.post_process_rp.tonemapper_pipeline = add_compute_shader(
		{"shaders/tonemapping.slang"},
		"Tonemapper_Pipeline",
		GPUPostProcessingPushConstants,
	)
}

record_post_process_pass :: proc(cmd: gfx.Command_Buffer) {
    state := &game.render_state

	gfx.transition_image(cmd, game.render_state.resolve_image, .GENERAL)
	gfx.cmd_bind_pipeline(cmd, game.render_state.post_process_rp.tonemapper_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUPostProcessingPushConstants {
			resolved_image = state.resolve_image,
			tony_mc_mapface = game.render_state.post_process_rp.tony_mc_mapface_id,
			sampler = game.render_state.temp_resources.default_sampler_id,
		},
	)

	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(state.draw_extent.width) / 16.0)),
		u32(math.ceil(f32(state.draw_extent.height) / 16.0)),
		1,
	)
}
