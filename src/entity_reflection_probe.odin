package game

import "core:math"

import "gfx"
import vk "vendor:vulkan"

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
	cube_image:           gfx.Image,
	cube_sampled_id:      gfx.ImageId, // CUBE view  (read in lighting / prefilter source)
	cube_mip_storage_ids: [MAX_REFLECTION_MIPS]gfx.ImageId,
	gpu_sampler_id:       gfx.SamplerId,
	configs:              [gfx.FRAME_OVERLAP]gfx.Buffer(GPUReflectionProbe),
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

	for &config in probe.configs {
		config = gfx.create_buffer(GPUReflectionProbe, 1, .DynUniform)
		gfx.defer_destroy(arena, config)
	}

	probe.gpu_sampler_id = gfx.add_sampler(sampler)
	cfg := reflection_probe_to_gpu(probe)
	for &config in probe.configs {
		gfx.write_buffer(&config, &cfg)
	}
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
	gfx.write_buffer(&probe.configs[gfx.current_frame_index()], &cfg)
}
