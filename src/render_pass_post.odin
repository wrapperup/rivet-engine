package game

import "core:math"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
ImageId :: gfx.ImageId
@(private = "file")
SamplerId :: gfx.SamplerId

@(shader_shared)
GPUPostProcessingPushConstants :: struct #max_field_align(16) {
	resolved_image:  ImageId `RWImage2D`,
	tony_mc_mapface: ImageId `Image3D<Vec3>`,
	sampler:         SamplerId `Sampler`,
}

PostProcessingRenderPass :: struct {
	tony_mc_mapface_id:  ImageId,
	tonemapper_pipeline: ^gfx.ComputePipeline,
}

init_post_process_rp :: proc() {
	game.render_state.post_process_rp.tonemapper_pipeline = add_compute_shader(
		"shaders/tonemapping.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Tonemapper_Pipeline", module, GPUPostProcessingPushConstants)
		},
	)
}

record_post_process_pass :: proc(cmd: vk.CommandBuffer) {
	gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .GENERAL)
	gfx.cmd_bind_pipeline(cmd, game.render_state.post_process_rp.tonemapper_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUPostProcessingPushConstants {
			resolved_image = game.render_state.temp_resources.resolved_image_id,
			tony_mc_mapface = game.render_state.post_process_rp.tony_mc_mapface_id,
			sampler = game.render_state.temp_resources.default_sampler_id,
		},
	)

	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.width) / 16.0)),
		u32(math.ceil(f32(gfx.r_ctx.draw_extent.height) / 16.0)),
		1,
	)
}
