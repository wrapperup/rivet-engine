package game

import vk "vendor:vulkan"

import "gfx"

@(shader_shared)
GPUGeometryDebugView :: enum u32 {
	None,
    Shadow,
    No_Shadow,
    Base_Color,
    Normal,
    Tangent,
    Bitangent,
    Irradiance,
    Specular,
}

@(shader_shared)
GPUDrawPushConstants :: struct #max_field_align(16) {
	global_data_buffer: gfx.Ptr(GPUGlobalData),
	instances:          gfx.Ptr(GPURenderInstance),
	materials:          gfx.Ptr(GPUMaterial),
	instance_index:     u32,
	num_cascades:       u32,
	shadow_depth:       gfx.Image_Id `Image2DArray<f32>`,
	shadow_sampler:     gfx.Sampler_Id `SamplerComparison`,
}

GeometryRenderPass :: struct {
	depth_pipeline: ^gfx.Pipeline,
	mesh_pipeline:  ^gfx.Pipeline,
}

init_geometry_rp :: proc() {
	// Match vertex and raster state in both passes for depth equality.
	game.render_state.geometry_rp.depth_pipeline = add_graphics_shader(
		{"shaders/mesh.slang"},
		"Mesh_Depth_Prepass",
		GPUDrawPushConstants,
		{
			depth_only = true,
			cull_mode = {.BACK},
			depth = {format = DEPTH_FORMAT, compare_op = .GREATER_OR_EQUAL, write_enabled = true},
			msaa_sample_count = game.render_state.msaa_samples,
		},
	)
	game.render_state.geometry_rp.mesh_pipeline = add_graphics_shader(
		{"shaders/mesh.slang"},
		"Basic_Mesh_Pipeline",
		GPUDrawPushConstants,
		{
			cull_mode = {.BACK},
			depth = {format = DEPTH_FORMAT, compare_op = .EQUAL, write_enabled = false},
			color_format = DRAW_FORMAT,
			msaa_sample_count = game.render_state.msaa_samples,
		},
	)

}

record_geometry_pass :: proc(cmd: gfx.Command_Buffer, instances: []RenderInstance) {
    state := &game.render_state

	gfx.transition_image(cmd, state.draw_image, .COLOR_ATTACHMENT_OPTIMAL)
	gfx.transition_image(cmd, state.depth_image, .DEPTH_ATTACHMENT_OPTIMAL)
	gfx.transition_image(cmd, game.render_state.shadow_rp.shadow_depth_image, .DEPTH_READ_ONLY_OPTIMAL)
	record_geometry_depth_pass(cmd, instances)
	gfx.image_barrier(cmd, state.depth_image, src_access = .Depth_Attachment_Read_Write, dst_access = .Depth_Attachment_Read_Write)

	if game.render_state.draw_sky {
		record_atmosphere_background(cmd)
	}
	background_clear := vk.ClearValue {
		color = {float32 = {0, 0, 0, 1}},
	}

	gfx.cmd_begin_rendering(
		cmd,
		area = state.draw_extent,
		color_attachment = &{
			view = state.draw_image,
			layout = .COLOR_ATTACHMENT_OPTIMAL,
			clear_value = game.render_state.draw_sky ? nil : &background_clear,
		},
		depth_attachment = &{view = state.depth_image, layout = .DEPTH_ATTACHMENT_OPTIMAL},
	)

	gfx.cmd_bind_pipeline(cmd, game.render_state.geometry_rp.mesh_pipeline)
	record_geometry_draws(cmd, instances)

	gfx.cmd_end_rendering(cmd)
}

record_geometry_depth_pass :: proc(cmd: gfx.Command_Buffer, instances: []RenderInstance) {
    state := &game.render_state

	gfx.cmd_begin_rendering(
		cmd,
		area = state.draw_extent,
		depth_attachment = &{
			view = state.depth_image,
			clear_value = &{depthStencil = {depth = 0.0}},
			layout = .DEPTH_ATTACHMENT_OPTIMAL,
		},
	)
	gfx.cmd_bind_pipeline(cmd, game.render_state.geometry_rp.depth_pipeline)
	record_geometry_draws(cmd, instances)
	gfx.cmd_end_rendering(cmd)
}

record_geometry_draws :: proc(cmd: gfx.Command_Buffer, instances: []RenderInstance) {
	for instance, instance_index in instances {
		gfx.cmd_bind_index_buffer(cmd, instance.index_buffer)
		gfx.cmd_push_constants(
			cmd,
			GPUDrawPushConstants {
				global_data_buffer = current_frame_game().global_buffer.ptr,
				instances = current_frame_game().instances_buffer.ptr,
				materials = game.render_state.material_store.materials_buffer.ptr,
				instance_index = u32(instance_index),
				num_cascades = NUM_CASCADES,
				shadow_depth = game.render_state.shadow_rp.shadow_depth_image,
				shadow_sampler = game.render_state.shadow_rp.shadow_sampler,
			},
		)

		gfx.cmd_draw_indexed(cmd, instance.index_count)
	}
}
