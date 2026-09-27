package game

import "core:log"
import "core:math/linalg"
import "core:time"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import sp "deps:odin-slang/slang"
import vk "vendor:vulkan"

import "gfx"
import im_gfx "gfx/imgui_backend"

NUM_CASCADES: u32 : 4

@(private = "file")
ImageId :: gfx.ImageId
@(private = "file")
SamplerId :: gfx.SamplerId

@(shader_shared)
GPUEnvironment :: struct #max_field_align(16) {
	point_lights: gfx.Slice(GPUPointLight),
	env_map:      ImageId `ImageCube`,
	dfg:          ImageId `Image2D`,
	env_sampler:  SamplerId `Sampler`,
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
	default_sampler:          SamplerId `Sampler`,
	ddgi_volumes:             gfx.Slice(GPUDDGIVolume),
	reflection_probes:        gfx.Slice(GPUReflectionProbe),
	atmosphere:               GPUAtmosphere,
	mesh_debug_view:          u32,
}

RenderState :: struct {
	frame_data:                      [gfx.FRAME_OVERLAP]GameFrameData,

	// Bindless textures, etc
	global_data:                     GPUGlobalData,
	scene_resources:                 struct {
		point_lights:       [256]GPUPointLight,
		point_light_buffer: gfx.Buffer(GPUPointLight),
	},
	temp_resources:                  struct {
		dfg_id:             ImageId,
		default_sampler_id: SamplerId,
		env_sampler_id:     SamplerId,
	},
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
	reflection_capture_pipeline:     ^gfx.ComputePipeline,
	reflection_prefilter_pipeline:   ^gfx.ComputePipeline,
	reflection_probe_debug_pipeline: ^gfx.GraphicsPipeline,
	reflection_probes_buffers:       [gfx.FRAME_OVERLAP]gfx.Buffer(GPUReflectionProbe),
	atmosphere_rp:                   AtmosphereRenderPass,
	draw_sky:                        bool,
	mesh_debug_view:                 i32,

	// Debug
	debug_rt_pipeline:               ^gfx.ComputePipeline,

	// Imgui
	imgui_ctx:                       ^im.Context,
}

GameFrameData :: struct {
	global_buffer:           gfx.Buffer(GPUGlobalData),
	model_matrices_buffer:   gfx.Buffer(Mat4x4),
	cascade_matrices_buffer: gfx.Buffer(Mat4x4),
	cascade_configs_buffer:  gfx.Buffer(GPUCascadeConfig),
	mesh_draws:              [dynamic]MeshDraw,
	skel_instances:          [dynamic]^SkeletalMeshInstance,
	rt:                      RaytracingScene,
}

GPU_Font_Instance :: struct {
	pos_min: Vec2,
	pos_max: Vec2,
	uv_min:  Vec2,
	uv_max:  Vec2,
	color:   Vec4,
}

current_frame_game :: proc() -> ^GameFrameData {
	return &game.render_state.frame_data[gfx.current_frame_index()]
}

init_game_renderer :: proc() {
	init_imgui()
	init_shadow_maps()
	init_test_resources()
	init_material_store()
	init_render_passes()
	init_shared_buffers()
}

init_imgui :: proc() {
	game.render_state.imgui_ctx = im.CreateContext()
	im.SetCurrentContext(game.render_state.imgui_ctx)

	im_glfw.InitForVulkan(game.window, true)

	im_gfx.gfx_imgui_init()
}

init_test_resources :: proc() {
	// Default Image Sampler
	default_sampler := gfx.create_sampler(.LINEAR, .REPEAT, max_lod = 10.0, max_anisotropy = gfx.r_ctx.limits.maxSamplerAnisotropy)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, default_sampler)

	env_sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, max_lod = 8.0)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, env_sampler)

	{
		rs := &game.render_state
		tr := &rs.temp_resources

		// dfg_asset := load_asset(Image_Asset, "assets/gen/t_dfg.ktx2")

		rs.post_process_rp.tony_mc_mapface_id = gfx.load_image_from_file("assets/textures/tonemapping/t_tony_mc_mapface.ktx2")
		tr.dfg_id = gfx.load_image_from_file("assets/gen/t_dfg.ktx2")

		tr.default_sampler_id = default_sampler
		tr.env_sampler_id = env_sampler
	}
}

init_material_store :: proc() {
	material_store := &game.render_state.material_store

	material_store.materials_buffer = gfx.create_buffer(GPUMaterial, 20)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, material_store.materials_buffer)

	test_material := load_material_from_file("assets/materials/test.sjson")

	add_material(test_material)
	add_material(test_material)

	materialball_material := load_material_from_file("assets/materials/materialball2.sjson")
	add_material(materialball_material)
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
	init_rt_scene_pass()
	init_ui_rp()
}

init_shared_buffers :: proc() {
	for &frame in game.render_state.frame_data {
		frame.global_buffer = gfx.create_buffer(GPUGlobalData, 1, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.global_buffer)
	}

	environment := &game.render_state.global_data.environment

	game.render_state.scene_resources.point_light_buffer = gfx.create_buffer(
		GPUPointLight,
		len(game.render_state.scene_resources.point_lights),
	)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, game.render_state.scene_resources.point_light_buffer)

	environment^ = {
		point_lights = gfx.slice(game.render_state.scene_resources.point_light_buffer, count = 0),
		env_sampler  = game.render_state.temp_resources.env_sampler_id,
		env_map      = game.render_state.atmosphere_rp.environment_id,
		dfg          = game.render_state.temp_resources.dfg_id,
	}
}

draw :: proc() {
	scope_stat_time(.Render)

	when ODIN_DEBUG {
		if check_shader_hotreload() {
			gfx.vk_check(vk.DeviceWaitIdle(gfx.r_ctx.device))
			hotreload_start := time.now()
			if hotreload_modified_shaders() {
				game.render_state.atmosphere_rp.force_update = true
				log.info("Shaders hotreloaded in", time.since(hotreload_start))
			} else {
				log.warn("Shaders failed to load!")
			}
		}
	}

	// TEMP: test draw command
	for &ball in get_entities(Ball) {
		draw_mesh(game.ball_mesh, 1, ball.translation, ball.rotation, 1, include_in_raytracing = false)
	}

	for static_mesh in get_entities(StaticMesh) {
		draw_mesh(static_mesh.mesh, static_mesh.material, static_mesh.translation, static_mesh.rotation, static_mesh.scale)
	}

	for terrain in get_entities(Terrain) {
		draw_mesh(terrain.mesh, terrain.material, terrain.translation, terrain.rotation, 1)
	}

	frame := current_frame_game()
	volumes := get_entities(DDGIVolume)
	probes := get_entities(ReflectionProbe)

	// Wait for this frame slot before writing any of its CPU-visible buffers.
	cmd, frame_ready, swapchain_resized := gfx.begin_command_buffer()
	if !frame_ready {
		clear_frame_submission_data()
		return
	}

	// CPU preparation and uploads happen before command recording.
	atmosphere_prepare()
	geometry_prepare()
	shadow_prepare()
	skinning_prepare(frame.skel_instances[:])
	rt_scene_prepare(&frame.rt)
	ddgi_prepare(volumes, game.state.update_ddgi && len(frame.rt.instances) > 0)
	reflection_probe_prepare(probes)
	ui_prepare()
	prepare_shared_frame_data()

	record_atmosphere_pass(cmd)
	record_rt_scene_pass(cmd, &frame.rt)
	record_ddgi_pass(cmd, volumes)
	record_reflection_probe_pass(cmd, probes, volumes)
	record_skinning_pass(cmd, frame.skel_instances[:])
	record_shadow_pass(cmd, frame.mesh_draws[:])
	record_geometry_pass(cmd, frame.mesh_draws[:])
	record_ddgi_debug_probes_pass(cmd, volumes)
	record_reflection_probe_debug_pass(cmd, probes)

	// Finalize ImGui draw data for this frame; gfx_imgui_render consumes it below.
	im.Render()

	// kinda HACK: use draw image for resolved image when msaa is disabled.
	// TODO: this means you can't enable/disable MSAA at runtime until this hack is fixed.
	if gfx.msaa_enabled() {
		// resolve MSAA
		gfx.transition_image(cmd, gfx.r_ctx.draw_image, .TRANSFER_SRC_OPTIMAL)
		gfx.transition_image(cmd, gfx.r_ctx.resolve_image, .TRANSFER_DST_OPTIMAL)

		ex := gfx.r_ctx.draw_extent

		resolve_region := vk.ImageResolve {
			srcSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
			srcOffset = {0, 0, 0},
			dstSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
			dstOffset = {0, 0, 0},
			extent = {ex.width, ex.height, 1},
		}

		gfx.cmd_resolve_image(cmd, gfx.r_ctx.draw_image, gfx.r_ctx.resolve_image, {resolve_region})
	} else {
		// HACK: here's that hack i mentioned. TODO: this needs to be fixed in the api.
		gfx.r_ctx.resolve_image = gfx.r_ctx.draw_image
	}

	final_image: gfx.ImageId
	switch game.view_state {
	case .SceneDepth:
		gfx.transition_image(cmd, gfx.r_ctx.depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.depth_image
	case .ShadowDepth:
		gfx.transition_image(cmd, game.render_state.shadow_rp.shadow_depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = game.render_state.shadow_rp.shadow_depth_image
	case .Raytracing:
		record_debug_rt_pass(cmd)
		gfx.transition_image(cmd, gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.resolve_image
	case .DDGIAtlas:
		if len(volumes) > 0 {
			idx := clamp(int(game.render_state.ddgi_rp.debug_volume), 0, len(volumes) - 1)
			record_ddgi_debug_atlas_pass(cmd, &volumes[idx].volume)
		}
		gfx.transition_image(cmd, gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.resolve_image
	case .SceneColor:
		record_post_process_pass(cmd)
		record_ui_pass(cmd)

		// Prepare swapchain image
		gfx.transition_image(cmd, gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.resolve_image
	}

	gfx.copy_image_to_swapchain(cmd, final_image, gfx.r_ctx.draw_extent)

	sc := &gfx.r_ctx.swapchain
	sc_image := sc.swapchain_images[sc.swapchain_image_index]

	gfx.transition_image(cmd, sc_image, .COLOR_ATTACHMENT_OPTIMAL)
	im_gfx.gfx_imgui_render(cmd, sc_image, sc.swapchain_extent)

	gfx.transition_image(cmd, sc_image, .TRANSFER_DST_OPTIMAL)

	swapchain_resized = gfx.submit(cmd)

	clear_frame_submission_data()
}

clear_frame_submission_data :: proc() {
	clear(&current_frame_game().mesh_draws)
	clear(&current_frame_game().skel_instances)
	rt_scene_reset(&current_frame_game().rt)
	clear(&game.render_state.geometry_rp.model_matrices)
}

draw_mesh :: proc(
	mesh: GPUMeshBuffers,
	material: MaterialId,
	translation: Vec3,
	rotation: quaternion128,
	scale: [3]f32,
	include_in_raytracing := true,
) {
	model_index := len(game.render_state.geometry_rp.model_matrices)
	model := linalg.matrix4_from_trs_f32(translation, rotation, scale)

	append(
		&current_frame_game().mesh_draws,
		MeshDraw {
			vertex_buffer = mesh.vertex_buffer.ptr,
			index_buffer = mesh.index_buffer.buffer,
			index_count = mesh.index_count,
			model_index = u32(model_index),
			material_index = material,
		},
	)

	append(&game.render_state.geometry_rp.model_matrices, model)

	if include_in_raytracing {
		rt_scene_add(&current_frame_game().rt, mesh, material, model)
	}
}

draw_skeletal_mesh :: proc(
	instance: ^SkeletalMeshInstance,
	material: MaterialId,
	translation: Vec3,
	rotation: quaternion128,
	scale: Vec3,
) {
	model_index := len(game.render_state.geometry_rp.model_matrices)

	append(&current_frame_game().skel_instances, instance)
	append(
		&current_frame_game().mesh_draws,
		MeshDraw {
			vertex_buffer = instance.preskinned_vertex_buffers[gfx.current_frame_index()].ptr,
			index_buffer = instance.skel.buffers.index_buffer.buffer,
			index_count = instance.skel.buffers.index_count,
			model_index = u32(model_index),
			material_index = material,
		},
	)

	append(&game.render_state.geometry_rp.model_matrices, linalg.matrix4_from_trs_f32(translation, rotation, scale))
}

prepare_shared_frame_data :: proc() {
	for &point_light, i in get_entities(PointLight) {
		if i >= len(game.render_state.scene_resources.point_lights) do break
		game.render_state.scene_resources.point_lights[i] = point_light_to_gpu(point_light)
	}
	gfx.staging_write_buffer_slice(
		&game.render_state.scene_resources.point_light_buffer,
		game.render_state.scene_resources.point_lights[:],
	)

	global_data := &game.render_state.global_data
	player := get_entity(game.state.player_id)

	global_data.view_to_clip = get_current_projection_matrix()
	global_data.world_to_view = get_current_view_matrix()
	global_data.clip_to_world = linalg.inverse(global_data.view_to_clip * global_data.world_to_view)

	global_data.sun_color = game.state.environment.sun_color
	global_data.sky_color = game.state.environment.sky_color

	global_data.camera_pos = player != nil ? player.eye_pos : {0, 0, 0} // must match the render view (eye, not feet)
	global_data.sun_direction = game.state.environment.sun_direction
	global_data.mesh_debug_view = u32(game.render_state.mesh_debug_view)

	point_light_count := min(len_entities(PointLight), len(game.render_state.scene_resources.point_lights))
	global_data.environment.point_lights = gfx.slice(game.render_state.scene_resources.point_light_buffer, count = u64(point_light_count))

	global_data.cascade_world_to_shadows = current_frame_game().cascade_matrices_buffer.ptr
	global_data.cascade_configs = current_frame_game().cascade_configs_buffer.ptr
	global_data.default_sampler = game.render_state.temp_resources.default_sampler_id

	gfx.write_buffer(&current_frame_game().global_buffer, global_data)
}

renderer_shutdown :: proc() {
	// Wait for the GPU to finish before tearing down resources still in use (e.g. the
	// imgui buffers referenced by the last in-flight command buffer).
	gfx.vk_check(vk.DeviceWaitIdle(gfx.r_ctx.device))
	im_gfx.gfx_imgui_destroy()
	im_glfw.Shutdown()
	im.DestroyContext(game.render_state.imgui_ctx)
	game.render_state.imgui_ctx = nil
	shutdown_shader_manager()

	for &frame in game.render_state.frame_data {
		delete(frame.mesh_draws)
		// Replaced TLASes are retired per frame; the last one still needs retiring on shutdown.
		gfx.defer_destroy_accel(&gfx.r_ctx.global_arena, frame.rt.tlas)
		delete(frame.skel_instances)
		delete(frame.rt.instances)
		delete(frame.rt.geometries)
	}
}
