package gfx

import "core:fmt"

import vk "vendor:vulkan"

import ktx "deps:odin-libktx"
import vma "deps:odin-vma"

Image :: struct {
	image:          vk.Image,
	image_view:     vk.ImageView,
	allocation:     vma.Allocation,
	extent:         vk.Extent3D,
	format:         vk.Format,
	mip_levels:     u32,
	array_layers:   u32,
	current_layout: vk.ImageLayout,
	usage:          vk.ImageUsageFlags,
	view_type:      vk.ImageViewType,
	owns_image:     bool,
}

ImageAccess :: enum {
	None,
	AllWrites,
	AllReadsWrites,
	ComputeShaderRead,
	ComputeShaderWrite,
	ComputeShaderReadWrite,
	AllShaderRead,
	ComputeFragmentShaderRead,
	FragmentShaderRead,
	ColorAttachmentReadWrite,
	DepthAttachmentReadWrite,
	TransferRead,
	TransferWrite,
}

// A count of zero covers all remaining mip levels or array layers.
ImageSubresourceRange :: struct {
	base_mip_level:   u32,
	mip_count:        u32,
	base_array_layer: u32,
	layer_count:      u32,
}

// This allocates on the GPU, make sure to call `destroy_image` or add to the deletion queue when you are finished with the image.
create_image :: proc(
	format: vk.Format,
	extent: vk.Extent3D,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	image_type: vk.ImageType = .D2,
	msaa_samples: vk.SampleCountFlag = ._1,
	tiling: vk.ImageTiling = .OPTIMAL,
	flags: vk.ImageCreateFlags = {},
	alloc_flags: vma.AllocationCreateFlags = {},
	usage: vma.MemoryUsage = .GPU_ONLY,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> ImageId {
	img_alloc_info := vma.AllocationCreateInfo {
		usage         = usage,
		requiredFlags = {.DEVICE_LOCAL},
		flags         = alloc_flags,
	}

	img_info := init_image_create_info(
		format,
		image_usage_flags,
		extent,
		mip_levels,
		array_layers,
		msaa_samples,
		image_type,
		flags,
		tiling,
	)

	view_type: vk.ImageViewType = .D1
	if .CUBE_COMPATIBLE in flags {
		view_type = .CUBE
	} else {
		view_type += cast(vk.ImageViewType)image_type // Adding dimension

		if array_layers > 1 {
			view_type += cast(vk.ImageViewType)4
		}
	}

	image := Image {
		extent       = extent,
		format       = format,
		mip_levels   = mip_levels,
		array_layers = array_layers,
		usage        = image_usage_flags,
		view_type    = view_type,
		owns_image   = true,
	}

	vk_check(vma.CreateImage(r_ctx.allocator, &img_info, &img_alloc_info, &image.image, &image.allocation, nil))

	image.image_view = _create_image_view_impl(
		image.image,
		image.format,
		view_type,
		base_mip_level = 0,
		mip_levels = image.mip_levels,
		base_array_layer = 0,
		array_layers = image.array_layers,
	)

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(image.image, fmt.ctprint(loc))
			debug_set_object_name(image.image_view, fmt.ctprint(loc))
		} else {
			debug_set_object_name(image.image, debug_name)
			debug_set_object_name(image.image_view, debug_name)
		}
	}

	return add_image_impl(image)
}

wrap_image :: proc(
	vk_image: vk.Image,
	format: vk.Format,
	extent: vk.Extent3D,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	image_type: vk.ImageType = .D2,
	msaa_samples: vk.SampleCountFlag = ._1,
	tiling: vk.ImageTiling = .OPTIMAL,
	flags: vk.ImageCreateFlags = {},
	alloc_flags: vma.AllocationCreateFlags = {},
	usage: vma.MemoryUsage = .GPU_ONLY,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> ImageId {
	view_type: vk.ImageViewType = .D1
	if .CUBE_COMPATIBLE in flags {
		view_type = .CUBE
	} else {
		view_type += cast(vk.ImageViewType)image_type // Adding dimension

		if array_layers > 1 {
			view_type += cast(vk.ImageViewType)4
		}
	}

	image := Image {
		image        = vk_image,
		extent       = extent,
		format       = format,
		mip_levels   = mip_levels,
		array_layers = array_layers,
		usage        = image_usage_flags,
		view_type    = view_type,
	}

	image.image_view = _create_image_view_impl(
		image.image,
		image.format,
		view_type,
		base_mip_level = 0,
		mip_levels = image.mip_levels,
		base_array_layer = 0,
		array_layers = image.array_layers,
	)

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(image.image, fmt.ctprint(loc))
			debug_set_object_name(image.image_view, fmt.ctprint(loc))
		} else {
			debug_set_object_name(image.image, debug_name)
			debug_set_object_name(image.image_view, debug_name)
		}
	}

	return add_image_impl(image)
}

create_image_view :: proc(
	id: ImageId,
	format: vk.Format,
	view_type: vk.ImageViewType = .D2,
	#any_int base_mip_level: u32 = 0,
	#any_int mip_levels: u32 = 1,
	#any_int base_array_layer: u32 = 0,
	#any_int array_layers: u32 = 1,
) -> ImageId {
	image := image_meta(id)

	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = view_type,
		image = image.image,
		format = format,
		subresourceRange = {
			baseMipLevel = base_mip_level,
			levelCount = mip_levels,
			baseArrayLayer = base_array_layer,
			layerCount = array_layers,
			aspectMask = vk_aspect_of_format(format),
		},
	}

	image_view: vk.ImageView
	vk_check(vk.CreateImageView(r_ctx.device, &info, nil, &image_view))

	return add_image_with_view_impl(image^, image_view)
}

_create_image_view_impl :: proc(
	image: vk.Image,
	format: vk.Format,
	view_type: vk.ImageViewType = .D2,
	#any_int base_mip_level: u32 = 0,
	#any_int mip_levels: u32 = 1,
	#any_int base_array_layer: u32 = 0,
	#any_int array_layers: u32 = 1,
) -> vk.ImageView {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = view_type,
		image = image,
		format = format,
		subresourceRange = {
			baseMipLevel = base_mip_level,
			levelCount = mip_levels,
			baseArrayLayer = base_array_layer,
			layerCount = array_layers,
			aspectMask = vk_aspect_of_format(format),
		},
	}

	image_view: vk.ImageView
	vk_check(vk.CreateImageView(r_ctx.device, &info, nil, &image_view))

	return image_view
}

is_depth_format :: proc(format: vk.Format) -> bool {
	#partial switch format {
	case .D16_UNORM:
		return true
	case .D32_SFLOAT:
		return true
	case .D16_UNORM_S8_UINT:
		return true
	case .D32_SFLOAT_S8_UINT:
		return true
	case .X8_D24_UNORM_PACK32:
		return true
	}

	return false
}

is_stencil_format :: proc(format: vk.Format) -> bool {
	#partial switch format {
	case .S8_UINT:
		return true
	case .D16_UNORM_S8_UINT:
		return true
	case .D24_UNORM_S8_UINT:
		return true
	case .D32_SFLOAT_S8_UINT:
		return true
	}

	return false
}

vk_aspect_of_format :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	if is_depth_format(format) || is_stencil_format(format) {
		flags := vk.ImageAspectFlags{}

		if is_depth_format(format) {
			flags |= {.DEPTH}
		}
		if is_stencil_format(format) {
			flags |= {.STENCIL}
		}

		return flags
	}

	return {.COLOR}
}

create_sampler :: proc(
	filter: vk.Filter,
	address_mode: vk.SamplerAddressMode,
	compare_op: vk.CompareOp = .NEVER,
	border_color: vk.BorderColor = .FLOAT_TRANSPARENT_BLACK,
	max_lod: f32 = 1.0,
	max_anisotropy: f32 = 1.0,
    debug_name: cstring = nil,
    loc := #caller_location
) -> SamplerId {
	sampler_create_info := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		magFilter        = filter,
		minFilter        = filter,
		mipmapMode       = .LINEAR,
		addressModeU     = address_mode,
		addressModeV     = address_mode,
		addressModeW     = address_mode,
		mipLodBias       = 0.0,
		anisotropyEnable = max_anisotropy > 1.0 ? true : false,
		maxAnisotropy    = max_anisotropy,
		minLod           = 0.0,
		maxLod           = max_lod,
		borderColor      = border_color,
		compareOp        = compare_op,
		compareEnable    = compare_op != .NEVER,
	}

	sampler: vk.Sampler
	vk_check(vk.CreateSampler(r_ctx.device, &sampler_create_info, nil, &sampler))

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(sampler, fmt.ctprint(loc))
		} else {
			debug_set_object_name(sampler, debug_name)
		}
	}

	return add_sampler(sampler)
}

destroy_sampler :: proc(id: SamplerId) {
	sampler := sampler_meta(id)
	vk.DestroySampler(r_ctx.device, sampler, nil)
	_remove_sampler(id)
}

image_access_masks :: proc(access: ImageAccess) -> (vk.PipelineStageFlags2, vk.AccessFlags2) {
	switch access {
	case .None:
		return {}, {}
	case .AllWrites:
		return {.ALL_COMMANDS}, {.MEMORY_WRITE}
	case .AllReadsWrites:
		return {.ALL_COMMANDS}, {.MEMORY_READ, .MEMORY_WRITE}
	case .ComputeShaderRead:
		return {.COMPUTE_SHADER}, {.SHADER_READ}
	case .ComputeShaderWrite:
		return {.COMPUTE_SHADER}, {.SHADER_WRITE}
	case .ComputeShaderReadWrite:
		return {.COMPUTE_SHADER}, {.SHADER_READ, .SHADER_WRITE}
	case .AllShaderRead:
		return {.ALL_COMMANDS}, {.SHADER_READ}
	case .ComputeFragmentShaderRead:
		return {.COMPUTE_SHADER, .FRAGMENT_SHADER}, {.SHADER_READ}
	case .FragmentShaderRead:
		return {.FRAGMENT_SHADER}, {.SHADER_READ}
	case .ColorAttachmentReadWrite:
		return {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
	case .DepthAttachmentReadWrite:
		return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
	case .TransferRead:
		return {.ALL_TRANSFER}, {.TRANSFER_READ}
	case .TransferWrite:
		return {.ALL_TRANSFER}, {.TRANSFER_WRITE}
	}

	unreachable()
}

image_barrier :: proc(
	cmd: CommandBuffer,
	image_id: ImageId,
	src_access: ImageAccess,
	dst_access: ImageAccess,
	new_layout: vk.ImageLayout = .UNDEFINED,
	range: ImageSubresourceRange = {},
) -> bool {
	src_stage_mask, src_access_mask := image_access_masks(src_access)
	dst_stage_mask, dst_access_mask := image_access_masks(dst_access)

	image := image_meta(image_id)

	target_layout := image.current_layout
	if new_layout != .UNDEFINED {
		target_layout = new_layout
	}

	mip_count := range.mip_count
	if mip_count == 0 {
		mip_count = vk.REMAINING_MIP_LEVELS
	}

	layer_count := range.layer_count
	if layer_count == 0 {
		layer_count = vk.REMAINING_ARRAY_LAYERS
	}

	if new_layout != .UNDEFINED {
		assert(
			range.base_mip_level == 0 &&
			(range.mip_count == 0 || range.mip_count == image.mip_levels) &&
			range.base_array_layer == 0 &&
			(range.layer_count == 0 || range.layer_count == image.array_layers),
			"Image only tracks whole-image layouts",
		)
	}

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		pNext = nil,
		srcStageMask = src_stage_mask,
		srcAccessMask = src_access_mask,
		dstStageMask = dst_stage_mask,
		dstAccessMask = dst_access_mask,
		oldLayout = image.current_layout,
		newLayout = target_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image.image,
		subresourceRange = {
			aspectMask = vk_aspect_of_format(image.format),
			baseMipLevel = range.base_mip_level,
			levelCount = mip_count,
			baseArrayLayer = range.base_array_layer,
			layerCount = layer_count,
		},
	}

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		pNext                   = nil,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)

	if new_layout != .UNDEFINED {
		image.current_layout = target_layout
	}

	return true
}

transition_image :: proc(cmd: CommandBuffer, image: ImageId, new_layout: vk.ImageLayout) -> bool {
	return image_barrier(cmd, image, src_access = .AllWrites, dst_access = .AllReadsWrites, new_layout = new_layout)
}

copy_image_to_image :: proc(cmd: CommandBuffer, src_id: ImageId, dst_id: ImageId, src_size: vk.Extent2D, dst_size: vk.Extent2D) {
	source := image_meta(src_id)
	destination := image_meta(dst_id)

	blit_region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		pNext = nil,
	}

	blit_region.srcOffsets[1].x = i32(src_size.width)
	blit_region.srcOffsets[1].y = i32(src_size.height)
	blit_region.srcOffsets[1].z = 1

	blit_region.dstOffsets[1].x = i32(dst_size.width)
	blit_region.dstOffsets[1].y = i32(dst_size.height)
	blit_region.dstOffsets[1].z = 1

	blit_region.srcSubresource.aspectMask = {.COLOR}
	blit_region.srcSubresource.baseArrayLayer = 0
	blit_region.srcSubresource.layerCount = 1
	blit_region.srcSubresource.mipLevel = 0

	blit_region.dstSubresource.aspectMask = {.COLOR}
	blit_region.dstSubresource.baseArrayLayer = 0
	blit_region.dstSubresource.layerCount = 1
	blit_region.dstSubresource.mipLevel = 0

	blit_info := vk.BlitImageInfo2 {
		sType          = .BLIT_IMAGE_INFO_2,
		pNext          = nil,
		dstImage       = destination.image,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		srcImage       = source.image,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		filter         = .LINEAR,
		regionCount    = 1,
		pRegions       = &blit_region,
	}

	vk.CmdBlitImage2(cmd, &blit_info)
}

destroy_image :: proc(id: ImageId) {
	image := image_meta(id)

	vk.DestroyImageView(r_ctx.device, image.image_view, nil)

	if image.owns_image {
		vma.DestroyImage(r_ctx.allocator, image.image, image.allocation)
	}

	_remove_image(id)
}

// Uploads the data via a staging buffer. This is useful if your buffer is GPU only.
staging_write_image :: proc(gpu_image: ^Image, in_data: ^$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	assert(gpu_image.image_view != 0, "Image is missing a valid image view.")

	size := size_of(T)
	gpu_size := gpu_image.extent.width * gpu_image.extent.height * gpu_image.extent.depth * size_of(T) // TODO: Validate this.
	assert(gpu_size >= (u32(size) + u32(offset)), "The size of the data and offset is larger than the buffer", loc)

	staging := create_buffer(u8, vk.DeviceSize(size_of(T)), {.TRANSFER_SRC}, .CPU_ONLY)
	write_buffer(&staging, in_data)

	if cmd, ok := immediate_submit(); ok {
		transition_image(cmd, gpu_image.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

		copy_region := vk.BufferImageCopy {
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
			imageExtent = extent,
		}

		vk.CmdCopyBufferToImage(cmd, staging.buffer, gpu_image.image, .TRANSFER_DST_OPTIMAL, 1, &copy_region)

		transition_image(cmd, gpu_image.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
	}

	destroy_buffer(&staging)
}

// Uploads the data via a staging buffer. This is useful if your buffer is GPU only.
staging_write_image_slice :: proc(gpu_image: ^Image, in_data: []$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	assert(gpu_image.image_view != 0, "Image is missing a valid image view.")

	size := size_of(T) * len(in_data)
	gpu_size := gpu_image.extent.width * gpu_image.extent.height * gpu_image.extent.depth * size_of(T) // TODO: Validate this.
	assert(gpu_size >= (u32(size) + u32(offset)), "The size of the data and offset is larger than the buffer", loc)

	staging := create_buffer(u8, size, {.TRANSFER_SRC}, .CPU_ONLY)
	write_buffer_slice(&staging, in_data)

	if cmd, ok := immediate_submit(); ok {
		transition_image(cmd, gpu_image.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

		copy_region := vk.BufferImageCopy {
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
			imageExtent = gpu_image.extent,
		}

		vk.CmdCopyBufferToImage(cmd, staging.buffer, gpu_image.image, .TRANSFER_DST_OPTIMAL, 1, &copy_region)

		transition_image(cmd, gpu_image.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
	}

	destroy_buffer(&staging)
}
