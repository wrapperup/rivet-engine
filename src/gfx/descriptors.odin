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

DescriptorAllocator :: struct {
	sets_per_pool: u32,
	pool_ratios:   [dynamic]PoolSizeRatio,
	ready_pools:   [dynamic]vk.DescriptorPool,
	full_pools:    [dynamic]vk.DescriptorPool,
	flags:         vk.DescriptorPoolCreateFlags,
	debug_name:    cstring,
}

PoolSizeRatio :: struct {
	type:  vk.DescriptorType,
	ratio: f32,
}

init_descriptor_allocator :: proc(
	allocator: ^DescriptorAllocator,
	device: vk.Device,
	max_sets: u32,
	pool_ratios: []PoolSizeRatio,
	flags: vk.DescriptorPoolCreateFlags = {},
	debug_name: cstring = nil,
	loc := #caller_location,
) {
	clear(&allocator.pool_ratios)

	for &ratio in pool_ratios {
		append(&allocator.pool_ratios, ratio)
	}

	new_pool := create_pool(allocator, device, max_sets, pool_ratios, flags)
	allocator.flags = flags

	when ODIN_DEBUG {
		if debug_name == nil {
			allocator.debug_name = fmt.ctprint(loc)
		} else {
			allocator.debug_name = debug_name
		}
	}

	append(&allocator.ready_pools, new_pool)
}

get_pool :: proc(allocator: ^DescriptorAllocator, device: vk.Device) -> vk.DescriptorPool {
	if len(allocator.ready_pools) > 0 {
		return pop(&allocator.ready_pools)
	} else {
		return create_pool(allocator, device, allocator.sets_per_pool, allocator.pool_ratios[:], allocator.flags)
	}
}

create_pool :: proc(
	allocator: ^DescriptorAllocator,
	device: vk.Device,
	set_count: u32,
	pool_ratios: []PoolSizeRatio,
	flags: vk.DescriptorPoolCreateFlags = {},
) -> vk.DescriptorPool {
	pool_sizes: [dynamic]vk.DescriptorPoolSize
	defer delete(pool_sizes)

	reserve(&pool_sizes, len(pool_ratios))

	for ratio in pool_ratios {
		append(&pool_sizes, vk.DescriptorPoolSize{type = ratio.type, descriptorCount = u32(f32(ratio.ratio) * f32(set_count))})
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = flags,
		maxSets       = set_count,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	new_pool: vk.DescriptorPool
	vk_check(vk.CreateDescriptorPool(device, &pool_info, nil, &new_pool))

	when ODIN_DEBUG {
		debug_set_object_name(new_pool, allocator.debug_name)
	}

	return new_pool
}

reset_pools :: proc(allocator: ^DescriptorAllocator, device: vk.Device) {
	for &pool in &allocator.ready_pools {
		vk.ResetDescriptorPool(device, pool, {})
	}

	for &pool in &allocator.full_pools {
		vk.ResetDescriptorPool(device, pool, {})
		append(&allocator.ready_pools, pool)
	}
	clear(&allocator.full_pools)
}

destroy_pools :: proc(allocator: ^DescriptorAllocator, device: vk.Device) {
	for &pool in &allocator.ready_pools {
		vk.DestroyDescriptorPool(device, pool, nil)
	}
	clear(&allocator.ready_pools)

	for &pool in &allocator.full_pools {
		vk.DestroyDescriptorPool(device, pool, nil)
	}
	clear(&allocator.full_pools)
}

allocate_descriptor_set :: proc(
	allocator: ^DescriptorAllocator,
	device: vk.Device,
	layout: vk.DescriptorSetLayout,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> vk.DescriptorSet {
	pool := get_pool(allocator, device)
	layout := layout

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = nil,
		descriptorPool     = pool,
		descriptorSetCount = 1,
		pSetLayouts        = &layout,
	}

	descriptor_set: vk.DescriptorSet
	result := vk.AllocateDescriptorSets(device, &alloc_info, &descriptor_set)

	if result == .ERROR_OUT_OF_POOL_MEMORY || result == .ERROR_FRAGMENTED_POOL {
		append(&allocator.full_pools, pool)

		pool = get_pool(allocator, device)
		alloc_info.descriptorPool = pool

		// Try again, if it fails then we're goofed anyway.
		result = vk.AllocateDescriptorSets(device, &alloc_info, &descriptor_set)

		vk_check(result)
	}

	append(&allocator.ready_pools, pool)

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(descriptor_set, fmt.ctprint(loc))
		} else {
			debug_set_object_name(descriptor_set, debug_name)
		}
	}


	return descriptor_set
}

destroy_descriptor_allocator :: proc(allocator: ^DescriptorAllocator) {
	delete(allocator.pool_ratios)
	delete(allocator.ready_pools)
	delete(allocator.full_pools)
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
