package game

import "core:math/linalg"

import "gfx"
import vk "vendor:vulkan"


DDGI_PROBE_IRR_TEXELS :: 6 // interior; +1px border each side -> 8x8 tile
DDGI_PROBE_DEPTH_TEXELS :: 14 // +border -> 16x16 tile
DDGI_RAYS_PER_PROBE :: 384

DDGI_IRR_TILE :: DDGI_PROBE_IRR_TEXELS + 2 // 8
DDGI_DEPTH_TILE :: DDGI_PROBE_DEPTH_TEXELS + 2 // 16

// Atlas layout: tiles packed as (x + z*nx) across, y down. So tiles_x = nx*nz, tiles_y = ny.
@(shader_shared)
GPUDDGIVolume :: struct #max_field_align(16) {
	grid_origin:    Vec3, // world-space corner (probe 0)
	rays_per_probe: u32,
	probe_spacing:  Vec3, // world units between probes
	grid_counts:    [3]u32, // e.g. {16, 8, 16}
	irradiance:     gfx.ImageId `Image2D`, // RGBA16F
	depth:          gfx.ImageId `Image2D`, // RG16F (mean, mean^2)
	offset:         gfx.ImageId `Image2D`, // RGBA16F (relocation; zero for now)
	sampler:        gfx.SamplerId `Sampler`, // LINEAR, CLAMP_TO_EDGE
	hysteresis:     f32, // 0.97 realtime
	max_distance:   f32, // ~1.5 * length(probe_spacing)
	normal_bias:    f32,
	frame_index:    u32, // rotates the ray set
	intensity:      f32,
	feedback:       f32,
	depth_bias:     f32, // added to recorded front-face depth (less edge self-occlusion)
	relocation_max: f32, // max probe relocation offset, in cells (~0.45 keeps trilinear valid)
	cheb_sharpness: f32, // Chebyshev visibility falloff power (higher = less thin-wall leak)
	ray_max:        f32, // primary ray max distance (decoupled from the Chebyshev range)
	max_radiance:   f32, // firefly clamp: max luminance per traced ray (0 = disabled)
	priority:       f32,
	edge_fade:      f32,
}

MAX_DDGI_VOLUMES :: 8

DDGI_Volume_Resources :: struct {
	gpu:             GPUDDGIVolume,
	config_buffers:  [gfx.FRAME_OVERLAP]gfx.Buffer(GPUDDGIVolume),
	radiance_buffer: gfx.Buffer(Vec4), // rays_per_probe * num_probes
	irradiance:      gfx.ImageId,
	depth:           gfx.ImageId,
	offset:          gfx.ImageId,
}

@(entity)
DDGIVolume :: struct {
	using entity: ^Entity,
	translation:  Vec3,
	using volume: DDGI_Volume_Resources,
}

// TODO: make this part of the entity...
ddgi_volume_resources_init :: proc(
	volume: ^DDGI_Volume_Resources,
	origin: Vec3,
	spacing: Vec3,
	counts: [3]u32,
	arena: ^gfx.ResourceArena,
	priority: f32 = 0.0,
	edge_fade: f32 = 1.0,
) {
	tiles_x := counts.x * counts.z
	tiles_y := counts.y

	atlas_usage: vk.ImageUsageFlags : {.STORAGE, .SAMPLED, .TRANSFER_DST}
	volume.irradiance = gfx.create_image(.R16G16B16A16_SFLOAT, {tiles_x * DDGI_IRR_TILE, tiles_y * DDGI_IRR_TILE, 1}, atlas_usage)
	volume.depth = gfx.create_image(.R16G16_SFLOAT, {tiles_x * DDGI_DEPTH_TILE, tiles_y * DDGI_DEPTH_TILE, 1}, atlas_usage)
	volume.offset = gfx.create_image(.R16G16B16A16_SFLOAT, {tiles_x, tiles_y, 1}, atlas_usage)

	gfx.defer_destroy(arena, volume.irradiance)
	gfx.defer_destroy(arena, volume.depth)
	gfx.defer_destroy(arena, volume.offset)

	if cmd, ok := gfx.immediate_submit(); ok {
		gfx.transition_image(cmd, volume.irradiance, .GENERAL)
		gfx.transition_image(cmd, volume.depth, .GENERAL)
		gfx.transition_image(cmd, volume.offset, .GENERAL)

		range := vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			levelCount = 1,
			layerCount = 1,
		}
		zero := vk.ClearColorValue {
			float32 = {0, 0, 0, 0},
		}
		md := 1.5 * linalg.length(spacing)
		far := vk.ClearColorValue {
			float32 = {md, md * md, 0, 0},
		}
		offset_init := vk.ClearColorValue {
			float32 = {0, 0, 0, 1},
		}
		gfx.cmd_clear_color_image(cmd, volume.irradiance, &zero, {range})
		gfx.cmd_clear_color_image(cmd, volume.depth, &far, {range})
		gfx.cmd_clear_color_image(cmd, volume.offset, &offset_init, {range})
	}

	sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE)
	gfx.defer_destroy(arena, sampler)

	volume.gpu = GPUDDGIVolume {
		grid_origin    = origin,
		probe_spacing  = spacing,
		grid_counts    = counts,
		rays_per_probe = DDGI_RAYS_PER_PROBE,
		irradiance     = volume.irradiance,
		depth          = volume.depth,
		offset         = volume.offset,
		sampler        = sampler,
		hysteresis     = 0.99,
		max_distance   = 1.5 * linalg.length(spacing),
		normal_bias    = 0.2 * min(spacing.x, spacing.y, spacing.z),
		frame_index    = 0,
		intensity      = 1.0,
		feedback       = 0.8,
		depth_bias     = 0.0,
		relocation_max = 0.45,
		cheb_sharpness = 3.0,
		ray_max        = 200.0,
		max_radiance   = 8.0,
		priority       = priority,
		edge_fade      = edge_fade,
	}

	for &config_buffer in volume.config_buffers {
		config_buffer = gfx.create_buffer(GPUDDGIVolume, 1, .DynUniform)
		gfx.defer_destroy(arena, config_buffer)
		gfx.write_buffer(&config_buffer, &volume.gpu)
	}

	num_probes := counts.x * counts.y * counts.z
	volume.radiance_buffer = gfx.create_buffer(Vec4, num_probes * DDGI_RAYS_PER_PROBE, .Storage)
	gfx.defer_destroy(arena, volume.radiance_buffer)
}
