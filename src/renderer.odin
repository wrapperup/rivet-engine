package game

import "vendor:glfw"
import "core:math/linalg"
import "core:mem"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import sp "deps:odin-slang/slang"
import vk "vendor:vulkan"

import "gfx"
import im_gfx "gfx/imgui_backend"

DRAW_FORMAT :: vk.Format.R32G32B32A32_SFLOAT
DEPTH_FORMAT :: vk.Format.D32_SFLOAT

// Number of frames to provide in flight.
FRAME_OVERLAP :: 2

NUM_CASCADES: u32 : 4

@(shader_shared)
GPUEnvironment :: struct #max_field_align(16) {
	point_lights: gfx.Slice(GPUPointLight),
	env_map:      gfx.Image_Id `ImageCube`,
	dfg:          gfx.Image_Id `Image2D`,
	env_sampler:  gfx.Sampler_Id `Sampler`,
}

@(shader_shared)
GPUGlobalData :: struct #max_field_align(16) {
	view_to_clip:             Mat4x4,
	world_to_view:            Mat4x4,
	clip_to_world:            Mat4x4,
	environment:              GPUEnvironment,
	cascade_world_to_shadows: gfx.Ptr(Mat4x4),
	cascade_configs:          gfx.Ptr(GPUCascadeConfig),
	sun_color:                Vec3,
	sky_color:                Vec3,
	camera_pos:               Vec3,
	sun_direction:            Vec3,
	default_sampler:          gfx.Sampler_Id `Sampler`,
	ddgi_volumes:             gfx.Slice(GPUDDGIVolume),
	reflection_probes:        gfx.Slice(GPUReflectionProbe),
	atmosphere:               GPUAtmosphere,
	mesh_debug_view:          GPUGeometryDebugView,
}

RenderState :: struct {
	frame_data:   [FRAME_OVERLAP]GameFrameData,
    frame_count:  int,
    global_arena: gfx.Deletion_Queue,

    swapchain:              gfx.Swapchain,

	// Bindless textures, etc
	global_data:                     GPUGlobalData,
	scene_resources:                 struct {
		point_lights:      [256]GPUPointLight,
		point_light_slice: gfx.Slice(GPUPointLight),
	},
	temp_resources:                  struct {
		dfg_id:             gfx.Image_Id,
		default_sampler_id: gfx.Sampler_Id,
		env_sampler_id:     gfx.Sampler_Id,
	},

    // Draw resources
	draw_image:                      gfx.Image_Id,
	resolve_image:                   gfx.Image_Id,
	depth_image:                     gfx.Image_Id,
	draw_extent:                     gfx.Extent_2D,
	msaa_samples:                    vk.SampleCountFlag,

	material_store:                  Material_Store,
	shader_manager:                  ShaderManager,
	global_session:                  ^sp.IGlobalSession,
	ddgi_rp:                         DDGIRenderPass,
	geometry_rp:                     GeometryRenderPass,
	skinning_rp:                     SkinningRenderPass,
	shadow_rp:                       ShadowRenderPass,
	post_process_rp:                 PostProcessingRenderPass,
	ui_rp:                           UIRenderPass,

	// Reflection probe pipelines
	reflection_capture_pipeline:     ^gfx.Pipeline,
	reflection_prefilter_pipeline:   ^gfx.Pipeline,
	reflection_probe_debug_pipeline: ^gfx.Pipeline,
	reflection_probes_buffers:       [FRAME_OVERLAP]gfx.Buffer(GPUReflectionProbe),
	atmosphere_rp:                   AtmosphereRenderPass,
	draw_sky:                        bool,
	mesh_debug_view:                 GPUGeometryDebugView,

	// Debug
	debug_rt_pipeline:               ^gfx.Pipeline,

	// Imgui
	imgui_ctx:                       ^im.Context,
}

GameFrameData :: struct {
    render_semaphore_pair:   gfx.Semaphore_Pair,
    arena:                   gfx.Deletion_Queue,
	global_buffer:           gfx.Buffer(GPUGlobalData),
	scratch:                 gfx.Scratch,
	instances_buffer:        gfx.Buffer(GPURenderInstance),
	cascade_matrices_buffer: gfx.Buffer(Mat4x4),
	cascade_configs_buffer:  gfx.Buffer(GPUCascadeConfig),
	instances:               [dynamic]RenderInstance,
	skel_instances:          [dynamic]^SkeletalMeshInstance,
	rt:                      RaytracingResources,
}

current_frame_index :: proc() -> int {
    return game.render_state.frame_count % FRAME_OVERLAP
}

current_frame_game :: proc() -> ^GameFrameData {
	return &game.render_state.frame_data[current_frame_index()]
}

frame_arena :: proc() -> ^gfx.Deletion_Queue {
	return &game.render_state.frame_data[current_frame_index()].arena
}

create_draw_images :: proc(arena: ^gfx.Deletion_Queue, extent: gfx.Extent_2D) {
    state := &game.render_state

    draw_image_extent := gfx.Extent_3D{**extent, 1}
	draw_image_usages := vk.ImageUsageFlags{.TRANSFER_SRC, .TRANSFER_DST, .STORAGE, .COLOR_ATTACHMENT}

	state.draw_image = gfx.create_image(DRAW_FORMAT, draw_image_extent, draw_image_usages, msaa_samples = state.msaa_samples)
	gfx.defer_destroy(arena, state.draw_image)

	// Used for MSAA resolution
	state.resolve_image = gfx.create_image(DRAW_FORMAT, draw_image_extent, draw_image_usages, msaa_samples = ._1)
	gfx.defer_destroy(&state.global_arena, state.resolve_image)

	state.depth_image = gfx.create_image(DEPTH_FORMAT, draw_image_extent, {.DEPTH_STENCIL_ATTACHMENT}, msaa_samples = state.msaa_samples)
	gfx.defer_destroy(&state.global_arena, state.depth_image)

	state.draw_extent.x = draw_image_extent.x
	state.draw_extent.y = draw_image_extent.y
}

init_game_renderer :: proc() {
    state := &game.render_state

    surface: vk.SurfaceKHR
    gfx.vk_check(glfw.CreateWindowSurface(gfx.r_ctx.instance, game.window, nil, &surface))
    gfx.defer_destroy(&state.global_arena, surface)

    width, height := glfw.GetFramebufferSize(game.window)

    state.swapchain = gfx.create_swapchain(
        surface,
        .FIFO,
        cast(gfx.Extent_2D)([2]i32{width, height}),
        FRAME_OVERLAP,
    )
    create_draw_images(&state.swapchain.arena, {u32(width), u32(height)})

	init_imgui()
	init_shadow_maps()
	init_test_resources()
	init_material_store()
	init_render_passes()
	init_shared_buffers()
}

init_imgui :: proc() {
    when EDITOR {
        game.render_state.imgui_ctx = im.CreateContext()
        im.SetCurrentContext(game.render_state.imgui_ctx)

        im_glfw.InitForVulkan(game.window, true)

        im_gfx.gfx_imgui_init(game.render_state.swapchain.swapchain_image_format)
    }
}

init_test_resources :: proc() {
	// Default Image Sampler
	default_sampler := gfx.create_sampler(.LINEAR, .REPEAT, max_lod = 10.0, max_anisotropy = gfx.r_ctx.limits.maxSamplerAnisotropy)
	gfx.defer_destroy(&game.render_state.global_arena, default_sampler)

	env_sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, max_lod = 8.0)
	gfx.defer_destroy(&game.render_state.global_arena, env_sampler)

	{
		rs := &game.render_state
		tr := &rs.temp_resources

		// dfg_asset := load_asset(Image_Asset, "gen/t_dfg.ktx2")

		rs.post_process_rp.tony_mc_mapface_id = load_asset(Image_Asset, "textures/tonemapping/t_tony_mc_mapface.ktx2").image_id
		tr.dfg_id = load_asset(Image_Asset, "gen/t_dfg.ktx2").image_id

		tr.default_sampler_id = default_sampler
		tr.env_sampler_id = env_sampler
	}
}

init_render_passes :: proc() {
	assert(sp.createGlobalSession(sp.API_VERSION, &game.render_state.global_session) == sp.OK)

	init_geometry_rp()
	init_shadow_rp()
	init_skinning_rp()
	init_atmosphere_rp()
	init_post_process_rp()
	init_debug_rt_rp()
	init_ddgi_rp()
	init_reflection_probe_rp()
	init_raytracing()
	init_ui_rp()
}

init_shared_buffers :: proc() {
	for &frame in game.render_state.frame_data {
		frame.instances_buffer = gfx.create_buffer(GPURenderInstance, MAX_RENDER_INSTANCES, .Host_Sequential_Write)
		gfx.defer_destroy(&game.render_state.global_arena, frame.instances_buffer)

		frame.scratch = gfx.create_scratch(32 * mem.Megabyte, "Frame Scratch Buffer")
		gfx.defer_destroy(&game.render_state.global_arena, frame.scratch)

		frame.global_buffer = gfx.create_buffer(GPUGlobalData, 1, .Host_Sequential_Write)
		gfx.defer_destroy(&game.render_state.global_arena, frame.global_buffer)
	}

	environment := &game.render_state.global_data.environment

	environment^ = {
		point_lights = game.render_state.scene_resources.point_light_slice,
		env_sampler  = game.render_state.temp_resources.env_sampler_id,
		env_map      = game.render_state.atmosphere_rp.environment_id,
		dfg          = game.render_state.temp_resources.dfg_id,
	}
}

draw :: proc() {
    state := &game.render_state

	scope_stat_time(.Render)

    gfx.wait_semaphore(current_frame_game().render_semaphore_pair)
    gfx.flush_vk_arena(frame_arena())

	// TEMP: test draw command
	for &ball in get_entities(Ball) {
		material_asset := get_asset(Material_Asset, "materials/test.mat")
		if material_asset != nil {
			draw_mesh(game.ball_mesh, material_asset.material_id, ball.translation, ball.rotation, 1, include_in_raytracing = false)
		}
	}

	for static_mesh in get_entities(StaticMesh) {
		mesh_asset := get_asset(static_mesh.mesh_asset)
		material_asset := get_asset(static_mesh.material_asset)
		if mesh_asset != nil && material_asset != nil {
			draw_mesh(mesh_asset.gpu_buffers, material_asset.material_id, static_mesh.translation, static_mesh.rotation, static_mesh.scale)
		}
	}

	for terrain in get_entities(Terrain) {
		heightfield_asset := get_asset(terrain.heightfield)
		material_asset := get_asset(terrain.material)
		if heightfield_asset != nil && material_asset != nil {
			draw_mesh(heightfield_asset.gpu_buffers, material_asset.material_id, terrain.translation, terrain.rotation, 1)
		}
	}

	frame := current_frame_game()
	volumes := get_entities(DDGIVolume)
	probes := get_entities(ReflectionProbe)

    gfx.flush_vk_arena(&frame.arena)
	gfx.reset_scratch(&frame.scratch)

    swapchain_image := gfx.swapchain_acquire_next_image(&state.swapchain)
    if swapchain_image == {} {
        width, height := glfw.GetFramebufferSize(game.window)
        if width == 0 || height == 0 {
            return 
        }

        gfx.swapchain_resize(&state.swapchain, cast(gfx.Extent_2D)[2]i32{width, height})
        create_draw_images(&state.swapchain.arena, {u32(width), u32(height)})

        return
    }

	cmd := gfx.begin_command_buffer(.Main)

	// CPU preparation and uploads happen before command recording.
	atmosphere_prepare()
	prepare_render_instances(frame)
	shadow_prepare()
	skinning_prepare(frame.skel_instances[:])
	ddgi_prepare(volumes, game.state.update_ddgi && frame.rt.instance_count > 0)
	reflection_probe_prepare(probes)
	ui_prepare()
	prepare_shared_frame_data()

	record_atmosphere_pass(cmd)
	record_raytracing(cmd, &frame.rt)
	record_ddgi_pass(cmd, volumes)
	record_reflection_probe_pass(cmd, probes, volumes)
	record_skinning_pass(cmd, frame.skel_instances[:])
	record_shadow_pass(cmd, frame.instances[:])
	record_geometry_pass(cmd, frame.instances[:])
	record_ddgi_debug_probes_pass(cmd, volumes)
	record_reflection_probe_debug_pass(cmd, probes)

	// Finalize ImGui draw data for this frame; gfx_imgui_render consumes it below.
    when EDITOR {
        im.Render()
    }

	// kinda HACK: use draw image for resolved image when msaa is disabled.
	// TODO: this means you can't enable/disable MSAA at runtime until this hack is fixed.
	if state.msaa_samples > ._1 {
		// resolve MSAA
		gfx.transition_image(cmd, state.draw_image, .TRANSFER_SRC_OPTIMAL)
		gfx.transition_image(cmd, state.resolve_image, .TRANSFER_DST_OPTIMAL)

		ex := state.draw_extent

		resolve_region := vk.ImageResolve {
			srcSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
			srcOffset = {0, 0, 0},
			dstSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
			dstOffset = {0, 0, 0},
			extent = {**ex, 1},
		}

		gfx.cmd_resolve_image(cmd, state.draw_image, state.resolve_image, {resolve_region})
	} else {
		// HACK: here's that hack i mentioned. TODO: this needs to be fixed in the api.
		state.resolve_image = state.draw_image
	}

	final_image: gfx.Image_Id
	switch game.view_state {
	case .SceneDepth:
		gfx.transition_image(cmd, state.depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = state.depth_image
	case .ShadowDepth:
		gfx.transition_image(cmd, game.render_state.shadow_rp.shadow_depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = game.render_state.shadow_rp.shadow_depth_image
	case .Raytracing:
		record_debug_rt_pass(cmd)
		gfx.transition_image(cmd, state.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = state.resolve_image
	case .SceneColor:
		record_post_process_pass(cmd)
		record_ui_pass(cmd)

		// Prepare swapchain image
		gfx.transition_image(cmd, game.render_state.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = game.render_state.resolve_image
	}

	gfx.transition_image(cmd, swapchain_image, .TRANSFER_DST_OPTIMAL)
	gfx.copy_image_to_image(cmd, final_image, swapchain_image, cast(gfx.Offset_2D)state.draw_extent, cast(gfx.Offset_2D)state.draw_extent)

    when EDITOR {
        gfx.transition_image(cmd, swapchain_image, .COLOR_ATTACHMENT_OPTIMAL)
        im_gfx.gfx_imgui_render(cmd, swapchain_image, state.draw_extent)
    }

	current_frame_game().render_semaphore_pair =
        gfx.queue_submit(.Main, cmd, swapchain = &state.swapchain)

    gfx.swapchain_present(&state.swapchain, .Main)

    game.render_state.frame_count += 1

	clear_frame_submission_data()
}

clear_frame_submission_data :: proc() {
	clear(&current_frame_game().instances)
	clear(&current_frame_game().skel_instances)
}

draw_mesh :: proc(
	mesh: GPUMeshBuffers,
	material: MaterialId,
	translation: Vec3,
	rotation: quaternion128,
	scale: [3]f32,
	include_in_raytracing := true,
) {
	submit_render_instance(
		RenderInstance {
			data = {
				model_to_world = linalg.matrix4_from_trs_f32(translation, rotation, scale),
				vertex_buffer = mesh.vertex_buffer.ptr,
				index_buffer = mesh.index_buffer.ptr,
				material_index = material,
			},
			index_buffer = mesh.index_buffer.buffer,
			index_count = mesh.index_count,
			blas_address = include_in_raytracing ? mesh.blas.address : 0,
		},
	)
}

draw_skeletal_mesh :: proc(
	instance: ^SkeletalMeshInstance,
	material: MaterialId,
	translation: Vec3,
	rotation: quaternion128,
	scale: Vec3,
) {
	append(&current_frame_game().skel_instances, instance)
	submit_render_instance(
		RenderInstance {
			data = {
				model_to_world = linalg.matrix4_from_trs_f32(translation, rotation, scale),
				vertex_buffer = instance.preskinned_vertex_buffers[current_frame_index()].ptr,
				index_buffer = instance.skel.buffers.index_buffer.ptr,
				material_index = material,
			},
			index_buffer = instance.skel.buffers.index_buffer.buffer,
			index_count = instance.skel.buffers.index_count,
		},
	)
}

prepare_shared_frame_data :: proc() {
	for &point_light, i in get_entities(PointLight) {
		if i >= len(game.render_state.scene_resources.point_lights) do break
		game.render_state.scene_resources.point_lights[i] = point_light_to_gpu(point_light)
	}
	point_light_count := min(len_entities(PointLight), len(game.render_state.scene_resources.point_lights))
	point_lights_slice := gfx.write_scratch_slice(&current_frame_game().scratch, game.render_state.scene_resources.point_lights[:point_light_count])

	global_data := &game.render_state.global_data
	player := get_entity(game.state.player_id)

	global_data.view_to_clip = get_current_projection_matrix()
	global_data.world_to_view = get_current_view_matrix()
	global_data.clip_to_world = linalg.inverse(global_data.view_to_clip * global_data.world_to_view)

	global_data.sun_color = game.state.environment.sun_color
	global_data.sky_color = game.state.environment.sky_color

	global_data.camera_pos = player != nil ? player.eye_pos : {0, 0, 0} // must match the render view (eye, not feet)
	global_data.sun_direction = game.state.environment.sun_direction
	global_data.mesh_debug_view = game.render_state.mesh_debug_view

	global_data.environment.point_lights = point_lights_slice

	global_data.cascade_world_to_shadows = current_frame_game().cascade_matrices_buffer.ptr
	global_data.cascade_configs = current_frame_game().cascade_configs_buffer.ptr
	global_data.default_sampler = game.render_state.temp_resources.default_sampler_id

	gfx.write_buffer(&current_frame_game().global_buffer, global_data)
}

renderer_shutdown :: proc() {
	gfx.wait_idle()

    gfx.swapchain_destroy(&game.render_state.swapchain)

    for &frame in game.render_state.frame_data {
        gfx.defer_destroy_accel(&frame.arena, frame.rt.tlas)
        gfx.flush_vk_arena(&frame.arena)
    }

    gfx.flush_vk_arena(&game.render_state.global_arena)

    when EDITOR {
        im_gfx.gfx_imgui_destroy()
        im_glfw.Shutdown()
        im.DestroyContext(game.render_state.imgui_ctx)
        game.render_state.imgui_ctx = nil
    }

	for &frame in game.render_state.frame_data {
		delete(frame.instances)
		delete(frame.skel_instances)
	}
}
