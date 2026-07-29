package game

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
GPUPtr :: gfx.GPUPtr
@(private = "file")
ImageId :: gfx.ImageId

@(shader_shared)
GPUDrawPushConstants :: struct #max_field_align(16) {
	global_data_buffer: GPUPtr(GPUGlobalData),
	vertex_buffer:      GPUPtr(Vertex),
	model_matrices:     GPUPtr(Mat4x4),
	materials:          GPUPtr(GPUMaterial),
	model_index:        u32,
	material_index:     MaterialId,
	num_cascades:       u32,
	shadow_depth:       ImageId `Image2DArray<f32>`,
	shadow_sampler:     gfx.SamplerId `SamplerComparison`,
}

@(shader_shared)
GPUSkyboxPushConstants :: struct #max_field_align(16) {
	vertex_buffer:      GPUPtr(Vertex),
	global_data_buffer: GPUPtr(GPUGlobalData),
}

GeometryRenderPass :: struct {
	mesh_pipeline:  ^gfx.GraphicsPipeline,
	model_matrices: [dynamic]Mat4x4,
}

// TODO: Encode this as indirect draw args instead.
MeshDraw :: struct {
	vertex_buffer:  GPUPtr(Vertex),
	index_buffer:   vk.Buffer,
	index_count:    u32,
	model_index:    u32,
	material_index: MaterialId,
}

init_geometry_rp :: proc() {
	game.render_state.geometry_rp.mesh_pipeline = add_graphics_shader(
		"shaders/mesh.slang",
		proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
			return gfx.create_graphics_pipeline(
				name = "Basic_Mesh_Pipeline",
				shader = module,
				input_topology = .TRIANGLE_LIST,
				polygon_mode = .FILL,
				cull_mode = {.BACK},
				front_face = .COUNTER_CLOCKWISE,
				depth = {format = gfx.r_ctx.depth_image.format, compare_op = .LESS_OR_EQUAL, write_enabled = true},
				color_format = gfx.r_ctx.draw_image.format,
				multisampling_samples = gfx.msaa_samples(),
				push_constants = GPUDrawPushConstants,
			)
		},
	)
}

init_skybox_rp :: proc() {
	game.render_state.skybox_pipeline = add_graphics_shader("shaders/skybox.slang", proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
			return gfx.create_graphics_pipeline(
				name = "Skybox_Pipeline",
				shader = module,
				input_topology = .TRIANGLE_LIST,
				polygon_mode = .FILL,
				cull_mode = {.BACK},
				front_face = .COUNTER_CLOCKWISE,
				depth = {format = gfx.r_ctx.depth_image.format, compare_op = .LESS_OR_EQUAL, write_enabled = true},
				color_format = gfx.r_ctx.draw_image.format,
				multisampling_samples = gfx.msaa_samples(),
				push_constants = GPUSkyboxPushConstants,
			)
		})
}

geometry_pass :: proc(cmd: vk.CommandBuffer) {
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .GENERAL},
		depth_attachment = &{
			view = gfx.r_ctx.depth_image.image_view,
			clear_value = &{depthStencil = {depth = 1.0}},
			layout = .DEPTH_ATTACHMENT_OPTIMAL,
		},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)

	gfx.cmd_bind_pipeline(cmd, game.render_state.geometry_rp.mesh_pipeline)

	for mesh_draw in current_frame_game().mesh_draws {
		gfx.cmd_bind_index_buffer(cmd, mesh_draw.index_buffer)
		gfx.cmd_push_constants(
			cmd,
			GPUDrawPushConstants {
				global_data_buffer = current_frame_game().global_buffer.ptr,
				vertex_buffer = mesh_draw.vertex_buffer,
				model_matrices = current_frame_game().model_matrices_buffer.ptr,
				materials = game.render_state.scene_resources.materials_buffer.ptr,
				model_index = mesh_draw.model_index,
				material_index = mesh_draw.material_index,
				num_cascades = NUM_CASCADES,
				shadow_depth = game.render_state.shadow_rp.shadow_depth_image_id,
				shadow_sampler = game.render_state.temp_resources.shadow_depth_sampler_id,
			},
		)

		gfx.cmd_draw_indexed(cmd, mesh_draw.index_count)
	}

	gfx.cmd_end_rendering(cmd)
}

skybox_pass :: proc(cmd: vk.CommandBuffer) {
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		depth_attachment = &{
			view = gfx.r_ctx.depth_image.image_view,
			clear_value = &{depthStencil = {depth = 1.0}},
			layout = .DEPTH_ATTACHMENT_OPTIMAL,
		},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)

	gfx.cmd_bind_pipeline(cmd, game.render_state.skybox_pipeline)
	gfx.cmd_bind_index_buffer(cmd, game.render_state.skybox_mesh.index_buffer.buffer)
	gfx.cmd_push_constants(
		cmd,
		GPUSkyboxPushConstants {
			vertex_buffer = game.render_state.skybox_mesh.vertex_buffer.ptr,
			global_data_buffer = current_frame_game().global_buffer.ptr,
		},
	)

	gfx.cmd_draw_indexed(cmd, game.render_state.skybox_mesh.index_count)
	gfx.cmd_end_rendering(cmd)
}
