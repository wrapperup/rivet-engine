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
	depth_per_texel:      f32, // One world-space shadow texel expressed in normalized depth.
	raster_subpixel_size: f32,
}

ShadowRenderPass :: struct {
	mesh_shadow_pipeline:            ^gfx.GraphicsPipeline,
	shadow_depth_image:              gfx.Image,
	shadow_depth_image_id:           ImageId,
	shadow_sampler_id:               gfx.SamplerId,
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
	sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_BORDER, compare_op = .LESS_OR_EQUAL, border_color = .FLOAT_OPAQUE_WHITE)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, sampler)
	shadow_rp.shadow_sampler_id = gfx.add_sampler(sampler)

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
			push_constants = GPUDrawShadowDepthPushConstants,
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

// Camera motion may change only the XY translation, in whole shadow texels.
// Fit in camera space: inverse world-frustum corners introduce camera-dependent
// rounding into the radius, which changes the texel size even after snapping.
fit_shadow_cascade :: proc(
	projection, view_to_world: Mat4x4,
	sun_direction: Vec3,
	near, far: f32,
	resolution: u32,
	stable: bool,
) -> (
	Mat4x4,
	f32,
) {
	assert(resolution > 16 && far > near && near > 0)
	mid := (f64(near) + f64(far)) * 0.5
	half_depth := (f64(far) - f64(near)) * 0.5
	far_x := f64(far) / f64(projection[0, 0])
	far_y := f64(far) / f64(projection[1, 1])
	// Fixed sphere covers the frustum for every camera orientation. Eight texels
	// cover snapping, the receiver offset and PCF footprint at the boundary.
	radius := math.sqrt(far_x * far_x + far_y * far_y + half_depth * half_depth)
	radius /= 1 - 16 / f64(resolution)
	center_ws := linalg.Matrix4f64(view_to_world) * linalg.Vector4f64{0, 0, -mid, 1}

	direction := linalg.length(sun_direction) > 0.0001 ? linalg.normalize(sun_direction) : Vec3{0, 1, 0}
	light_up: Vec3 = math.abs(direction.y) > 0.99 ? {0, 0, 1} : {0, 1, 0}
	// Build orientation at the origin. look_at(center, center+direction) loses
	// direction precision as the camera moves away from the world origin.
	rotation := linalg.Matrix4f64(linalg.matrix4_look_at_f32({}, direction, light_up))
	center_ls := rotation * center_ws
	light_view := rotation
	light_view[3] = {-center_ls.x, -center_ls.y, -center_ls.z, 1}
	ortho := linalg.Matrix4f64(
		gfx.matrix_ortho3d_z0_f32(-f32(radius), f32(radius), -f32(radius), f32(radius), f32(radius) * 10, -f32(radius)),
	)
	ortho[1, 1] *= -1
	result := ortho * light_view
	if stable {
		// Snap the final NDC translation directly; no subsequent multiplication
		// can perturb it. XY matrix coefficients remain identical across frames.
		for axis in 0 ..< 2 {
			result[axis, 3] = math.round(result[axis, 3] * f64(resolution) * 0.5) * 2 / f64(resolution)
		}
	}
	return Mat4x4(result), f32((2 * radius / f64(resolution)) * math.abs(ortho[2, 2]))
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

	view_to_world := linalg.inverse(get_current_view_matrix())
	last_near := near
	for i in 0 ..< NUM_CASCADES {
		split_dist := cascade_splits[i]

		test_far := near + split_dist * clip_range

		world_to_shadow, depth_per_texel := fit_shadow_cascade(
			get_current_projection_matrix_clipped(near = last_near, far = test_far),
			view_to_world,
			game.state.environment.sun_direction,
			last_near,
			test_far,
			game.config.shadow_map_size,
			game.config.use_stable_shadow_maps,
		)
		game.render_state.shadow_rp.cascade_world_to_shadows[i] = world_to_shadow
		game.render_state.shadow_rp.cascade_configs[i] = {
			split_dist = test_far,
			depth_per_texel      = depth_per_texel,
			raster_subpixel_size = 1 / f32(u64(1) << min(gfx.r_ctx.limits.subPixelPrecisionBits, 24)),
		}

		last_near = test_far
	}
}
