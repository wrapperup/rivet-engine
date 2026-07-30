package game

import "core:math"
import "core:math/linalg"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
ImageId :: gfx.ImageId

@(shader_shared)
GPUDrawShadowDepthPushConstants :: struct #max_field_align(16) {
	vertex_buffer:  gfx.Ptr(Vertex),
	model_matrices: gfx.Ptr(Mat4x4),
	global_data:    gfx.Ptr(GPUGlobalData),
	model_index:    u32,
	cascade_index:  u32,
}

@(shader_shared)
GPUCascadeConfig :: struct #max_field_align(16) {
	split_dist: f32,
	bias:       f32,
	slope_bias: f32,
}

ShadowRenderPass :: struct {
	mesh_shadow_pipeline:            ^gfx.GraphicsPipeline,
	shadow_depth_image:              gfx.Image,
	shadow_depth_image_id:           ImageId,
	shadow_depth_attach_image_views: [NUM_CASCADES]vk.ImageView,
	cascade_world_to_shadows:        [NUM_CASCADES]Mat4x4,
	cascade_configs:                 [NUM_CASCADES]GPUCascadeConfig,
}

init_shadow_maps :: proc() {
	extent := vk.Extent3D{game.config.shadow_map_size, game.config.shadow_map_size, 1}

	shadow_rp := &game.render_state.shadow_rp

	shadow_rp.shadow_depth_image = gfx.create_image(
		.D32_SFLOAT,
		extent,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
		array_layers = NUM_CASCADES,
	)

	shadow_rp.shadow_depth_image_id = gfx.add_image(shadow_rp.shadow_depth_image)

	gfx.defer_destroy(&gfx.r_ctx.global_arena, shadow_rp.shadow_depth_image.image_view)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, shadow_rp.shadow_depth_image.image, shadow_rp.shadow_depth_image.allocation)

	for &view, i in shadow_rp.shadow_depth_attach_image_views {
		view = gfx.create_image_view(shadow_rp.shadow_depth_image.image, shadow_rp.shadow_depth_image.format, .D2, 0, 1, i, 1)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, view)
	}
}

init_shadow_rp :: proc() {
	game.render_state.shadow_rp.mesh_shadow_pipeline = add_graphics_shader(
	"shaders/shadow_depth.slang",
	proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
		return gfx.create_graphics_pipeline(
			name = "Shadow_Depth_Pipeline",
			shader = module,
			vertex_entry = "vertex_main",
			fragment_entry = nil, // TODO: Only need vertex depth currently for shadow maps.
			input_topology = .TRIANGLE_LIST,
			polygon_mode = .FILL,
			cull_mode = {},
			front_face = .COUNTER_CLOCKWISE,
			depth = {format = gfx.r_ctx.depth_image.format, compare_op = .LESS_OR_EQUAL, write_enabled = true},
			push_constants = GPUDrawPushConstants,
		)
	},
	)

	for &frame in game.render_state.frame_data {
		frame.cascade_matrices_buffer = gfx.create_buffer(Mat4x4, NUM_CASCADES, .DynUniform)
		frame.cascade_configs_buffer = gfx.create_buffer(GPUCascadeConfig, NUM_CASCADES, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.cascade_matrices_buffer)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.cascade_configs_buffer)
	}
}

shadow_prepare :: proc() {
	calculate_shadow_view_projection_matrices()
	gfx.write_buffer_slice(&current_frame_game().cascade_matrices_buffer, game.render_state.shadow_rp.cascade_world_to_shadows[:])
	gfx.write_buffer_slice(&current_frame_game().cascade_configs_buffer, game.render_state.shadow_rp.cascade_configs[:])
}

record_shadow_pass :: proc(cmd: vk.CommandBuffer, mesh_draws: []MeshDraw) {
	gfx.transition_image(cmd, &game.render_state.shadow_rp.shadow_depth_image, .DEPTH_ATTACHMENT_OPTIMAL)
	for cascade in u32(0) ..< NUM_CASCADES {
		record_shadow_cascade(cmd, cascade, mesh_draws)
	}
}

@(private = "file")
record_shadow_cascade :: proc(cmd: vk.CommandBuffer, cascade: u32, mesh_draws: []MeshDraw) {
	image_view := game.render_state.shadow_rp.shadow_depth_attach_image_views[cascade]
	extent := game.render_state.shadow_rp.shadow_depth_image.extent

	width := extent.width
	height := extent.height

	gfx.cmd_begin_rendering(
		cmd,
		area = {width, height},
		depth_attachment = &{view = image_view, layout = .DEPTH_ATTACHMENT_OPTIMAL, clear_value = &{depthStencil = {depth = 1.0}}},
	)
	gfx.set_viewport_and_scissor(cmd, game.render_state.shadow_rp.shadow_depth_image.extent)

	gfx.cmd_bind_pipeline(cmd, game.render_state.shadow_rp.mesh_shadow_pipeline)

	for mesh_draw in mesh_draws {
		gfx.cmd_bind_index_buffer(cmd, mesh_draw.index_buffer)

		gfx.cmd_push_constants(
			cmd,
			GPUDrawShadowDepthPushConstants {
				vertex_buffer = mesh_draw.vertex_buffer,
				model_matrices = current_frame_game().model_matrices_buffer.ptr,
				global_data = current_frame_game().global_buffer.ptr,
				model_index = mesh_draw.model_index,
				cascade_index = cascade,
			},
		)

		gfx.cmd_draw_indexed(cmd, mesh_draw.index_count)
	}

	gfx.cmd_end_rendering(cmd)
}

calculate_shadow_view_projection_matrices :: proc(near: f32 = 0.1, far: f32 = 300) {
	cascade_split_lambda := game.config.shadow_cascade_split_lambda

	cascade_splits: [NUM_CASCADES]f32

	clip_range := far - near
	ratio := far / near

	// Calculate split depths based on view camera frustum
	// Based on method presented in https://developer.nvidia.com/gpugems/GPUGems3/gpugems3_ch10.html
	for i in 0 ..< NUM_CASCADES {
		p := (f32(i) + 1) / f32(NUM_CASCADES)
		log := near * math.pow(ratio, p)
		uniform := near + clip_range * p
		d := cascade_split_lambda * (log - uniform) + uniform
		cascade_splits[i] = (d - near) / clip_range
	}

	last_near := near
	for i in 0 ..< NUM_CASCADES {
		split_dist := cascade_splits[i]

		test_far := near + split_dist * clip_range

		world_to_clip := get_current_projection_matrix_clipped(near = last_near, far = test_far) * get_current_view_matrix()
		clip_to_world := linalg.inverse(world_to_clip)

		CORNERS_NDC :: [8]Vec4 {
			{-1.0, -1.0, 0.0, 1.0},
			{-1.0, -1.0, 1.0, 1.0},
			{-1.0, 1.0, 0.0, 1.0},
			{-1.0, 1.0, 1.0, 1.0},
			{1.0, -1.0, 0.0, 1.0},
			{1.0, -1.0, 1.0, 1.0},
			{1.0, 1.0, 0.0, 1.0},
			{1.0, 1.0, 1.0, 1.0},
		}

		corners_ws: [8]Vec4
		for pos_fs, j in CORNERS_NDC {
			pos_ws := clip_to_world * pos_fs
			corners_ws[j] = pos_ws / pos_ws.w

			if i == 1 {
				debug_draw_dot(corners_ws[j].xyz)
			}
		}

		center_ws: Vec3
		for corner_ws in corners_ws {
			center_ws += corner_ws.xyz
		}
		center_ws /= len(corners_ws)

		sun_dir := game.state.environment.sun_direction

		radius: f32
		for corner in corners_ws {
			// A sphere remains conservative after rotating into light space. The
			// previous max-axis extent did not, so diagonal corners could be clipped.
			radius = max(radius, linalg.length(corner.xyz - center_ws))
		}

		// Keep rasterization and PCF taps away from the exact projection boundary.
		radius *= 1.01

		aabb: Aabb
		aabb.min = -radius
		aabb.max = radius

		cascade_world_to_view := linalg.matrix4_look_at_f32(center_ws, center_ws + sun_dir, {0.0, 1.0, 0.0})
		cascade_view_to_clip := gfx.matrix_ortho3d_z0_f32(aabb.min.x, aabb.max.x, aabb.min.y, aabb.max.y, aabb.max.z * 10, aabb.min.z)
		cascade_view_to_clip[1][1] *= -1.0

		if game.config.use_stable_shadow_maps {
			sMapSize := f32(game.config.shadow_map_size)

			shadowMatrix := cascade_view_to_clip * cascade_world_to_view
			shadowOrigin := Vec4{0, 0, 0, 1}
			shadowOrigin = shadowMatrix * shadowOrigin
			shadowOrigin *= sMapSize / 2.0

			roundedOrigin := linalg.round(shadowOrigin)
			roundOffset := roundedOrigin - shadowOrigin
			roundOffset *= 2.0 / sMapSize
			roundOffset.zw = 0.0

			shadowProj := cascade_view_to_clip
			shadowProj[3] += roundOffset
			cascade_view_to_clip = shadowProj
		}

		game.render_state.shadow_rp.cascade_world_to_shadows[i] = cascade_view_to_clip * cascade_world_to_view
		game.render_state.shadow_rp.cascade_configs[i] = {
			split_dist = test_far,
			bias       = game.config.shadow_map_biases[i],
			slope_bias = game.config.shadow_map_slope_biases[i],
		}

		last_near = test_far
	}
}
