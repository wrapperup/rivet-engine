package gfx

import vk "vendor:vulkan"

Swapchain :: struct {
	swapchain:              vk.SwapchainKHR,
	swapchain_images:       []ImageId,
	swapchain_image_index:  u32,
	swapchain_image_format: vk.Format,
	swapchain_extent:       vk.Extent2D,
    acquire_semaphores:     []vk.Semaphore,
    present_semaphores:     []vk.Semaphore,
    present_mode:           vk.PresentModeKHR,
    max_frames_in_flight:   int,
    frame_index:            int,
	arena:                  ResourceArena,
}

create_swapchain :: proc(surface: vk.SurfaceKHR, present_mode: vk.PresentModeKHR, window_size: [2]int, max_frames_in_flight: int) -> Swapchain {
    swapchain: Swapchain
    swapchain.present_mode = present_mode
    swapchain.max_frames_in_flight = max_frames_in_flight

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r_ctx.physical_device, surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, surface, &format_count, nil)

	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, surface, &format_count, raw_data(formats))

	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, surface, &present_mode_count, nil)

	present_modes := make([]vk.PresentModeKHR, present_mode_count)
	defer delete(present_modes)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, surface, &present_mode_count, raw_data(present_modes))

	surface_format := formats[0]

	for format in formats {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			surface_format = format
		}
	}

	extent := choose_swap_extent(window_size, &capabilities)

	image_count := capabilities.minImageCount + 1

	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
		surface               = surface,
		minImageCount         = image_count,
		imageFormat           = surface_format.format,
		imageColorSpace       = surface_format.colorSpace,
		imageExtent           = extent,
		imageArrayLayers      = 1,
		imageUsage            = {.COLOR_ATTACHMENT, .TRANSFER_DST, .SAMPLED},

		// TODO: Support multiple queues?
		imageSharingMode      = .EXCLUSIVE,
		queueFamilyIndexCount = 0, // Optional
		pQueueFamilyIndices   = nil, // Optional
		preTransform          = capabilities.currentTransform,
		compositeAlpha        = {.OPAQUE},
		presentMode           = present_mode,
		clipped               = true,
		// oldSwapchain       = old_swapchain, // TODO: Revisit swapchain resizing.
	}

    vk_swapchain: vk.SwapchainKHR
	vk_check(vk.CreateSwapchainKHR(r_ctx.device, &create_info, nil, &vk_swapchain))
	// defer_destroy(&swapchain.arena, swapchain.swapchain)

    swapchain.swapchain = vk_swapchain
	swapchain.swapchain_image_format = surface_format.format
	swapchain.swapchain_extent = extent

	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, nil)
	vk_swapchain_images := make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, raw_data(vk_swapchain_images))

	swapchain.swapchain_images = make([]ImageId, image_count)
	for i in 0 ..< len(swapchain.swapchain_images) {
		swapchain.swapchain_images[i] = wrap_image(
			vk_swapchain_images[i],
			swapchain.swapchain_image_format,
			{swapchain.swapchain_extent.width, swapchain.swapchain_extent.height, 0},
			{.COLOR_ATTACHMENT, .TRANSFER_DST, .SAMPLED},
		)
		defer_destroy(&swapchain.arena, swapchain.swapchain_images[i])
	}

    // create sync structures
    swapchain.acquire_semaphores = make([]vk.Semaphore, swapchain.max_frames_in_flight)
    swapchain.present_semaphores = make([]vk.Semaphore, swapchain.max_frames_in_flight)
    for i in 0 ..< swapchain.max_frames_in_flight {
        vk_check(vk.CreateSemaphore(r_ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &swapchain.acquire_semaphores[i]))
        vk_check(vk.CreateSemaphore(r_ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &swapchain.present_semaphores[i]))
    }

    return swapchain
}

swapchain_acquire :: proc(swapchain: ^Swapchain) {
	acquire_image_result := vk.AcquireNextImageKHR(
		r_ctx.device,
		swapchain.swapchain,
		1_000_000_000,
		swapchain.acquire_semaphores[swapchain.frame_index],
		0,
		&swapchain.swapchain_image_index,
	)
}

choose_swap_extent :: proc(desired: [2]int, capabilities: ^vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if (capabilities.currentExtent.width != max(u32)) {
		return capabilities.currentExtent
	} else {
		width, height := **desired

		actual_extent := vk.Extent2D{u32(width), u32(height)}

		actual_extent.width = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

		return actual_extent
	}
}
