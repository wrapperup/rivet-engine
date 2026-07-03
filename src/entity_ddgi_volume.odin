package game

import "core:math"
import "core:math/linalg"

import "gfx"
import vk "vendor:vulkan"

@(private = "file")
GPUPtr :: gfx.GPUPtr
@(private = "file")
ImageId :: gfx.ImageId
@(private = "file")
SamplerId :: gfx.SamplerId


DDGI_PROBE_IRR_TEXELS :: 6 // interior; +1px border each side -> 8x8 tile
DDGI_PROBE_DEPTH_TEXELS :: 14 // +border -> 16x16 tile
DDGI_RAYS_PER_PROBE :: 384

DDGI_IRR_TILE :: DDGI_PROBE_IRR_TEXELS + 2 // 8
DDGI_DEPTH_TILE :: DDGI_PROBE_DEPTH_TEXELS + 2 // 16

DDGI_UPDATE_BLOCKS_PER_PROBE :: (DDGI_PROBE_IRR_TEXELS * DDGI_PROBE_IRR_TEXELS + 63) / 64 + (DDGI_PROBE_DEPTH_TEXELS * DDGI_PROBE_DEPTH_TEXELS + 63) / 64

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
	config_buffer:   gfx.GPUBuffer(GPUDDGIVolume),
	radiance_buffer: gfx.GPUBuffer(Vec4), // rays_per_probe * num_probes
	irradiance:      gfx.GPUImage,
	depth:           gfx.GPUImage,
	offset:          gfx.GPUImage,
}

@(entity)
DDGIVolume :: struct {
	using entity: ^Entity,
	using volume: DDGI_Volume_Resources,
}

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
		gfx.transition_image(cmd, &volume.irradiance, .GENERAL)
		gfx.transition_image(cmd, &volume.depth, .GENERAL)
		gfx.transition_image(cmd, &volume.offset, .GENERAL)

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
		vk.CmdClearColorImage(cmd, volume.irradiance.image, .GENERAL, &zero, 1, &range)
		vk.CmdClearColorImage(cmd, volume.depth.image, .GENERAL, &far, 1, &range)
		vk.CmdClearColorImage(cmd, volume.offset.image, .GENERAL, &offset_init, 1, &range)
	}

	sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE)
	gfx.defer_destroy(arena, sampler)

	volume.gpu = GPUDDGIVolume {
		grid_origin    = origin,
		probe_spacing  = spacing,
		grid_counts    = counts,
		rays_per_probe = DDGI_RAYS_PER_PROBE,
		irradiance     = gfx.add_image(volume.irradiance),
		depth          = gfx.add_image(volume.depth),
		offset         = gfx.add_image(volume.offset),
		sampler        = gfx.add_sampler(sampler),
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

	volume.config_buffer = gfx.create_buffer(GPUDDGIVolume, 1, .DynUniform)
	gfx.defer_destroy(arena, volume.config_buffer)
	gfx.write_buffer(&volume.config_buffer, &volume.gpu)

	num_probes := counts.x * counts.y * counts.z
	volume.radiance_buffer = gfx.create_buffer(Vec4, num_probes * DDGI_RAYS_PER_PROBE, .Storage)
	gfx.defer_destroy(arena, volume.radiance_buffer)
}

ddgi_volume_resources_destroy :: proc(volume: ^DDGI_Volume_Resources) {
	gfx.remove_image(volume.gpu.irradiance)
	gfx.remove_image(volume.gpu.depth)
	gfx.remove_image(volume.gpu.offset)
	gfx.remove_sampler(volume.gpu.sampler)
}

ddgi_volume_destroy :: proc(volume: ^DDGIVolume) {
    ddgi_volume_resources_destroy(&volume.volume)
}

@(shader_shared)
GPUDDGITracePush :: struct #max_field_align(16) {
	volume:     GPUPtr(GPUDDGIVolume),
	geometries: GPUPtr(GPUGeometry),
	materials:  GPUPtr(GPUMaterial),
	global:     GPUPtr(GPUGlobalData),
	radiance:   GPUPtr(Vec4),
	tlas:       vk.DeviceAddress `AccelerationStructure`,
}

@(shader_shared)
GPUDDGIUpdatePush :: struct #max_field_align(16) {
	volume:     GPUPtr(GPUDDGIVolume),
	radiance:   GPUPtr(Vec4),
	irradiance: ImageId `RWImage2D`,
	visibility: ImageId `RWImage2D`,
	probe_data: ImageId `RWImage2D`,
}

@(shader_shared)
GPUDDGIRelocatePush :: struct #max_field_align(16) {
	volume:         GPUPtr(GPUDDGIVolume),
	radiance:       GPUPtr(Vec4),
	probe_data:     ImageId `RWImage2D`,
	first_frame:    u32,
	adjust_offsets: u32,
}

@(shader_shared)
GPUDDGIDebugAtlasPush :: struct #max_field_align(16) {
	volume:    GPUPtr(GPUDDGIVolume),
	out_image: ImageId `RWImage2D`,
}

@(shader_shared)
GPUDDGIProbePush :: struct #max_field_align(16) {
	global:        GPUPtr(GPUGlobalData),
	volume:        GPUPtr(GPUDDGIVolume),
	vertex_buffer: GPUPtr(Vertex),
	probe_radius:  f32,
}

// Generates a UV sphere (positions == normals, unit radius).
@(private = "file")
ddgi_make_sphere :: proc(rings, sectors: int) -> ([]Vertex, []u32) {
	verts := make([dynamic]Vertex)
	indices := make([dynamic]u32)
	for r in 0 ..= rings {
		theta := f32(r) / f32(rings) * math.PI
		st := math.sin(theta)
		ct := math.cos(theta)
		for s in 0 ..= sectors {
			phi := f32(s) / f32(sectors) * 2.0 * math.PI
			n := Vec3{st * math.cos(phi), ct, st * math.sin(phi)}
			append(&verts, Vertex{position = {n.x, n.y, n.z}, normal = {n.x, n.y, n.z}})
		}
	}
	for r in 0 ..< rings {
		for s in 0 ..< sectors {
			i0 := u32(r * (sectors + 1) + s)
			i1 := u32(r * (sectors + 1) + s + 1)
			i2 := u32((r + 1) * (sectors + 1) + s)
			i3 := u32((r + 1) * (sectors + 1) + s + 1)
			append(&indices, i0, i2, i1, i1, i2, i3)
		}
	}
	return verts[:], indices[:]
}

ddgi_init_debug_sphere :: proc() {
	rs := &game.render_state
	verts, indices := ddgi_make_sphere(12, 16)
	defer delete(verts)
	defer delete(indices)

	rs.ddgi_probe_vbuf = gfx.create_buffer(Vertex, len(verts))
	rs.ddgi_probe_ibuf = gfx.create_buffer(u32, len(indices), .Index)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rs.ddgi_probe_vbuf)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rs.ddgi_probe_ibuf)
	gfx.staging_write_buffer_slice(&rs.ddgi_probe_vbuf, verts)
	gfx.staging_write_buffer_slice(&rs.ddgi_probe_ibuf, indices)
	rs.ddgi_probe_index_count = u32(len(indices))
}

ddgi_debug_probes_pass :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	rs := &game.render_state
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		depth_attachment = &{view = gfx.r_ctx.depth_image.image_view, layout = .DEPTH_ATTACHMENT_OPTIMAL},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)
	gfx.cmd_bind_pipeline(cmd, rs.ddgi_probe_pipeline)
	gfx.cmd_bind_index_buffer(cmd, rs.ddgi_probe_ibuf.buffer)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGIProbePush {
			global = current_frame_game().global_buffer.ptr,
			volume = volume.config_buffer.ptr,
			vertex_buffer = rs.ddgi_probe_vbuf.ptr,
			probe_radius = 0.3,
		},
	)
	counts := volume.gpu.grid_counts
	gfx.cmd_draw_indexed(cmd, rs.ddgi_probe_index_count, instance_count = counts[0] * counts[1] * counts[2])
	gfx.cmd_end_rendering(cmd)
}

ddgi_update_volume :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	counts := volume.gpu.grid_counts
	num_probes := counts[0] * counts[1] * counts[2]

	// Advance the ray set and push the config.
	volume.gpu.frame_index += 1
	gfx.write_buffer(&volume.config_buffer, &volume.gpu)

	update_push := GPUDDGIUpdatePush {
		volume     = volume.config_buffer.ptr,
		radiance   = volume.radiance_buffer.ptr,
		irradiance = volume.gpu.irradiance,
		visibility = volume.gpu.depth,
		probe_data = volume.gpu.offset,
	}

	// Pass A: trace.
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_trace_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGITracePush {
			volume = volume.config_buffer.ptr,
			geometries = current_frame_game().geometries_buffer.ptr,
			materials = game.render_state.scene_resources.materials_buffer.ptr,
			global = current_frame_game().global_buffer.ptr,
			radiance = volume.radiance_buffer.ptr,
			tlas = current_frame_game().tlas.address,
		},
	)
	vk.CmdDispatch(cmd, num_probes, 1, 1)

	// radiance write -> read barrier before the passes below read it.
	gfx.transition_buffer(cmd, volume.radiance_buffer, {.SHADER_WRITE}, {.SHADER_READ}, gfx.r_ctx.graphics_queue_family)

	init_iteration := volume.gpu.frame_index
	if init_iteration >= 1 && init_iteration <= 6 {
		gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_relocate_pipeline)
		gfx.cmd_push_constants(
			cmd,
			GPUDDGIRelocatePush {
				volume = volume.config_buffer.ptr,
				radiance = volume.radiance_buffer.ptr,
				probe_data = volume.gpu.offset,
				first_frame = u32(init_iteration == 1),
				adjust_offsets = u32(init_iteration <= 5),
			},
		)
		vk.CmdDispatch(cmd, (num_probes + 63) / 64, 1, 1)
		ddgi_image_barrier(cmd, volume.offset.image)
	}

	// Pass B: update irradiance and visibility.
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_update_pipeline)
	gfx.cmd_push_constants(cmd, update_push)
	vk.CmdDispatch(cmd, num_probes, 1, DDGI_UPDATE_BLOCKS_PER_PROBE)

	// interior write -> read before the border copy reads edge texels.
	ddgi_image_barrier(cmd, volume.irradiance.image)
	ddgi_image_barrier(cmd, volume.depth.image)

	// Pass C: octahedral border copy.
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_border_pipeline)
	gfx.cmd_push_constants(cmd, update_push)
	vk.CmdDispatch(cmd, num_probes, 1, 1)
	ddgi_image_barrier(cmd, volume.irradiance.image)
	ddgi_image_barrier(cmd, volume.depth.image)
	ddgi_image_barrier(cmd, volume.offset.image)
}

ddgi_image_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask = {.ALL_COMMANDS},
		dstAccessMask = {.SHADER_READ},
		oldLayout = .GENERAL,
		newLayout = .GENERAL,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

ddgi_debug_atlas_pass :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_debug_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGIDebugAtlasPush{volume = volume.config_buffer.ptr, out_image = game.render_state.temp_resources.resolved_image_id},
	)
	vk.CmdDispatch(cmd, u32(gfx.r_ctx.draw_extent.width + 15) / 16, u32(gfx.r_ctx.draw_extent.height + 15) / 16, 1)
}
