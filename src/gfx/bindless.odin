package gfx

import "core:fmt"
import vk "vendor:vulkan"

MAX_BINDLESS_IMAGES :: 1024
MAX_BINDLESS_SAMPLERS :: 128

BINDLESS_SAMPLED_IMAGES: u32 : 0
BINDLESS_SAMPLERS: u32 : 1
BINDLESS_STORAGE_IMAGES: u32 : 2

ImageId :: distinct u32
SamplerId :: distinct u32

BindlessSystem :: struct {
	descriptor_layout: vk.DescriptorSetLayout,
	descriptor_set:    vk.DescriptorSet,

	// Storage
	images:            [dynamic]Image,
	samplers:          [dynamic]vk.Sampler,

	free_images:       [dynamic]ImageId,
	free_samplers:     [dynamic]SamplerId,
}

init_bindless_descriptors :: proc() {
	bindless_system := &r_ctx.bindless_system

	bindless_system.descriptor_layout = create_descriptor_set_layout(
		{
			{binding = BINDLESS_SAMPLED_IMAGES, type = .SAMPLED_IMAGE, count = MAX_BINDLESS_IMAGES},
			{binding = BINDLESS_SAMPLERS, type = .SAMPLER, count = MAX_BINDLESS_SAMPLERS},
			{binding = BINDLESS_STORAGE_IMAGES, type = .STORAGE_IMAGE, count = MAX_BINDLESS_IMAGES},
		},
		{.UPDATE_AFTER_BIND_POOL},
		{.VERTEX, .FRAGMENT, .COMPUTE},
	)
	defer_destroy(&r_ctx.global_arena, bindless_system.descriptor_layout)

	bindless_system.descriptor_set = allocate_descriptor_set(
		&r_ctx.global_descriptor_allocator,
		r_ctx.device,
		bindless_system.descriptor_layout,
	)
}

shutdown_bindless_descriptors :: proc() {
	delete(r_ctx.bindless_system.images)
	delete(r_ctx.bindless_system.samplers)
	delete(r_ctx.bindless_system.free_images)
	delete(r_ctx.bindless_system.free_samplers)
	r_ctx.bindless_system = {}
}

image_meta :: proc(id: ImageId) -> ^Image {
	bindless_system := &r_ctx.bindless_system
    return &bindless_system.images[id]
}

sampler_meta :: proc(id: SamplerId) -> vk.Sampler {
	bindless_system := &r_ctx.bindless_system
    return bindless_system.samplers[id]
}

add_image_impl :: proc(image: Image) -> ImageId {
	bindless_system := &r_ctx.bindless_system

	// assert(.STORAGE in image.usage || .SAMPLED in image.usage)

	image_id: ImageId
	if len(bindless_system.free_images) > 0 {
		image_id = pop(&bindless_system.free_images) // recycle a freed slot
		bindless_system.images[image_id] = image
	} else {
		image_id = ImageId(u32(len(bindless_system.images)))
		append(&bindless_system.images, image)
	}
	assert(u32(image_id) < MAX_BINDLESS_IMAGES, "bindless image slots exhausted")

	if .STORAGE in image.usage {
        write_descriptor_set(
            bindless_system.descriptor_set,
            {
                {
                    binding = BINDLESS_STORAGE_IMAGES,
                    type = .STORAGE_IMAGE,
                    image_view = image.image_view,
                    image_layout = .GENERAL,
                    array_index = u32(image_id),
                },
            },
        )
    }

	if .SAMPLED in image.usage {
        write_descriptor_set(
            bindless_system.descriptor_set,
            {
                {
                    binding = BINDLESS_SAMPLED_IMAGES,
                    type = .SAMPLED_IMAGE,
                    image_view = image.image_view,
                    image_layout = .GENERAL,
                    array_index = u32(image_id),
                },
            },
        )
    }

	return image_id
}

add_image_with_view_impl :: proc(image: Image, view: vk.ImageView) -> ImageId {
    image := image
    image.image_view = view
    image.owns_image = false
    return add_image_impl(image)
}

add_sampler :: proc(sampler: vk.Sampler) -> SamplerId {
	bindless_system := &r_ctx.bindless_system

	sampler_id: SamplerId
	if len(bindless_system.free_samplers) > 0 {
		sampler_id = pop(&bindless_system.free_samplers) // recycle a freed slot
		bindless_system.samplers[sampler_id] = sampler
	} else {
		sampler_id = SamplerId(u32(len(bindless_system.samplers)))
		append(&bindless_system.samplers, sampler)
	}
	assert(u32(sampler_id) < MAX_BINDLESS_SAMPLERS, "bindless sampler slots exhausted")

	write_descriptor_set(
		bindless_system.descriptor_set,
		{{binding = BINDLESS_SAMPLERS, type = .SAMPLER, sampler = sampler, array_index = u32(sampler_id)}},
	)

	return sampler_id
}

_remove_image :: proc(id: ImageId) {
	append(&r_ctx.bindless_system.free_images, id)
}

_remove_sampler :: proc(id: SamplerId) {
	append(&r_ctx.bindless_system.free_samplers, id)
}
