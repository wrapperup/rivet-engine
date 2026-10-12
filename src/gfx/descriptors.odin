package gfx

import "core:fmt"
import vk "vendor:vulkan"

DescriptorBinding :: struct {
	binding: u32,
	type:    vk.DescriptorType,
	count:   u32,
}

create_descriptor_set_layout :: proc(
	bindings: []DescriptorBinding,
	descriptor_set_layout_flags: vk.DescriptorSetLayoutCreateFlags = {},
	stage_flags: vk.ShaderStageFlags = {.VERTEX, .FRAGMENT},
	debug_name: cstring = nil,
	loc := #caller_location,
) -> vk.DescriptorSetLayout {
	descriptor_set_bindings: [dynamic]vk.DescriptorSetLayoutBinding
	resize(&descriptor_set_bindings, len(bindings))

	for binding, i in bindings {
		descriptor_set_bindings[i] = vk.DescriptorSetLayoutBinding {
			stageFlags      = stage_flags,
			binding         = binding.binding,
			descriptorType  = binding.type,
			descriptorCount = binding.count > 0 ? binding.count : 1, // Default to 1. 0 doesn't make any sense.
		}
	}

	info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pBindings    = raw_data(descriptor_set_bindings[:]),
		bindingCount = u32(len(descriptor_set_bindings)),
		flags        = descriptor_set_layout_flags,
	}

	set: vk.DescriptorSetLayout
	vk_check(vk.CreateDescriptorSetLayout(r_ctx.device, &info, nil, &set))

	delete(descriptor_set_bindings)

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(set, fmt.ctprint(loc))
		} else {
			debug_set_object_name(set, debug_name)
		}
	}

	return set
}

create_pool :: proc(
	max_sets: u32,
	pool_sizes: []vk.DescriptorPoolSize,
	flags: vk.DescriptorPoolCreateFlags = {},
	debug_name: cstring = nil,
	loc := #caller_location,
) -> vk.DescriptorPool {
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = flags,
		maxSets       = max_sets,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	new_pool: vk.DescriptorPool
	vk_check(vk.CreateDescriptorPool(r_ctx.device, &pool_info, nil, &new_pool))

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(new_pool, fmt.ctprint(loc))
		} else {
			debug_set_object_name(new_pool, debug_name)
		}
	}

	return new_pool
}

allocate_descriptor_set :: proc(
	pool: vk.DescriptorPool,
	layout: vk.DescriptorSetLayout,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> vk.DescriptorSet {
	layout := layout

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = nil,
		descriptorPool     = pool,
		descriptorSetCount = 1,
		pSetLayouts        = &layout,
	}

	descriptor_set: vk.DescriptorSet
	vk_check(vk.AllocateDescriptorSets(r_ctx.device, &alloc_info, &descriptor_set))

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(descriptor_set, fmt.ctprint(loc))
		} else {
			debug_set_object_name(descriptor_set, debug_name)
		}
	}


	return descriptor_set
}

DescriptorWrite :: struct {
	binding:      u32,
	type:         vk.DescriptorType,
	image_view:   vk.ImageView,
	sampler:      vk.Sampler,
	image_layout: vk.ImageLayout,
	buffer:       vk.Buffer,
	array_index:  u32,
}

is_image_descriptor_type :: proc(ty: vk.DescriptorType) -> bool {
	return ty == .STORAGE_IMAGE || ty == .SAMPLED_IMAGE || ty == .SAMPLER
}

is_sampler_descriptor_type :: proc(ty: vk.DescriptorType) -> bool {
	return ty == .SAMPLER
}

// TODO: This should not allocate.
write_descriptor_set :: proc(descriptor_set: vk.DescriptorSet, writes: []DescriptorWrite, loc := #caller_location) {
	// Collect writes in the convenient format into vk's.
	descriptor_writes: [dynamic]vk.WriteDescriptorSet
	image_infos: [dynamic]vk.DescriptorImageInfo
	buffer_infos: [dynamic]vk.DescriptorBufferInfo

	for write in writes {
		if is_image_descriptor_type(write.type) {
			assert(write.buffer == 0, "Descriptor write is an image type, but the buffer field was set.", loc = loc)

			if write.type == .SAMPLER {
				assert(write.sampler != 0, fmt.tprint("Descriptor write has a null sampler! array_index:", write.array_index), loc = loc)
			} else {
				assert(write.image_layout != .UNDEFINED, "Descriptor write has a null image layout!", loc = loc)
				assert(write.image_view != 0, "Descriptor write has a null image view!", loc = loc)
			}

			image_info := vk.DescriptorImageInfo {
				imageLayout = write.image_layout,
				imageView   = write.image_view,
				sampler     = write.sampler,
			}

			append(&image_infos, image_info)

			descriptor_write := vk.WriteDescriptorSet {
				sType           = .WRITE_DESCRIPTOR_SET,
				pNext           = nil,
				dstBinding      = write.binding,
				dstSet          = descriptor_set,
				dstArrayElement = write.array_index,
				descriptorCount = 1,
				descriptorType  = write.type,
				pImageInfo      = &image_infos[len(image_infos) - 1],
			}

			append(&descriptor_writes, descriptor_write)
		} else {
			assert(write.image_layout == .UNDEFINED, "Descriptor write is a buffer type, but the image_layout field was set.")
			assert(write.image_view == 0, "Descriptor write is a buffer type, but the image_view field was set.")
			assert(write.sampler == 0, "Descriptor write is a buffer type, but the sampler field was set.")

			buffer_info := vk.DescriptorBufferInfo {
				buffer = write.buffer,
			}

			append(&buffer_infos, buffer_info)

			descriptor_write := vk.WriteDescriptorSet {
				sType           = .WRITE_DESCRIPTOR_SET,
				pNext           = nil,
				dstBinding      = write.binding,
				dstSet          = descriptor_set,
				dstArrayElement = write.array_index,
				descriptorCount = 1,
				descriptorType  = write.type,
				pBufferInfo     = &buffer_infos[len(buffer_infos) - 1],
			}

			append(&descriptor_writes, descriptor_write)
		}
	}

	// Finally write out all of the writes
	vk.UpdateDescriptorSets(r_ctx.device, u32(len(descriptor_writes)), raw_data(descriptor_writes), 0, nil)

	delete(descriptor_writes)
	delete(image_infos)
	delete(buffer_infos)
}
