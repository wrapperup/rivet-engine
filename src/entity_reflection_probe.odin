package game

import "core:math"

import "gfx"
import vk "vendor:vulkan"

// File-private aliases so the @shader_shared bindgen sees the bare names.
@(private = "file")
GPUPtr :: gfx.GPUPtr
@(private = "file")
ImageId :: gfx.ImageId
@(private = "file")
SamplerId :: gfx.SamplerId

@(shader_shared)
GPUReflectionProbe :: struct #max_field_align(16) {
	center:         Vec3,
	blend_distance: f32,
	half_extents:   Vec3,
	intensity:      f32,
	cube:           gfx.ImageId `ImageCube`,
	sampler:        gfx.SamplerId `Sampler`,
	mip_count:      u32,
	priority:       f32,
}

// Push for the RT capture compute (shaders/reflection_capture.slang). DDGI indirect at ray hits
// comes from the packed volume array in global (world-space select), not a single volume pointer.
@(shader_shared)
GPUReflectionCapturePush :: struct #max_field_align(16) {
	global:     GPUPtr(GPUGlobalData),
	geometries: GPUPtr(GPUGeometry),
	materials:  GPUPtr(GPUMaterial),
	tlas:       vk.DeviceAddress `AccelerationStructure`,
	out_cube:   ImageId `RWImage2DArray`, // D2_ARRAY storage view of the cube (mip 0, 6 layers)
	center:     Vec3,
	face_size:  u32, // resolution per cube face
	ray_max:    f32,
}

// Push for the debug mirror-ball gizmo (shaders/reflection_probe_debug.slang).
@(shader_shared)
GPUReflectionProbeDebugPush :: struct #max_field_align(16) {
	global:        GPUPtr(GPUGlobalData),
	probe:         GPUPtr(GPUReflectionProbe),
	vertex_buffer: GPUPtr(Vertex),
	center:        Vec3,
	radius:        f32,
}

// Push for the roughness prefilter (shaders/reflection_prefilter.slang). One dispatch per mip.
@(shader_shared)
GPUReflectionPrefilterPush :: struct #max_field_align(16) {
	src_cube:     ImageId `ImageCube`, // captured cube (read mip 0)
	sampler:      SamplerId `Sampler`,
	out_mip:      ImageId `RWImage2DArray`, // this mip's D2_ARRAY storage view
	face_size:    u32, // resolution of this mip
	roughness:    f32,
	sample_count: u32,
}

@(entity)
ReflectionProbe :: struct {
	using entity:         ^Entity,
	half_extents:         Vec3,
	blend_distance:       f32,
	intensity:            f32,
	priority:             f32,
	debug_radius:         f32,
	face_size:            u32,
	mip_count:            u32,

	// GPU resources
	cube_image:           gfx.GPUImage,
	cube_sampled_id:      gfx.ImageId, // CUBE view  (read in lighting / prefilter source)
	cube_mip_storage_ids: [MAX_REFLECTION_MIPS]gfx.ImageId,
	gpu_sampler_id:       gfx.SamplerId,
	config:               gfx.GPUBuffer(GPUReflectionProbe),
	captured:             bool,
	wants_recapture:      bool,
}

REFLECTION_PROBE_FACE_SIZE :: 128
MAX_REFLECTION_MIPS :: 12
MAX_REFLECTION_PROBES :: 64

reflection_probe_init :: proc(probe: ^ReflectionProbe, position: Vec3, half_extents: Vec3, arena: ^gfx.ResourceArena) {
	probe.translation = position
	probe.half_extents = half_extents
	probe.blend_distance = 1.0
	probe.intensity = 1.0
	probe.priority = 0.0
	probe.debug_radius = 0.5
	probe.face_size = REFLECTION_PROBE_FACE_SIZE
	probe.mip_count = u32(math.log2(f32(REFLECTION_PROBE_FACE_SIZE))) + 1

	fs := probe.face_size
	usage: vk.ImageUsageFlags = {.STORAGE, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST}
	probe.cube_image = gfx.create_image(
		.R16G16B16A16_SFLOAT,
		{fs, fs, 1},
		usage,
		mip_levels = probe.mip_count,
		array_layers = 6,
		flags = {.CUBE_COMPATIBLE},
	)
	gfx.defer_destroy(arena, probe.cube_image)

	if cmd, ok := gfx.immediate_submit(); ok {
		gfx.transition_image(cmd, &probe.cube_image, .GENERAL)

		black := vk.ClearColorValue {
			float32 = {0, 0, 0, 1},
		}
		range := vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			levelCount = probe.mip_count,
			layerCount = 6,
		}
		vk.CmdClearColorImage(cmd, probe.cube_image.image, .GENERAL, &black, 1, &range)
	}

	// Sampled CUBE view (the default view, since CUBE_COMPATIBLE), registered SAMPLED-only.
	sampled := probe.cube_image
	sampled.usage = {.SAMPLED}
	probe.cube_sampled_id = gfx.add_image(sampled)

	for mip in u32(0) ..< probe.mip_count {
		mip_view := gfx.create_image_view(
			probe.cube_image.image,
			probe.cube_image.format,
			.D2_ARRAY,
			base_mip_level = mip,
			mip_levels = 1,
			base_array_layer = 0,
			array_layers = 6,
		)
		storage := probe.cube_image
		storage.usage = {.STORAGE}
		probe.cube_mip_storage_ids[mip] = gfx.add_image(storage, mip_view)
	}

	sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, max_lod = f32(probe.mip_count - 1))
	gfx.defer_destroy(arena, sampler)

	probe.config = gfx.create_buffer(GPUReflectionProbe, 1, .DynUniform)
	gfx.defer_destroy(arena, probe.config)

	probe.gpu_sampler_id = gfx.add_sampler(sampler)
	reflection_probe_write_config(probe)
}

// Release a probe's bindless slots so a scene reload can recycle them. The underlying
// VkImages/sampler/buffer are destroyed by the owning ResourceArena flush; this only frees the
// descriptor indices (otherwise the monotonic slot counter marches past MAX_BINDLESS_IMAGES).
reflection_probe_destroy :: proc(probe: ^ReflectionProbe) {
	gfx.remove_image(probe.cube_sampled_id)
	for mip in u32(0) ..< probe.mip_count {
		gfx.remove_image(probe.cube_mip_storage_ids[mip])
	}
	gfx.remove_sampler(probe.gpu_sampler_id)
}

// Debug gizmo: draw a perfect mirror sphere at each probe's capture point, sampling its
// captured cube. Reuses the DDGI debug-sphere mesh. Renders into the HDR scene.
reflection_probe_debug_spheres_pass :: proc(cmd: vk.CommandBuffer) {
	rp := &game.render_state.ddgi_rp
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		depth_attachment = &{view = gfx.r_ctx.depth_image.image_view, layout = .DEPTH_ATTACHMENT_OPTIMAL},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)
	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_probe_debug_pipeline)
	gfx.cmd_bind_index_buffer(cmd, rp.probe_ibuf.buffer)

	for &probe in get_entities(ReflectionProbe) {
		// Always drawn (even before the first capture, where the cube reads black) so the
		// gizmo doesn't vanish while waiting on auto-capture / DDGI convergence.
		gfx.cmd_push_constants(
			cmd,
			GPUReflectionProbeDebugPush {
				global = current_frame_game().global_buffer.ptr,
				probe = probe.config.ptr,
				vertex_buffer = rp.probe_vbuf.ptr,
				center = probe.translation,
				radius = probe.debug_radius,
			},
		)
		gfx.cmd_draw_indexed(cmd, rp.probe_index_count, instance_count = 1)
	}
	gfx.cmd_end_rendering(cmd)
}

// Debug overlay: draw the probe's box volume (parallax/influence bounds) as a wireframe.
reflection_probe_debug_draw_box :: proc(probe: ^ReflectionProbe) {
	c := probe.translation
	h := probe.half_extents

	corners: [8]Vec3
	for i in 0 ..< 8 {
		sx := f32(int(i & 1) * 2 - 1)
		sy := f32(int((i >> 1) & 1) * 2 - 1)
		sz := f32(int((i >> 2) & 1) * 2 - 1)
		corners[i] = c + Vec3{sx * h.x, sy * h.y, sz * h.z}
	}

	// 12 edges = corner pairs differing in exactly one axis bit.
	edges := [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
	for e in edges {
		debug_draw_line(corners[e[0]], corners[e[1]], 1.5, DEBUG_COLOR_GOOD)
	}
}

reflection_probe_to_gpu :: proc(probe: ^ReflectionProbe) -> GPUReflectionProbe {
	return GPUReflectionProbe {
		center = probe.translation,
		blend_distance = probe.blend_distance,
		half_extents = probe.half_extents,
		intensity = probe.intensity,
		cube = probe.cube_sampled_id,
		sampler = probe.gpu_sampler_id,
		mip_count = probe.mip_count,
		priority = probe.priority,
	}
}

reflection_probe_write_config :: proc(probe: ^ReflectionProbe) {
	cfg := reflection_probe_to_gpu(probe)
	gfx.write_buffer(&probe.config, &cfg)
}

// Record an RT capture of all 6 cube faces (mip 0), then GGX-prefilter the roughness mips.
// Uses the per-frame scene TLAS, so call after build_scene_tlas + DDGI update.
reflection_probe_capture :: proc(cmd: vk.CommandBuffer, probe: ^ReflectionProbe) {
	reflection_probe_write_config(probe)

	// Pass 1: ray-trace mip 0 (the sharp, roughness-0 environment).
	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_capture_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUReflectionCapturePush {
			global = current_frame_game().global_buffer.ptr,
			geometries = current_frame_game().geometries_buffer.ptr,
			materials = game.render_state.scene_resources.materials_buffer.ptr,
			tlas = current_frame_game().tlas.address,
			out_cube = probe.cube_mip_storage_ids[0],
			center = probe.translation,
			face_size = probe.face_size,
			ray_max = 200.0,
		},
	)
	groups := (probe.face_size + 7) / 8
	vk.CmdDispatch(cmd, groups, groups, 6)

	// mip 0 write -> read, so the prefilter can sample it.
	reflection_cube_barrier(cmd, probe.cube_image.image)

	// Pass 2: GGX roughness prefilter for mips 1.. (each from mip 0).
	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_prefilter_pipeline)
	for mip in u32(1) ..< probe.mip_count {
		mip_size := max(probe.face_size >> mip, 1)
		roughness := f32(mip) / f32(probe.mip_count - 1)
		gfx.cmd_push_constants(
			cmd,
			GPUReflectionPrefilterPush {
				src_cube = probe.cube_sampled_id,
				sampler = probe.gpu_sampler_id,
				out_mip = probe.cube_mip_storage_ids[mip],
				face_size = mip_size,
				roughness = roughness,
				sample_count = 128,
			},
		)
		g := (mip_size + 7) / 8
		vk.CmdDispatch(cmd, g, g, 6)
	}

	// All mips written -> sampleable by the lighting pass.
	reflection_cube_barrier(cmd, probe.cube_image.image)
	probe.captured = true
}

// Memory barrier on the cube (kept in GENERAL): compute writes -> later shader reads.
@(private = "file")
reflection_cube_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask = {.COMPUTE_SHADER, .FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_READ},
		oldLayout = .GENERAL,
		newLayout = .GENERAL,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = 6},
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}
