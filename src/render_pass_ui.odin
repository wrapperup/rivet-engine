package game

import "core:slice"
import "gfx"

@(shader_shared)
UI_Command :: struct #max_field_align(16) {
	pos:    Vec2,
	size:   Vec2,
	color:  Vec4,
	radius: Vec4, // clockwise from top-left corner
}

@(shader_shared)
UI_Push :: struct #max_field_align(16) {
	commands:      gfx.Slice(UI_Command),
	viewport_size: Vec2,
}

UIRenderPass :: struct {
	pipeline:        ^gfx.GraphicsPipeline,
	commands:        [dynamic]UI_Command,
	num_commands:    int,
	command_buffers: [gfx.FRAME_OVERLAP]gfx.Buffer(UI_Command),
}

MAX_UI_COMMANDS :: 256

init_ui_rp :: proc() {
	ui_rp := &game.render_state.ui_rp

	ui_rp.pipeline = add_graphics_shader("shaders/ui.slang", proc(module: gfx.ShaderModule) -> gfx.GraphicsPipeline {
		return gfx.create_graphics_pipeline(
			name = "UI_Pipeline",
			shader = module,
			input_topology = .TRIANGLE_STRIP,
			polygon_mode = .FILL,
			cull_mode = {},
			front_face = .CLOCKWISE,
			color_format = gfx.r_ctx.draw_image.format,
			multisampling_samples = ._1,
			push_constants = UI_Push,
			blend_mode = .Alpha,
		)
	})

	for i in 0 ..< gfx.FRAME_OVERLAP {
		buffer := gfx.create_buffer(UI_Command, MAX_UI_COMMANDS, .Storage, "UI_Command_Buffer")
		ui_rp.command_buffers[i] = buffer
		gfx.defer_destroy(&gfx.r_ctx.global_arena, buffer)
	}

	reserve(&game.render_state.geometry_rp.model_matrices, 16_000)
}

ui_append_command :: proc(pos: Vec2, size: Vec2, color: Vec4 = 1, radius: Vec4 = 0) {
	radius := radius

	half_size := size / 2
	max_radius := slice.min(half_size[:])

	for &r in radius {
		r = min(r, max_radius)
	}

	command := UI_Command {
		pos    = pos,
		size   = size,
		color  = color,
		radius = radius,
	}

	append(&game.render_state.ui_rp.commands, command)
}

ui_prepare :: proc() {
	ui_rp := &game.render_state.ui_rp

	assert(len(ui_rp.commands) < MAX_UI_COMMANDS, "Submitted too many UI commands.")

	if len(ui_rp.commands) > 0 {
		gfx.staging_write_buffer_slice(&ui_rp.command_buffers[gfx.current_frame_index()], ui_rp.commands[:])
	}

	ui_rp.num_commands = len(ui_rp.commands)
	clear(&ui_rp.commands)
}

record_ui_pass :: proc(cmd: gfx.CommandBuffer) {
	gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .COLOR_ATTACHMENT_OPTIMAL)

	{
		gfx.cmd_begin_rendering(
			cmd,
			area = gfx.r_ctx.draw_extent,
			color_attachment = &{view = gfx.r_ctx.resolve_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		)

		gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)

		gfx.cmd_bind_pipeline(cmd, game.render_state.ui_rp.pipeline)

		commands := gfx.slice(game.render_state.ui_rp.command_buffers[gfx.current_frame_index()])
		gfx.cmd_push_constants(cmd, UI_Push{commands = commands, viewport_size = auto_cast (transmute([2]u32)game.renderer.draw_extent)})

		gfx.cmd_draw(cmd, 4, u32(game.render_state.ui_rp.num_commands))

		gfx.cmd_end_rendering(cmd)
	}
}
