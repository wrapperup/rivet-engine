package game

import "gfx"
import vk "vendor:vulkan"

UIPass :: struct {
	using render_pass:  RenderPass,
	ui_pipeline:        ^gfx.ComputePipeline,
}

create_ui_pass :: proc() -> UIPass {
	ui_pass := UIPass {
		render_pass = {
			{{name = "draw_image", layout = .GENERAL}, {name = "depth_image", layout = .DEPTH_ATTACHMENT_OPTIMAL}},
			ui_pass_init,
			ui_pass_run,
		},
	}

	return ui_pass
}

ui_pass_init :: proc(this: rawptr) {
	ui_pass := cast(^UIPass)this
	ui_pass.ui_pipeline = add_compute_shader("shaders/ui.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("UI_Pipeline", module, GPUPostProcessingPushConstants)
	})
}

ui_pass_run :: proc(this: rawptr, cmd: vk.CommandBuffer) {
	// ui_pass := cast(^UIPass)this
	//
	// gfx.cmd_bind_pipeline(cmd, ui_pass.ui_pipeline^)
	//
	// gfx.cmd_push_constants(
	// 	cmd,
	// 	GPUPostProcessingPushConstants{resolved_image = game.render_state.temp_resources.resolved_image_id},
	// )
	//
	// vk.CmdDispatch(
	// 	cmd,
	// 	u32(math.ceil(f32(gfx.r_ctx.draw_extent.width) / 16.0)),
	// 	u32(math.ceil(f32(gfx.r_ctx.draw_extent.height) / 16.0)),
	// 	1,
	// )
}
