package game

import "core:math"
import "core:math/linalg"

import vk "vendor:vulkan"

import "gfx"

AtmosphereSettings :: struct {
	rayleigh_density: f32,
	mie_density:      f32,
	ozone_density:    f32,
	ground_albedo:    f32,
	ground_height:    f32, // World-space metres; atmosphere uses kilometres internally.
}

default_atmosphere_settings :: proc() -> AtmosphereSettings {
	return {rayleigh_density = 1, mie_density = 1, ozone_density = 1, ground_albedo = 0.3}
}

@(shader_shared)
GPUAtmosphere :: struct #max_field_align(16) {
	transmittance:        gfx.ImageId `Image2D`,
	multiple_scattering:  gfx.ImageId `Image2D`,
	sky_view:             gfx.ImageId `Image2D`,
	aerial_scattering:    gfx.ImageId `Image3D`,
	aerial_transmittance: gfx.ImageId `Image3D`,
	sampler:              gfx.SamplerId `Sampler`,
	rayleigh_density:     f32,
	mie_density:          f32,
	ozone_density:        f32,
	ground_albedo:        f32,
	ground_height:        f32,
	camera_height:        f32,
	sun_radius:           f32,
}

@(shader_shared)
GPUAtmosphereLutPush :: struct #max_field_align(16) {
	global: gfx.Ptr(GPUGlobalData),
	output: gfx.ImageId `RWImage2D`,
}

@(shader_shared)
GPUAtmosphereCubePush :: struct #max_field_align(16) {
	global: gfx.Ptr(GPUGlobalData),
	output: gfx.ImageId `RWImage2DArray`,
}

@(shader_shared)
GPUAtmosphereAerialPush :: struct #max_field_align(16) {
	global:        gfx.Ptr(GPUGlobalData),
	scattering:    gfx.ImageId `RWImage3D`,
	transmittance: gfx.ImageId `RWImage3D`,
}

@(shader_shared)
GPUAtmosphereDrawPush :: struct #max_field_align(16) {
	global: gfx.Ptr(GPUGlobalData),
}

AtmosphereRenderPass :: struct {
	transmittance:                gfx.Image,
	multiple_scattering:          gfx.Image,
	sky_view:                     gfx.Image,
	aerial_scattering:            gfx.Image,
	aerial_transmittance:         gfx.Image,
	environment:                  gfx.Image,
	environment_id:               gfx.ImageId,
	environment_mips:             [9]gfx.ImageId,
	parameters:                   GPUAtmosphere,
	transmittance_pipeline:       ^gfx.ComputePipeline,
	multiple_scattering_pipeline: ^gfx.ComputePipeline,
	sky_view_pipeline:            ^gfx.ComputePipeline,
	environment_pipeline:         ^gfx.ComputePipeline,
	aerial_pipeline:              ^gfx.ComputePipeline,
	draw_pipeline:                ^gfx.GraphicsPipeline,
	last_settings:                AtmosphereSettings,
	last_sun_direction:           Vec3,
	last_sun_color:               Vec3,
	last_sky_color:               Vec3,
	last_camera_height:           f32,
	initialized:                  bool,
	force_update:                 bool,
}

init_atmosphere_rp :: proc() {
	rp := &game.render_state.atmosphere_rp
	a := &rp.parameters

	rp.transmittance = gfx.create_image(.R16G16B16A16_SFLOAT, {256, 64, 1}, {.SAMPLED, .STORAGE})
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.transmittance)

	rp.multiple_scattering = gfx.create_image(.R16G16B16A16_SFLOAT, {32, 32, 1}, {.SAMPLED, .STORAGE})
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.multiple_scattering)

	rp.sky_view = gfx.create_image(.R16G16B16A16_SFLOAT, {192, 108, 1}, {.SAMPLED, .STORAGE, .TRANSFER_SRC})
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.sky_view)

	rp.aerial_scattering = gfx.create_image(.R16G16B16A16_SFLOAT, {32, 32, 32}, {.SAMPLED, .STORAGE}, image_type = .D3)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.aerial_scattering)

	rp.aerial_transmittance = gfx.create_image(.R16G16B16A16_SFLOAT, {32, 32, 32}, {.SAMPLED, .STORAGE}, image_type = .D3)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.aerial_transmittance)

	a.transmittance = gfx.add_image(rp.transmittance)
	a.multiple_scattering = gfx.add_image(rp.multiple_scattering)
	a.sky_view = gfx.add_image(rp.sky_view)
	a.aerial_scattering = gfx.add_image(rp.aerial_scattering)
	a.aerial_transmittance = gfx.add_image(rp.aerial_transmittance)
	a.sampler = game.render_state.temp_resources.env_sampler_id
	a.sun_radius = math.to_radians(f32(5))

	rp.environment = gfx.create_image(
		.R16G16B16A16_SFLOAT,
		{256, 256, 1},
		{.SAMPLED, .STORAGE},
		mip_levels = 9,
		array_layers = 6,
		flags = {.CUBE_COMPATIBLE},
	)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.environment)

	sampled := rp.environment
	sampled.usage = {.SAMPLED}
	rp.environment_id = gfx.add_image(sampled)
	for &id, mip in rp.environment_mips {
		view := gfx.create_image_view(
			rp.environment.image,
			rp.environment.format,
			.D2_ARRAY,
			base_mip_level = u32(mip),
			mip_levels = 1,
			array_layers = 6,
		)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, view)
		storage := rp.environment
		storage.usage = {.STORAGE}
		id = gfx.add_image(storage, view)
	}

	rp.transmittance_pipeline = add_compute_shader(
		"shaders/atmosphere_transmittance.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Atmosphere_Transmittance", module, GPUAtmosphereLutPush)
		},
	)
	rp.multiple_scattering_pipeline = add_compute_shader(
		"shaders/atmosphere_multiple_scattering.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Atmosphere_MultipleScattering", module, GPUAtmosphereLutPush)
		},
	)
	rp.sky_view_pipeline = add_compute_shader("shaders/atmosphere_sky_view.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("Atmosphere_SkyView", module, GPUAtmosphereLutPush)
	})
	rp.environment_pipeline = add_compute_shader(
		"shaders/atmosphere_environment.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Atmosphere_Environment", module, GPUAtmosphereCubePush)
		},
	)
	rp.aerial_pipeline = add_compute_shader("shaders/atmosphere_aerial.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("Atmosphere_Aerial", module, GPUAtmosphereAerialPush)
	})
	rp.draw_pipeline = add_graphics_shader("shaders/atmosphere.slang", proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
		return gfx.create_graphics_pipeline(
			name = "Atmosphere_Sky",
			shader = module,
			input_topology = .TRIANGLE_LIST,
			polygon_mode = .FILL,
			cull_mode = {},
			front_face = .COUNTER_CLOCKWISE,
			color_format = gfx.r_ctx.draw_image.format,
			multisampling_samples = gfx.msaa_samples(),
			push_constants = GPUAtmosphereDrawPush,
		)
	})
}

atmosphere_prepare :: proc() {
	env := &game.state.environment
	if linalg.length(env.sun_direction) < 0.0001 {
		env.sun_direction = {0, 1, 0}
	} else {
		env.sun_direction = linalg.normalize(env.sun_direction)
	}
	settings := &env.atmosphere
	settings.rayleigh_density = clamp(settings.rayleigh_density, 0, 4)
	settings.mie_density = clamp(settings.mie_density, 0, 10)
	settings.ozone_density = clamp(settings.ozone_density, 0, 4)
	settings.ground_albedo = clamp(settings.ground_albedo, 0, 0.95)
	rp := &game.render_state.atmosphere_rp

	if rp.initialized &&
	   (rp.force_update ||
			   rp.last_settings != settings^ ||
			   rp.last_sun_direction != env.sun_direction ||
			   rp.last_sun_color != env.sun_color ||
			   rp.last_sky_color != env.sky_color) {
		for &probe in get_entities(ReflectionProbe) {
			probe.wants_recapture = true
		}
	}

	a := &game.render_state.atmosphere_rp.parameters
	a.rayleigh_density = settings.rayleigh_density
	a.mie_density = settings.mie_density
	a.ozone_density = settings.ozone_density
	a.ground_albedo = settings.ground_albedo
	a.ground_height = settings.ground_height
	player := get_entity(game.state.player_id)
	height := player != nil ? player.eye_pos.y : 0

	// Quantize height to metres to limit LUT and reflection rebuilds.
	a.camera_height = clamp(math.floor(height - settings.ground_height) * 0.001, 0.002, 99.0)
	game.render_state.global_data.atmosphere = a^
}

@(private = "file")
atmosphere_begin_write :: proc(cmd: vk.CommandBuffer, img: ^gfx.Image) {
	gfx.image_barrier(cmd, img, .AllReadsWrites, .ComputeShaderWrite, new_layout = .GENERAL)
}

@(private = "file")
atmosphere_end_write :: proc(cmd: vk.CommandBuffer, img: ^gfx.Image) {
	gfx.image_barrier(cmd, img, .ComputeShaderWrite, .ComputeFragmentShaderRead)
}

@(private = "file")
record_atmosphere_lut :: proc(cmd: vk.CommandBuffer, pipeline: ^gfx.ComputePipeline, img: ^gfx.Image, id: gfx.ImageId) {
	atmosphere_begin_write(cmd, img)
	gfx.cmd_bind_pipeline(cmd, pipeline)
	gfx.cmd_push_constants(cmd, GPUAtmosphereLutPush{global = current_frame_game().global_buffer.ptr, output = id})
	vk.CmdDispatch(cmd, (img.extent.width + 7) / 8, (img.extent.height + 7) / 8, 1)
	atmosphere_end_write(cmd, img)
}

record_atmosphere_pass :: proc(cmd: vk.CommandBuffer) {
	rp := &game.render_state.atmosphere_rp
	env := &game.state.environment
	medium_changed := !rp.initialized || rp.force_update || rp.last_settings != env.atmosphere
	sky_changed := medium_changed || rp.last_sun_direction != env.sun_direction || rp.last_camera_height != rp.parameters.camera_height
	environment_changed := sky_changed || rp.last_sun_color != env.sun_color
	if medium_changed {
		record_atmosphere_lut(cmd, rp.transmittance_pipeline, &rp.transmittance, rp.parameters.transmittance)
		record_atmosphere_lut(cmd, rp.multiple_scattering_pipeline, &rp.multiple_scattering, rp.parameters.multiple_scattering)
	}
	if sky_changed {
		record_atmosphere_lut(cmd, rp.sky_view_pipeline, &rp.sky_view, rp.parameters.sky_view)
	}
	if environment_changed {
		atmosphere_begin_write(cmd, &rp.environment)
		gfx.cmd_bind_pipeline(cmd, rp.environment_pipeline)
		gfx.cmd_push_constants(
			cmd,
			GPUAtmosphereCubePush{global = current_frame_game().global_buffer.ptr, output = rp.environment_mips[0]},
		)
		vk.CmdDispatch(cmd, 32, 32, 6)
		atmosphere_end_write(cmd, &rp.environment)
		gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_prefilter_pipeline)
		for mip in u32(1) ..< 9 {
			size := u32(256) >> mip
			gfx.cmd_push_constants(
				cmd,
				GPUReflectionPrefilterPush {
					src_cube = rp.environment_id,
					sampler = rp.parameters.sampler,
					out_mip = rp.environment_mips[mip],
					face_size = size,
					roughness = f32(mip) / 8,
					sample_count = 64,
				},
			)
			vk.CmdDispatch(cmd, (size + 7) / 8, (size + 7) / 8, 6)
		}
		atmosphere_end_write(cmd, &rp.environment)
	}
	// Rebuild view-dependent aerial perspective each frame.
	atmosphere_begin_write(cmd, &rp.aerial_scattering)
	atmosphere_begin_write(cmd, &rp.aerial_transmittance)
	gfx.cmd_bind_pipeline(cmd, rp.aerial_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUAtmosphereAerialPush {
			global = current_frame_game().global_buffer.ptr,
			scattering = rp.parameters.aerial_scattering,
			transmittance = rp.parameters.aerial_transmittance,
		},
	)
	vk.CmdDispatch(cmd, 8, 8, 8)
	atmosphere_end_write(cmd, &rp.aerial_scattering)
	atmosphere_end_write(cmd, &rp.aerial_transmittance)
	rp.initialized = true
	rp.force_update = false
	rp.last_settings = env.atmosphere
	rp.last_sun_direction = env.sun_direction
	rp.last_sun_color = env.sun_color
	rp.last_sky_color = env.sky_color
	rp.last_camera_height = rp.parameters.camera_height
}

record_atmosphere_background :: proc(cmd: vk.CommandBuffer) {
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)
	gfx.cmd_bind_pipeline(cmd, game.render_state.atmosphere_rp.draw_pipeline)
	gfx.cmd_push_constants(cmd, GPUAtmosphereDrawPush{global = current_frame_game().global_buffer.ptr})
	vk.CmdDraw(cmd, 3, 1, 0, 0)
	gfx.cmd_end_rendering(cmd)
}
