package game

import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:time"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import sp "deps:odin-slang/slang"
import vk "vendor:vulkan"

import "gfx"
import im_gfx "gfx/imgui_backend"

// TODO: Make this into proper assets?
MaterialId :: u32

NUM_CASCADES: u32 : 3

@(private = "file")
GPUPtr :: gfx.GPUPtr
@(private = "file")
ImageId :: gfx.ImageId
@(private = "file")
SamplerId :: gfx.SamplerId

@(shader_shared)
GPUMaterial :: struct #max_field_align(16) {
	base_color_id:            ImageId `Image2D`,
	normal_map_id:            ImageId `Image2D`,
	ao_roughness_metallic_id: ImageId `Image2D`,
}

@(shader_shared)
GPUEnvironment :: struct #max_field_align(16) {
	point_lights:     GPUPtr(GPUPointLight),
	num_point_lights: u32,
	env_map:          ImageId `ImageCube`,
	dfg:              ImageId `Image2D`,
	env_sampler:      SamplerId `Sampler`,
}

@(shader_shared)
GPUGlobalData :: struct #max_field_align(16) {
	view_to_clip:             Mat4x4,
	world_to_view:            Mat4x4,
	clip_to_world:            Mat4x4,
	environment:              GPUEnvironment,
	cascade_world_to_shadows: GPUPtr(Mat4x4),
	cascade_configs:          GPUPtr(GPUCascadeConfig),
	sun_color:                Vec3,
	sky_color:                Vec3,
	camera_pos:               Vec3,
	sun_direction:            Vec3,
	default_sampler:          SamplerId `Sampler`,
	ddgi_volumes:             GPUPtr(GPUDDGIVolume),
	num_ddgi_volumes:         u32,
	reflection_probes:        GPUPtr(GPUReflectionProbe),
	num_reflection_probes:    u32,
}

RenderState :: struct {
	frame_data:                      [gfx.FRAME_OVERLAP]GameFrameData,

	// Bindless textures, etc
	global_data:                     GPUGlobalData,
	scene_resources:                 struct {
		materials:          [dynamic]GPUMaterial,
		materials_buffer:   gfx.GPUBuffer(GPUMaterial),
		point_lights:       [256]GPUPointLight,
		point_light_buffer: gfx.GPUBuffer(GPUPointLight),
	},
	temp_resources:                  struct {
		dfg_id:                  ImageId,
		env_id:                  ImageId,
		default_sampler_id:      SamplerId,
		shadow_depth_sampler_id: SamplerId,
		env_sampler_id:          SamplerId,
		resolved_image_id:       ImageId,
	},
	shader_manager:                  ShaderManager,
	global_session:                  ^sp.IGlobalSession,
	ddgi_rp:                         DDGIRenderPass,
	geometry_rp:                     GeometryRenderPass,
	skinning_rp:                     SkinningRenderPass,
	shadow_rp:                       ShadowRenderPass,
	post_process_rp:                 PostProcessingRenderPass,

	// Reflection probe pipelines
	reflection_capture_pipeline:     ^gfx.ComputePipeline,
	reflection_prefilter_pipeline:   ^gfx.ComputePipeline,
	reflection_probe_debug_pipeline: ^gfx.GraphicsPipeline,
	reflection_probes_buffer:        gfx.GPUBuffer(GPUReflectionProbe), // packed per-frame array

	// Skybox pipelines
	skybox_pipeline:                 ^gfx.GraphicsPipeline,
	skybox_mesh:                     GPUMeshBuffers,
	draw_skybox:                     bool,

	// Debug
	debug_rt_pipeline:               ^gfx.ComputePipeline,

	// Imgui
	imgui_ctx:                       ^im.Context,
}

GameFrameData :: struct {
	global_buffer:           gfx.GPUBuffer(GPUGlobalData),
	model_matrices_buffer:   gfx.GPUBuffer(Mat4x4),
	cascade_matrices_buffer: gfx.GPUBuffer(Mat4x4),
	cascade_configs_buffer:  gfx.GPUBuffer(GPUCascadeConfig),
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

add_material :: proc(material: GPUMaterial) -> MaterialId {
	scene_resources := &game.render_state.scene_resources
	material_id := MaterialId(len(scene_resources.materials))

	append(&scene_resources.materials, material)

	gfx.staging_write_buffer_slice(&scene_resources.materials_buffer, scene_resources.materials[:])

	return material_id
}

init_game_renderer :: proc() {
	init_imgui()
	init_shadow_maps()
	init_test_resources()
	init_test_materials()
	init_render_passes()
	init_buffers()
}

init_imgui :: proc() {
	game.render_state.imgui_ctx = im.CreateContext()
	im.SetCurrentContext(game.render_state.imgui_ctx)

	im_glfw.InitForVulkan(game.window, true)

	im_gfx.gfx_imgui_init()
}

init_test_resources :: proc() {
	tony_mc_mapface := gfx.load_image_from_memory(asset_content(.t_tony_mc_mapface), .D3, .D3)

	dfg := gfx.load_image_from_memory(asset_content(.t_dfg))
	env := gfx.load_image_from_memory(asset_content(.t_test_cubemap_ld), .D2, .CUBE)

	// Default Imageture Sampler
	default_sampler := gfx.create_sampler(.LINEAR, .REPEAT, max_lod = 10.0, max_anisotropy = gfx.r_ctx.limits.maxSamplerAnisotropy)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, default_sampler)

	font_image_sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, font_image_sampler)

	// Shadow Depth Imageture Sampler
	shadow_depth_sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, .LESS_OR_EQUAL)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, shadow_depth_sampler)

	env_sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, max_lod = 8.0)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, env_sampler)

	{
		rs := &game.render_state
		tr := &rs.temp_resources

		rs.post_process_rp.tony_mc_mapface_id = gfx.add_image(tony_mc_mapface)
		tr.dfg_id = gfx.add_image(dfg)
		tr.env_id = gfx.add_image(env)

		tr.default_sampler_id = gfx.add_sampler(default_sampler)
		tr.shadow_depth_sampler_id = gfx.add_sampler(shadow_depth_sampler)
		tr.env_sampler_id = gfx.add_sampler(env_sampler)

		tr.resolved_image_id = gfx.add_image(gfx.r_ctx.resolve_image)
	}
}

init_test_materials :: proc() {
	game.render_state.scene_resources.materials_buffer = gfx.create_buffer(GPUMaterial, 20)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, game.render_state.scene_resources.materials_buffer)

	base_color_id := gfx.add_image(gfx.load_image_from_memory(asset_content(.t_test_basecolor2)))
	normal_map_id := gfx.add_image(gfx.load_image_from_memory(asset_content(.t_test_normalmap)))
	proughness_metallic_ao_id := gfx.add_image(gfx.load_image_from_memory(asset_content(.t_test_rma)))

	add_material({base_color_id = base_color_id, normal_map_id = normal_map_id, ao_roughness_metallic_id = proughness_metallic_ao_id})
	add_material({base_color_id = base_color_id, normal_map_id = normal_map_id, ao_roughness_metallic_id = proughness_metallic_ao_id})

	base_color_id = gfx.add_image(gfx.load_image_from_memory(asset_content(.t_basecolor)))
	normal_map_id = gfx.add_image(gfx.load_image_from_memory(asset_content(.t_normalmap)))
	proughness_metallic_ao_id = gfx.add_image(gfx.load_image_from_memory(asset_content(.t_rma)))

	add_material({base_color_id = base_color_id, normal_map_id = normal_map_id, ao_roughness_metallic_id = proughness_metallic_ao_id})
}

init_render_passes :: proc() {
	assert(sp.createGlobalSession(sp.API_VERSION, &game.render_state.global_session) == sp.OK)

	init_geometry_rp()
	init_shadow_rp()
	init_skinning_rp()
	init_skybox_rp()
	init_post_process_rp()
	init_debug_rt_rp()
	init_ddgi_rp()
	init_reflection_probe_rp()
}

init_buffers :: proc() {
	// Skybox
	{
		mesh, ok := load_gpu_mesh_from_file(asset_path(.sm_skybox))
		assert(ok)
		defer_destroy_gpu_mesh(&gfx.r_ctx.global_arena, mesh)
		game.render_state.skybox_mesh = mesh
	}

	for &frame in game.render_state.frame_data {
		// TODO: These don't make good use of being a uniform...
		// They get used in BDA instead, which means they aren't uniformly accessed.

		// Global uniform buffer
		frame.global_buffer = gfx.create_buffer(GPUGlobalData, 1, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.global_buffer)

		// Model matrices
		frame.model_matrices_buffer = gfx.create_buffer(Mat4x4, 16_384, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.model_matrices_buffer)

		// Raytraced scene (TLAS instances + geometry table, collected by draw_mesh)
		rt_scene_init(&frame.rt)

		frame.cascade_matrices_buffer = gfx.create_buffer(Mat4x4, NUM_CASCADES, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.cascade_matrices_buffer)

		frame.cascade_configs_buffer = gfx.create_buffer(GPUCascadeConfig, NUM_CASCADES, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.cascade_configs_buffer)
	}

	environment := &game.render_state.global_data.environment

	game.render_state.scene_resources.point_light_buffer = gfx.create_buffer(
		GPUPointLight,
		len(game.render_state.scene_resources.point_lights),
	)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, game.render_state.scene_resources.point_light_buffer)

	environment^ = {
		point_lights     = game.render_state.scene_resources.point_light_buffer.ptr,
		num_point_lights = u32(len(game.render_state.scene_resources.point_lights)),
		env_sampler      = game.render_state.temp_resources.env_sampler_id,
		env_map          = game.render_state.temp_resources.env_id,
		dfg              = game.render_state.temp_resources.dfg_id,
	}

	reserve(&game.render_state.geometry_rp.model_matrices, 16_000)
}

draw :: proc() {
	scope_stat_time(.Render)

	when ODIN_DEBUG {
		if check_shader_hotreload() {
			gfx.vk_check(vk.DeviceWaitIdle(gfx.r_ctx.device))
			hotreload_start := time.now()
			if hotreload_modified_shaders() {
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
		draw_mesh(static_mesh.mesh, static_mesh.material, static_mesh.translation, static_mesh.rotation, 1)
	}

	// {
	// 	font_state := &game.render_state.font_state
	//
	// 	if len(font_state.font_instances) > 0 {
	// 		gfx.write_buffer_slice(&font_state.font_instance_buf, font_state.font_instances[:])
	// 	}
	//
	// 	atlas_size := UVec2{u32(font_state.font_ctx.width), u32(font_state.font_ctx.height)}
	// 	dirty_texture :=
	// 		font_state.font_ctx.dirtyRect[0] < font_state.font_ctx.dirtyRect[2] &&
	// 		font_state.font_ctx.dirtyRect[1] < font_state.font_ctx.dirtyRect[3]
	//
	// 	if font_state.font_atlas_size != atlas_size {
	// 		dirty_texture = true
	// 		font_state.font_atlas_size = atlas_size
	//
	// 		vk.DeviceWaitIdle(gfx.r_ctx.device)
	//
	// 		if font_state.font_img.image != 0 {
	// 			gfx.defer_destroy(&gfx.current_frame().arena, font_state.font_img)
	// 		}
	//
	// 		font_state.font_img = gfx.create_image(
	// 			.R8_UINT,
	// 			{atlas_size.x, atlas_size.y, 1},
	// 			{.TRANSFER_DST, .SAMPLED},
	// 		)
	//
	// 		set_texture(font_state.font_img, FONT_ATLAS_ID)
	// 	}
	//
	// 	if dirty_texture {
	// 		gfx.staging_write_image_slice(&font_state.font_img, font_state.font_ctx.textureData)
	// 	}
	//
	// 	font_state.font_ctx.state_count = 0
	// 	fontstash.Reset(&font_state.font_ctx)
	// }

	cmd := gfx.begin_command_buffer()

	update_buffers()

	rt_scene_build(&current_frame_game().rt, cmd)

	// DDGI: trace + update every volume's probe atlases (needs the scene TLAS).
	// TODO: cadence knob (round-robin / nearest-first) once volume counts grow.
	if current_frame_game().rt.tlas.address != 0 && game.state.update_ddgi {
		for &volume in get_entities(DDGIVolume) {
			ddgi_update_volume(cmd, &volume.volume)
		}
	}

	// Reflection probes: RT-capture their cubemap once the TLAS is ready AND every DDGI atlas
	// has had time to converge (else the captured indirect bounce is near-black). Recapture
	// (imgui) re-triggers anytime. Capture after DDGI so it reflects the current probe field.
	REFLECTION_AUTO_CAPTURE_FRAME :: 200
	if current_frame_game().rt.tlas.address != 0 {
		converged := true // no volumes -> nothing to wait for
		for &volume in get_entities(DDGIVolume) {
			if volume.gpu.frame_index <= REFLECTION_AUTO_CAPTURE_FRAME {
				converged = false
				break
			}
		}
		for &probe in get_entities(ReflectionProbe) {
			auto := !probe.captured && converged
			live := game.state.update_reflections && converged // recapture every frame (imgui toggle)
			if probe.wants_recapture || auto || live {
				reflection_probe_capture(cmd, &probe)
				probe.wants_recapture = false
			}
		}
	}

	// Begin Skinning pass
	for instance in current_frame_game().skel_instances {
		gfx.transition_buffer(
			cmd,
			instance.preskinned_vertex_buffers[gfx.current_frame_index()],
			{.MEMORY_READ},
			{.MEMORY_WRITE},
			gfx.r_ctx.graphics_queue_family,
		)
		skinning_pass(cmd, instance)
		gfx.transition_buffer(
			cmd,
			instance.preskinned_vertex_buffers[gfx.current_frame_index()],
			{.MEMORY_WRITE},
			{.MEMORY_READ},
			gfx.r_ctx.graphics_queue_family,
		)
	}
	// End skinning pass

	// Begin shadow pass
	gfx.transition_image(cmd, &game.render_state.shadow_rp.shadow_depth_image, .DEPTH_ATTACHMENT_OPTIMAL)
	for i in 0 ..< len(game.render_state.shadow_rp.shadow_depth_attach_image_views) {
		shadow_map_pass(cmd, u32(i))
	}
	// End shadow pass

	// Begin mesh pass
	gfx.transition_image(cmd, &gfx.r_ctx.draw_image, .COLOR_ATTACHMENT_OPTIMAL)
	gfx.transition_image(cmd, &gfx.r_ctx.depth_image, .DEPTH_ATTACHMENT_OPTIMAL)
	gfx.transition_image(cmd, &game.render_state.shadow_rp.shadow_depth_image, .DEPTH_READ_ONLY_OPTIMAL)
	if game.render_state.draw_skybox {
		skybox_pass(cmd)
	}
	geometry_pass(cmd)
	if game.render_state.ddgi_rp.draw_probes {
		for &volume in get_entities(DDGIVolume) {
			ddgi_debug_probes_pass(cmd, &volume.volume)
		}
	}
	if game.render_state.ddgi_rp.draw_reflection_probes {
		reflection_probe_debug_spheres_pass(cmd)
	}
	// End mesh pass

	// Finalize ImGui draw data for this frame; gfx_imgui_render consumes it below.
	im.Render()

	final_image: vk.Image
	switch game.view_state {
	case .SceneDepth:
		gfx.transition_image(cmd, &gfx.r_ctx.depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.depth_image.image
	case .ShadowDepth:
		gfx.transition_image(cmd, &game.render_state.shadow_rp.shadow_depth_image, .TRANSFER_SRC_OPTIMAL)
		final_image = game.render_state.shadow_rp.shadow_depth_image.image
	case .Raytracing:
		gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .GENERAL)
		debug_rt_pass(cmd)
		gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.resolve_image.image
	case .DDGIAtlas:
		gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .GENERAL)
		volumes := get_entities(DDGIVolume)
		if len(volumes) > 0 {
			idx := clamp(int(game.render_state.ddgi_rp.debug_volume), 0, len(volumes) - 1)
			ddgi_debug_atlas_pass(cmd, &volumes[idx].volume)
		}
		gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
		final_image = gfx.r_ctx.resolve_image.image
	case .SceneColor:
		if gfx.msaa_enabled() {
			// Resolve MSAA
			gfx.transition_image(cmd, &gfx.r_ctx.draw_image, .TRANSFER_SRC_OPTIMAL)
			gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .TRANSFER_DST_OPTIMAL)

			ex := gfx.r_ctx.draw_extent

			resolve_region := vk.ImageResolve {
				srcSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
				srcOffset = {0, 0, 0},
				dstSubresource = {mipLevel = 0, aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1},
				dstOffset = {0, 0, 0},
				extent = {ex.width, ex.height, 1},
			}

			vk.CmdResolveImage(
				cmd,
				// gfx.r_ctx.draw_image.image,
				gfx.r_ctx.draw_image.image,
				.TRANSFER_SRC_OPTIMAL,
				gfx.r_ctx.resolve_image.image,
				.TRANSFER_DST_OPTIMAL,
				1,
				&resolve_region,
			)

			gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .GENERAL)
			post_processing_pass(cmd)

			// Prepare swapchain image
			gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .TRANSFER_SRC_OPTIMAL)
			final_image = gfx.r_ctx.resolve_image.image
		} else {
			post_processing_pass(cmd)

			// Prepare swapchain image
			gfx.transition_image(cmd, &gfx.r_ctx.draw_image, .TRANSFER_SRC_OPTIMAL)
			final_image = gfx.r_ctx.draw_image.image
		}
	}

	gfx.copy_image_to_swapchain(cmd, final_image, gfx.r_ctx.draw_extent)

	sc := &gfx.r_ctx.swapchain
	sc_image := sc.swapchain_images[sc.swapchain_image_index]
	sc_view := sc.swapchain_image_views[sc.swapchain_image_index]

	gfx.transition_vk_image(cmd, sc_image, .TRANSFER_DST_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL)
	im_gfx.gfx_imgui_render(cmd, sc_view, sc.swapchain_extent)
	// submit() expects the swapchain image in TRANSFER_DST before it
	// transitions to PRESENT, so hand it back in that layout.
	gfx.transition_vk_image(cmd, sc_image, .COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_DST_OPTIMAL)

	swapchain_resized := gfx.submit(cmd)

	if swapchain_resized {
		gfx.write_descriptor_set(
			gfx.r_ctx.bindless_system.descriptor_set,
			{
				{
					binding = gfx.BINDLESS_STORAGE_IMAGES,
					type = .STORAGE_IMAGE,
					image_view = gfx.r_ctx.resolve_image.image_view,
					image_layout = .GENERAL,
					array_index = u32(game.render_state.temp_resources.resolved_image_id),
				},
			},
		)
	}

	clear(&current_frame_game().mesh_draws)
	clear(&current_frame_game().skel_instances)
	rt_scene_reset(&current_frame_game().rt)
	clear(&game.render_state.geometry_rp.model_matrices)
}

draw_mesh :: proc(mesh: GPUMeshBuffers, material: MaterialId, translation: Vec3, rotation: quaternion128, scale: [3]f32, include_in_raytracing := true) {
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

update_buffers :: proc() {
	global_data := &game.render_state.global_data
	player := get_entity(game.state.player_id)

	global_data.view_to_clip = get_current_projection_matrix()
	global_data.world_to_view = get_current_view_matrix()
	global_data.clip_to_world = linalg.inverse(global_data.view_to_clip * global_data.world_to_view)

	global_data.sun_color = game.state.environment.sun_color
	global_data.sky_color = game.state.environment.sky_color

	global_data.camera_pos = player != nil ? player.eye_pos : {0, 0, 0} // must match the render view (eye, not feet)
	global_data.sun_direction = game.state.environment.sun_direction

	global_data.environment.num_point_lights = auto_cast len_entities(PointLight)

	global_data.cascade_world_to_shadows = current_frame_game().cascade_matrices_buffer.ptr
	global_data.cascade_configs = current_frame_game().cascade_configs_buffer.ptr
	global_data.default_sampler = game.render_state.temp_resources.default_sampler_id

	// DDGI volumes: pack every volume into the array the lighting/trace/capture passes budget-fill
	// over. Sorted priority-desc so leading volumes claim coverage first (same as reflection probes).
	{
		packed: [MAX_DDGI_VOLUMES]GPUDDGIVolume
		count: u32 = 0
		for &volume in get_entities(DDGIVolume) {
			if int(count) >= MAX_DDGI_VOLUMES do break
			packed[count] = volume.gpu
			count += 1
		}
		slice.sort_by(packed[:count], proc(a, b: GPUDDGIVolume) -> bool {
			return a.priority > b.priority
		})
		if count > 0 {
			gfx.write_buffer_slice(&game.render_state.ddgi_rp.volumes_buffer, packed[:count])
		}
		global_data.ddgi_volumes = game.render_state.ddgi_rp.volumes_buffer.ptr
		global_data.num_ddgi_volumes = count
	}

	// Reflection probes: write each probe's own config (debug passes) and pack them all into
	// the array buffer the lighting pass loops over.
	{
		packed: [MAX_REFLECTION_PROBES]GPUReflectionProbe
		count: u32 = 0
		for &probe in get_entities(ReflectionProbe) {
			if int(count) >= MAX_REFLECTION_PROBES do break
			reflection_probe_write_config(&probe) // push live imgui edits
			packed[count] = reflection_probe_to_gpu(&probe)
			count += 1
		}
		// Higher priority first. The shader fills coverage in array order (budget fill), so
		// leading probes win in overlaps — deterministic, unlike get_entities order which
		// reshuffles on removal/reload.
		slice.sort_by(packed[:count], proc(a, b: GPUReflectionProbe) -> bool {
			return a.priority > b.priority
		})
		if count > 0 {
			gfx.write_buffer_slice(&game.render_state.reflection_probes_buffer, packed[:count])
		}
		global_data.reflection_probes = game.render_state.reflection_probes_buffer.ptr
		global_data.num_reflection_probes = count
	}

	gfx.write_buffer_slice(&current_frame_game().cascade_matrices_buffer, game.render_state.shadow_rp.cascade_world_to_shadows[:])
	gfx.write_buffer_slice(&current_frame_game().cascade_configs_buffer, game.render_state.shadow_rp.cascade_configs[:])
	gfx.write_buffer(&current_frame_game().global_buffer, global_data)

	gfx.write_buffer_slice(&current_frame_game().model_matrices_buffer, game.render_state.geometry_rp.model_matrices[:])

	for &point_light, i in get_entities(PointLight) {
		if i >= len(game.render_state.scene_resources.point_lights) do break
		game.render_state.scene_resources.point_lights[i] = point_light_to_gpu(point_light)
	}

	gfx.staging_write_buffer_slice(
		&game.render_state.scene_resources.point_light_buffer,
		game.render_state.scene_resources.point_lights[:],
	)

	calculate_shadow_view_projection_matrices()
}

renderer_shutdown :: proc() {
	// Wait for the GPU to finish before tearing down resources still in use (e.g. the
	// imgui buffers referenced by the last in-flight command buffer).
	gfx.vk_check(vk.DeviceWaitIdle(gfx.r_ctx.device))
	im_gfx.gfx_imgui_destroy()
}
