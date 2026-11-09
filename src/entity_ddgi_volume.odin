package game

import "core:fmt"
import "core:slice"
import "core:os"
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
	irradiance:     gfx.Image_Id `Image2D`, // RGBA16F
	depth:          gfx.Image_Id `Image2D`, // RG16F (mean, mean^2)
	offset:         gfx.Image_Id `Image2D`, // RGBA16F (relocation; zero for now)
	sampler:        gfx.Sampler_Id `Sampler`, // LINEAR, CLAMP_TO_EDGE
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

DDGI_Bake_State :: enum {
	Realtime,
	Warmup,
	Accumulate,
	Baked,
}

DDGI_Volume_Resources :: struct {
	gpu:                 GPUDDGIVolume,
	config_buffers:      [FRAME_OVERLAP]gfx.Buffer(GPUDDGIVolume), // TODO: separate this.
	radiance_buffer:     gfx.Buffer(Vec4), // rays_per_probe * num_probes
	irradiance:          gfx.Image_Id,
	depth:               gfx.Image_Id,
	offset:              gfx.Image_Id,

	// baking
	bake_state:          DDGI_Bake_State,
	bake_frame:          u32,
	warmup_frames:       u32,
	bake_frames:         u32,
	realtime_hysteresis: f32,
}

@(entity)
DDGIVolume :: struct {
	using entity: ^Entity,
	translation:  Vec3,
	using volume: DDGI_Volume_Resources,
}

ddgi_do_bake :: proc(volume: ^DDGIVolume) -> (should_trace, should_relocate: bool) {
	switch volume.bake_state {
	case .Realtime:
		volume.gpu.hysteresis = volume.realtime_hysteresis
		return true, true
	case .Warmup:
		volume.gpu.hysteresis = 0.9
		volume.bake_frame += 1
		if volume.bake_frame >= volume.warmup_frames {volume.bake_state = .Accumulate; volume.bake_frame = 0}
		return true, true
	case .Accumulate:
		n := f32(volume.bake_frame)
		volume.gpu.hysteresis = n / (n + 1)
		volume.bake_frame += 1
		if volume.bake_frame >= volume.bake_frames {
			volume.bake_state = .Baked
            volume.bake_frame = 0

            // hack: save readback of image into an asset
            gfx.wait_idle()

            engine_id := game.state.current_scene.engine_ids[volume.id]

            irradiance_extent := gfx.image_meta(volume.irradiance).extent
            depth_extent := gfx.image_meta(volume.depth).extent
            offset_extent := gfx.image_meta(volume.offset).extent

            irradiance_buffer_len := irradiance_extent.x * irradiance_extent.y * 4 // RGBA16f
            depth_buffer_len      := depth_extent.x * depth_extent.y * 2           // RG16f
            offset_buffer_len     := offset_extent.x * offset_extent.y * 4         // RGBA16f

            irradiance_buffer := gfx.create_buffer(f16, irradiance_buffer_len, .Host_Random)
            depth_buffer := gfx.create_buffer(f16, depth_buffer_len, .Host_Random)
            offset_buffer := gfx.create_buffer(f16, offset_buffer_len, .Host_Random)

            {
                cmd := gfx.begin_command_buffer(.Main)

                gfx.cmd_copy_image_to_buffer(cmd, volume.irradiance, irradiance_buffer)
                gfx.cmd_copy_image_to_buffer(cmd, volume.depth, depth_buffer)
                gfx.cmd_copy_image_to_buffer(cmd, volume.offset, offset_buffer)

                sema_wait := gfx.queue_submit(.Main, cmd)
                gfx.wait_semaphore(sema_wait)
            }

            assert(irradiance_buffer.info.pMappedData != nil)
            assert(depth_buffer.info.pMappedData != nil)
            assert(offset_buffer.info.pMappedData != nil)

            irradiance_slice := slice.bytes_from_ptr(irradiance_buffer.info.pMappedData, auto_cast (irradiance_buffer_len * 2))
            depth_slice := slice.bytes_from_ptr(depth_buffer.info.pMappedData, auto_cast (depth_buffer_len * 2))
            offset_slice := slice.bytes_from_ptr(offset_buffer.info.pMappedData, auto_cast (offset_buffer_len * 2))

            a := os.write_entire_file(fmt.tprint("assets/temp/", engine_id, "_irradiance", sep = ""), irradiance_slice)
            b := os.write_entire_file(fmt.tprint("assets/temp/", engine_id, "_depth", sep = ""), depth_slice)
            c := os.write_entire_file(fmt.tprint("assets/temp/", engine_id, "_offset", sep = ""), offset_slice)
		}
		return true, false
	case .Baked:
		return false, false
	}
	return false, false
}

// TODO: make this part of the entity...
ddgi_volume_resources_init :: proc(
	volume: ^DDGI_Volume_Resources,
	origin: Vec3,
	spacing: Vec3,
	counts: [3]u32,
	arena: ^gfx.Deletion_Queue,
	priority: f32 = 0.0,
	edge_fade: f32 = 1.0,
    engine_id := "",
) {
	volume.bake_state = .Accumulate
	volume.realtime_hysteresis = 0.99
	volume.warmup_frames = 96
	volume.bake_frames = 256
	volume.realtime_hysteresis = 0.99

	tiles_x := counts.x * counts.z
	tiles_y := counts.y

	atlas_usage: vk.ImageUsageFlags : {.STORAGE, .SAMPLED, .TRANSFER_DST, .TRANSFER_SRC}
	volume.irradiance = gfx.create_image(.R16G16B16A16_SFLOAT, {tiles_x * DDGI_IRR_TILE, tiles_y * DDGI_IRR_TILE, 1}, atlas_usage)
	volume.depth = gfx.create_image(.R16G16_SFLOAT, {tiles_x * DDGI_DEPTH_TILE, tiles_y * DDGI_DEPTH_TILE, 1}, atlas_usage)
	volume.offset = gfx.create_image(.R16G16B16A16_SFLOAT, {tiles_x, tiles_y, 1}, atlas_usage)

    irradiance_extent := gfx.image_meta(volume.irradiance).extent
    depth_extent := gfx.image_meta(volume.depth).extent
    offset_extent := gfx.image_meta(volume.offset).extent

    irradiance_data, irr_err := os.read_entire_file(fmt.tprint("assets/temp/", engine_id, "_irradiance", sep = ""), context.temp_allocator)
    depth_data, depth_err := os.read_entire_file(fmt.tprint("assets/temp/", engine_id, "_depth", sep = ""), context.temp_allocator)
    offset_data, offset_err := os.read_entire_file(fmt.tprint("assets/temp/", engine_id, "_offset", sep = ""), context.temp_allocator)

	gfx.defer_destroy(arena, volume.irradiance)
	gfx.defer_destroy(arena, volume.depth)
	gfx.defer_destroy(arena, volume.offset)

    if irr_err == nil && depth_err == nil && offset_err == nil {
        volume.bake_state = .Baked
    }

	{
        cmd := gfx.begin_command_buffer(.Main)

		gfx.transition_image(cmd, volume.irradiance, .General)
		gfx.transition_image(cmd, volume.depth, .General)
		gfx.transition_image(cmd, volume.offset, .General)

        if irr_err == nil && depth_err == nil && offset_err == nil {
            irradiance_buffer_len := irradiance_extent.x * irradiance_extent.y * 4 // RGBA16f
            depth_buffer_len      := depth_extent.x * depth_extent.y * 2           // RG16f
            offset_buffer_len     := offset_extent.x * offset_extent.y * 4         // RGBA16f

            irradiance_buffer := gfx.create_buffer(f16, irradiance_buffer_len, .Host_Sequential_Write)
            gfx.defer_destroy(frame_arena(), irradiance_buffer)

            depth_buffer := gfx.create_buffer(f16, depth_buffer_len, .Host_Sequential_Write)
            gfx.defer_destroy(frame_arena(), depth_buffer)

            offset_buffer := gfx.create_buffer(f16, offset_buffer_len, .Host_Sequential_Write)
            gfx.defer_destroy(frame_arena(), offset_buffer)

            gfx.write_buffer_slice(&irradiance_buffer, irradiance_data)
            gfx.write_buffer_slice(&depth_buffer, depth_data)
            gfx.write_buffer_slice(&offset_buffer, offset_data)

            gfx.cmd_copy_buffer_to_image(cmd, irradiance_buffer, volume.irradiance)
            gfx.cmd_copy_buffer_to_image(cmd, depth_buffer, volume.depth)
            gfx.cmd_copy_buffer_to_image(cmd, offset_buffer, volume.offset)
        } else {
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

        done := gfx.queue_submit(.Main, cmd)
        gfx.wait_semaphore(done)
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
		config_buffer = gfx.create_buffer(GPUDDGIVolume, 1, .Host_Sequential_Write)
		gfx.defer_destroy(arena, config_buffer)
		gfx.write_buffer(&config_buffer, &volume.gpu)
	}

	num_probes := counts.x * counts.y * counts.z
	volume.radiance_buffer = gfx.create_buffer(Vec4, num_probes * DDGI_RAYS_PER_PROBE)
	gfx.defer_destroy(arena, volume.radiance_buffer)
}
