package gfx

import vk "vendor:vulkan"

init_command_pool_create_info :: proc(queue_family_index: u32, flags: vk.CommandPoolCreateFlags) -> vk.CommandPoolCreateInfo {
	info := vk.CommandPoolCreateInfo{}
	info.sType = .COMMAND_POOL_CREATE_INFO
	info.pNext = nil
	info.queueFamilyIndex = queue_family_index
	info.flags = flags

	return info
}

init_command_buffer_allocate_info :: proc(pool: vk.CommandPool, count: u32) -> vk.CommandBufferAllocateInfo {
	info := vk.CommandBufferAllocateInfo{}
	info.sType = .COMMAND_BUFFER_ALLOCATE_INFO
	info.pNext = nil

	info.commandPool = pool
	info.commandBufferCount = count
	info.level = .PRIMARY
	return info
}

init_fence_create_info :: proc(flags: vk.FenceCreateFlags) -> vk.FenceCreateInfo {
	info := vk.FenceCreateInfo{}
	info.sType = .FENCE_CREATE_INFO
	info.pNext = nil

	info.flags = flags

	return info
}

init_semaphore_create_info :: proc(flags: vk.SemaphoreCreateFlags) -> vk.SemaphoreCreateInfo {
	info := vk.SemaphoreCreateInfo{}
	info.sType = .SEMAPHORE_CREATE_INFO
	info.pNext = nil
	info.flags = flags
	return info
}

init_command_buffer_begin_info :: proc(flags: vk.CommandBufferUsageFlags) -> vk.CommandBufferBeginInfo {
	info := vk.CommandBufferBeginInfo{}
	info.sType = .COMMAND_BUFFER_BEGIN_INFO
	info.pNext = nil

	info.pInheritanceInfo = nil
	info.flags = flags

	return info
}

init_image_subresource_range :: proc(aspect_mask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
	sub_image := vk.ImageSubresourceRange {
		aspectMask     = aspect_mask,
		baseMipLevel   = 0,
		levelCount     = vk.REMAINING_MIP_LEVELS,
		baseArrayLayer = 0,
		layerCount     = vk.REMAINING_ARRAY_LAYERS,
	}

	return sub_image
}

init_semaphore_submit_info :: proc(stage_mask: vk.PipelineStageFlags2, semaphore: vk.Semaphore) -> vk.SemaphoreSubmitInfo {
	info := vk.SemaphoreSubmitInfo {
		sType       = .SEMAPHORE_SUBMIT_INFO,
		pNext       = nil,
		semaphore   = semaphore,
		stageMask   = stage_mask,
		deviceIndex = 0,
		value       = 1,
	}

	return info
}

init_command_buffer_submit_info :: proc(cmd: vk.CommandBuffer) -> vk.CommandBufferSubmitInfo {
	info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		pNext         = nil,
		commandBuffer = cmd,
		deviceMask    = 0,
	}

	return info
}

init_submit_info :: proc(
	cmd: ^vk.CommandBufferSubmitInfo,
	signal_semaphore_info: ^vk.SemaphoreSubmitInfo,
	wait_semaphore_info: ^vk.SemaphoreSubmitInfo,
) -> vk.SubmitInfo2 {
	info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		pNext                    = nil,
		waitSemaphoreInfoCount   = wait_semaphore_info == nil ? 0 : 1,
		pWaitSemaphoreInfos      = wait_semaphore_info,
		signalSemaphoreInfoCount = signal_semaphore_info == nil ? 0 : 1,
		pSignalSemaphoreInfos    = signal_semaphore_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = cmd,
	}

	return info
}

init_image_create_info :: proc(
	format: vk.Format,
	usage_flags: vk.ImageUsageFlags,
	extent: vk.Extent3D,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	msaa_samples: vk.SampleCountFlag = ._1,
	image_type: vk.ImageType = .D2,
	flags: vk.ImageCreateFlags = {},
	tiling: vk.ImageTiling = .OPTIMAL,
) -> vk.ImageCreateInfo {
	info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		imageType   = image_type,
		format      = format,
		extent      = extent,
		mipLevels   = mip_levels,
		arrayLayers = array_layers,
		samples     = {msaa_samples},
		tiling      = tiling,
		usage       = usage_flags,
		flags       = flags,
	}

	return info
}

init_imageview_create_info :: proc(
	format: vk.Format,
	image: vk.Image,
	aspect_flags: vk.ImageAspectFlags,
	view_type: vk.ImageViewType = .D2,
	base_mip_level: u32 = 0,
	mip_count: u32 = 1,
	base_array_layer: u32 = 0,
	layer_count: u32 = 1,
) -> vk.ImageViewCreateInfo {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = view_type,
		image = image,
		format = format,
		subresourceRange = {
			baseMipLevel = base_mip_level,
			levelCount = mip_count,
			baseArrayLayer = base_array_layer,
			layerCount = layer_count,
			aspectMask = aspect_flags,
		},
	}

	return info
}

init_sampler_create_info :: proc(
	filter: vk.Filter,
	address_mode: vk.SamplerAddressMode,
	compare_op: vk.CompareOp = .NEVER,
	border_color: vk.BorderColor = .FLOAT_TRANSPARENT_BLACK,
	max_lod: f32 = 1.0,
) -> vk.SamplerCreateInfo {
	sampler_create_info := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = filter,
		minFilter     = filter,
		mipmapMode    = .LINEAR,
		addressModeU  = address_mode,
		addressModeV  = address_mode,
		addressModeW  = address_mode,
		mipLodBias    = 0.0,
		maxAnisotropy = 1.0,
		minLod        = 0.0,
		maxLod        = max_lod,
		borderColor   = border_color,
		compareOp     = compare_op,
		compareEnable = compare_op != .NEVER,
	}

	return sampler_create_info
}

init_attachment_info :: proc(
	view: vk.ImageView,
	clear: ^vk.ClearValue,
	layout: vk.ImageLayout,
	resolve_image_view: vk.ImageView = 0,
	resolve_image_layout: vk.ImageLayout = .UNDEFINED,
) -> vk.RenderingAttachmentInfo {
	attachment := vk.RenderingAttachmentInfo {
		sType              = .RENDERING_ATTACHMENT_INFO,
		imageView          = view,
		imageLayout        = layout,
		loadOp             = clear != nil ? .CLEAR : .LOAD,
		storeOp            = .STORE,
		clearValue         = clear != nil ? clear^ : {},
		resolveMode        = resolve_image_view == 0 ? {} : {.AVERAGE},
		resolveImageView   = resolve_image_view,
		resolveImageLayout = resolve_image_layout,
	}

	return attachment
}

init_rendering_info :: proc(
	area: vk.Extent2D,
	color_attachment: ^vk.RenderingAttachmentInfo,
	depth_attachment: ^vk.RenderingAttachmentInfo,
) -> vk.RenderingInfo {
	info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		layerCount = 1,
		renderArea = {extent = area},
		pDepthAttachment = depth_attachment,
		pColorAttachments = color_attachment,
		colorAttachmentCount = color_attachment != nil ? 1 : 0,
	}

	return info
}

init_pipeline_layout_create_info :: proc() -> vk.PipelineLayoutCreateInfo {
	info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pNext                  = nil,
		flags                  = {},
		setLayoutCount         = 0,
		pSetLayouts            = nil,
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	return info
}
