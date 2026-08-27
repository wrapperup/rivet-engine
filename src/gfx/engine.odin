package gfx

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:time"

import vma "deps:odin-vma"
import "vendor:glfw"
import vk "vendor:vulkan"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"

log_normal :: proc(args: ..any) {
	if r_ctx.enable_logs {
		fmt.println(..args)
	}
}

log_error :: proc(args: ..any) {
	if r_ctx.enable_logs {
		fmt.eprintln(..args)
	}
}

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		when ODIN_DEBUG {
			p("vk_check failed", reflect.enum_string(result), loc)
		} else {
			p("vk_check failed", "NOT SUCCESS", loc)
		}
	}
}

r_ctx: ^Renderer

DeviceLimits :: struct {
	max_anisotropy: f32,
}

Renderer :: struct {
	debug_messenger:             vk.DebugUtilsMessengerEXT,
	enable_logs:                 bool,
	instance:                    vk.Instance,
	physical_device:             vk.PhysicalDevice,
	device:                      vk.Device,
	window:                      glfw.WindowHandle,

	// Queues
	graphics_queue:              vk.Queue,
	graphics_queue_family:       u32,
	surface:                     vk.SurfaceKHR,

	// Swapchain
	swapchain:                   Swapchain,
	swapchain_suboptimal:        bool,

	// Command Pool/Buffer
	frames:                      [FRAME_OVERLAP]FrameData,
	frame_number:                int,
	global_arena:                ResourceArena,
	allocator:                   vma.Allocator,

	// Draw resources
	draw_image:                  Image,
	resolve_image:               Image,
	depth_image:                 Image,
	draw_extent:                 vk.Extent2D,
	msaa_samples:                vk.SampleCountFlag,

	// Descriptors
	global_descriptor_allocator: DescriptorAllocator,

	// Immediate submit
	imm_fence:                   vk.Fence,
	imm_command_buffer:          vk.CommandBuffer,
	imm_command_pool:            vk.CommandPool,

	// Bindless
	bindless_system:             BindlessSystem,
	current_pipeline:            Pipeline,

	// Limits
	limits:                      vk.PhysicalDeviceLimits, // TODO: Too big?
}

Swapchain :: struct {
	swapchain:              vk.SwapchainKHR,
	swapchain_images:       []vk.Image,
	swapchain_image_index:  u32,
	swapchain_image_views:  []vk.ImageView,
	swapchain_image_format: vk.Format,
	swapchain_extent:       vk.Extent2D,
	arena:                  ResourceArena,
}

create_swapchain :: proc(old_swapchain: vk.SwapchainKHR = 0) {
	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r_ctx.physical_device, r_ctx.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, r_ctx.surface, &format_count, nil)

	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, r_ctx.surface, &format_count, raw_data(formats))


	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, r_ctx.surface, &present_mode_count, nil)

	present_modes := make([]vk.PresentModeKHR, present_mode_count)
	defer delete(present_modes)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, r_ctx.surface, &present_mode_count, raw_data(present_modes))

	surface_format := formats[0]

	for format in formats {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			surface_format = format
		}
	}

	present_mode := choose_swap_present_mode(present_modes)
	extent := choose_swap_extent(r_ctx.window, &capabilities)

	image_count := capabilities.minImageCount + 1

	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
		surface               = r_ctx.surface,
		minImageCount         = image_count,
		imageFormat           = surface_format.format,
		imageColorSpace       = surface_format.colorSpace,
		imageExtent           = extent,
		imageArrayLayers      = 1,
		imageUsage            = {.COLOR_ATTACHMENT, .TRANSFER_DST},

		// TODO: Support multiple queues?
		imageSharingMode      = .EXCLUSIVE,
		queueFamilyIndexCount = 0, // Optional
		pQueueFamilyIndices   = nil, // Optional
		preTransform          = capabilities.currentTransform,
		compositeAlpha        = {.OPAQUE},
		presentMode           = present_mode,
		clipped               = true,
		oldSwapchain          = old_swapchain,
	}

	swapchain := &r_ctx.swapchain

	vk_check(vk.CreateSwapchainKHR(r_ctx.device, &create_info, nil, &swapchain.swapchain))
	defer_destroy(&swapchain.arena, swapchain.swapchain)

	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, nil)
	swapchain.swapchain_images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, raw_data(swapchain.swapchain_images))

	swapchain.swapchain_image_format = surface_format.format
	swapchain.swapchain_extent = extent

	swapchain.swapchain_image_views = make([]vk.ImageView, len(swapchain.swapchain_images))

	for i in 0 ..< len(swapchain.swapchain_images) {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchain.swapchain_images[i],
			viewType = .D2,
			format = swapchain.swapchain_image_format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {aspectMask = {.COLOR}, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1},
		}

		vk_check(vk.CreateImageView(r_ctx.device, &create_info, nil, &swapchain.swapchain_image_views[i]))
		defer_destroy(&swapchain.arena, swapchain.swapchain_image_views[i])
	}

	draw_image_format: vk.Format = .R32G32B32A32_SFLOAT
	draw_image_extent := vk.Extent3D{extent.width, extent.height, 1}
	draw_image_usages := vk.ImageUsageFlags{.TRANSFER_SRC, .TRANSFER_DST, .STORAGE, .COLOR_ATTACHMENT}

	r_ctx.draw_image = create_image(draw_image_format, draw_image_extent, draw_image_usages, msaa_samples = r_ctx.msaa_samples)
	defer_destroy(&swapchain.arena, r_ctx.draw_image)

	// Used for MSAA resolution
	r_ctx.resolve_image = create_image(draw_image_format, draw_image_extent, draw_image_usages, msaa_samples = ._1)
	defer_destroy(&swapchain.arena, r_ctx.resolve_image)

	r_ctx.depth_image = create_image(.D32_SFLOAT, draw_image_extent, {.DEPTH_STENCIL_ATTACHMENT}, msaa_samples = r_ctx.msaa_samples)
	defer_destroy(&swapchain.arena, r_ctx.depth_image)

	r_ctx.draw_extent.width = r_ctx.draw_image.extent.width
	r_ctx.draw_extent.height = r_ctx.draw_image.extent.height
}

destroy_swapchain_resources :: proc(swapchain: ^Swapchain) {
	flush_vk_arena(&swapchain.arena)
	delete_vk_arena(swapchain.arena)
	delete(swapchain.swapchain_image_views)
	delete(swapchain.swapchain_images)
	swapchain^ = {}
}

resize_swapchain :: proc() -> bool {
	width, height := glfw.GetFramebufferSize(r_ctx.window)
	if width <= 0 || height <= 0 {
		return false
	}

	vk.DeviceWaitIdle(r_ctx.device)

	old_swapchain := r_ctx.swapchain
	r_ctx.swapchain = {}
	create_swapchain(old_swapchain.swapchain)
	destroy_swapchain_resources(&old_swapchain)
	return true
}

FrameData :: struct {
	swapchain_semaphore, render_semaphore: vk.Semaphore,
	render_fence:                          vk.Fence,
	command_pool:                          vk.CommandPool,
	main_command_buffer:                   vk.CommandBuffer,
	arena:                                 ResourceArena,
}

begin_immediate_submit :: proc() -> vk.CommandBuffer {
	vk_check(vk.ResetFences(r_ctx.device, 1, &r_ctx.imm_fence))
	vk_check(vk.ResetCommandBuffer(r_ctx.imm_command_buffer, {}))

	cmd := r_ctx.imm_command_buffer

	cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT})

	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	return cmd
}

end_immediate_submit :: proc() {
	cmd := r_ctx.imm_command_buffer

	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := init_command_buffer_submit_info(cmd)
	submit := init_submit_info(&cmd_info, nil, nil)

	// submit command buffer to the queue and execute it.
	//  _renderFence will now block until the graphic commands finish execution
	vk_check(vk.QueueSubmit2(r_ctx.graphics_queue, 1, &submit, r_ctx.imm_fence))

	vk_check(vk.WaitForFences(r_ctx.device, 1, &r_ctx.imm_fence, true, 9_999_999_999))
}

@(deferred_in = end_immediate_submit)
immediate_submit :: proc() -> (cmd: vk.CommandBuffer, ready: bool) {
	return begin_immediate_submit(), true
}

current_frame_index :: proc() -> int {
	return r_ctx.frame_number % FRAME_OVERLAP
}

current_frame :: proc() -> ^FrameData {
	return &r_ctx.frames[current_frame_index()]
}

msaa_samples :: proc() -> vk.SampleCountFlag {
	return r_ctx.msaa_samples
}

msaa_enabled :: proc() -> bool {
	return r_ctx.msaa_samples > ._1
}

renderer :: proc() -> ^Renderer {
	return r_ctx
}

set_renderer :: proc(r: ^Renderer) {
	r_ctx = r
}

init_vulkan :: proc(config: InitConfig) -> bool {
	r_ctx.enable_logs = config.enable_logs
	r_ctx.window = config.window

	{
		// Loads vulkan api functions needed to create an instance
		vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

		// Fallback if glfw is not inialized (headless mode)
		if vk.GetInstanceProcAddr == nil {
			lib := dynlib.load_library("vulkan-1.dll") or_else panic("Can't load vulkan-1 library")
			get_instance_proc_address :=
				dynlib.symbol_address(lib, "vkGetInstanceProcAddr") or_else panic("Can't find vkGetInstanceProcAdr")

			vk.load_proc_addresses_global(get_instance_proc_address)
		}

		if config.enable_validation_layers && !check_validation_layers() {
			panic("validation layers are not available")
		}

		app_info := vk.ApplicationInfo{}
		app_info.sType = .APPLICATION_INFO
		app_info.pApplicationName = "Hello Triangle"
		app_info.applicationVersion = vk.MAKE_VERSION(0, 0, 1)
		app_info.pEngineName = "No Engine"
		app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0)
		app_info.apiVersion = vk.API_VERSION_1_3

		create_info: vk.InstanceCreateInfo
		create_info.sType = .INSTANCE_CREATE_INFO
		create_info.pApplicationInfo = &app_info

		extensions := get_required_extensions(config.enable_validation_layers)
		defer delete(extensions)

		create_info.ppEnabledExtensionNames = raw_data(extensions)
		create_info.enabledExtensionCount = cast(u32)len(extensions)

		debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT{}
		validation_features := vk.ValidationFeaturesEXT {
			sType                         = .VALIDATION_FEATURES_EXT,
			pEnabledValidationFeatures    = raw_data(VALIDATION_FEATURES),
			enabledValidationFeatureCount = u32(len(VALIDATION_FEATURES)),
		}

		if config.enable_validation_layers {
			create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
			create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)

			debug_create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
			debug_create_info.messageSeverity = {.WARNING, .ERROR, .INFO}
			debug_create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
			debug_create_info.pfnUserCallback = debug_callback
			debug_create_info.pNext = &validation_features

			create_info.pNext = &debug_create_info
		} else {
			create_info.enabledLayerCount = 0
			create_info.pNext = nil
		}

		vk_check(vk.CreateInstance(&create_info, nil, &r_ctx.instance))

		// Load instance-specific procedures
		vk.load_proc_addresses_instance(r_ctx.instance)

		n_ext: u32
		vk.EnumerateInstanceExtensionProperties(nil, &n_ext, nil)

		extension_props := make([]vk.ExtensionProperties, n_ext)
		defer delete(extension_props)

		vk.EnumerateInstanceExtensionProperties(nil, &n_ext, raw_data(extension_props))

		log_normal("Available Extensions:")

		for &ext in &extension_props {
			log_normal(" -", cstring(&ext.extensionName[0]))
		}

		if config.enable_validation_layers && !check_validation_layers() {
			panic("Validation layers are not available")
		}
	}

	{
		if config.enable_validation_layers {
			log_normal("Creating Debug Messenger")
			create_info := vk.DebugUtilsMessengerCreateInfoEXT {
				sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				messageSeverity = {.VERBOSE, .WARNING, .INFO, .ERROR},
				messageType     = {.GENERAL, .VALIDATION},
				pfnUserCallback = debug_callback,
				pUserData       = nil,
			}

			vk_check(vk.CreateDebugUtilsMessengerEXT(r_ctx.instance, &create_info, nil, &r_ctx.debug_messenger))
		}
	}

	if r_ctx.window != nil {
		vk_check(glfw.CreateWindowSurface(r_ctx.instance, r_ctx.window, nil, &r_ctx.surface))
	}

	{
		device_count: u32 = 0

		vk.EnumeratePhysicalDevices(r_ctx.instance, &device_count, nil)

		devices := make([]vk.PhysicalDevice, device_count)
		defer delete(devices)
		vk.EnumeratePhysicalDevices(r_ctx.instance, &device_count, raw_data(devices))
		for device in devices {
			is_suitable, is_discrete := is_device_suitable(device)
			if is_suitable && is_discrete {
				r_ctx.physical_device = device
				break
			}
		}

        // Do a second pass but don't require a discrete GPU.
		if r_ctx.physical_device == nil {
            for device in devices {
                is_suitable, _is_discrete := is_device_suitable(device)
                if is_suitable {
                    r_ctx.physical_device = device
                    break
                }
            }
        }

		if r_ctx.physical_device == nil {
			panic("No GPU found that supports all required features.")
		}
	}

	{ 	// Keep device limits
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(r_ctx.physical_device, &properties)

		r_ctx.limits = properties.limits
	}

	{
		queue_family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(r_ctx.physical_device, &queue_family_count, nil)

		queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
		defer delete(queue_families)
		vk.GetPhysicalDeviceQueueFamilyProperties(r_ctx.physical_device, &queue_family_count, raw_data(queue_families))

		has_graphics := false

		for queue_family, i in &queue_families {
			if .GRAPHICS in queue_family.queueFlags {
				r_ctx.graphics_queue_family = u32(i)
				has_graphics = true
			}
		}

		assert(has_graphics, "No graphics queue is supported.")
	}

	{
		queue_priority: f32 = 1.0

		queue_create_info := vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = r_ctx.graphics_queue_family,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pNext                   = &REQUIRED_FEATURES,
			pQueueCreateInfos       = &queue_create_info,
			queueCreateInfoCount    = 1,
			ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
			enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
		}

		vk_check(vk.CreateDevice(r_ctx.physical_device, &device_create_info, nil, &r_ctx.device))

		assert(r_ctx.device != nil)

		vk.GetDeviceQueue(r_ctx.device, r_ctx.graphics_queue_family, 0, &r_ctx.graphics_queue)
	}

	{
		vulkan_functions := vma.create_vulkan_functions()

		allocator_info := vma.AllocatorCreateInfo {
			vulkanApiVersion = vk.API_VERSION_1_3,
			physicalDevice   = r_ctx.physical_device,
			device           = r_ctx.device,
			instance         = r_ctx.instance,
			flags            = {.BUFFER_DEVICE_ADDRESS},
			pVulkanFunctions = &vulkan_functions,
		}

		vma.CreateAllocator(&allocator_info, &r_ctx.allocator)
	}

	r_ctx.msaa_samples = config.msaa_samples

	if r_ctx.window != nil {
		create_swapchain()
	}

	{
		command_pool_info := vk.CommandPoolCreateInfo{}
		command_pool_info.sType = .COMMAND_POOL_CREATE_INFO
		command_pool_info.pNext = nil
		command_pool_info.flags = {.RESET_COMMAND_BUFFER}
		command_pool_info.queueFamilyIndex = r_ctx.graphics_queue_family

		for i in 0 ..< FRAME_OVERLAP {
			vk_check(vk.CreateCommandPool(r_ctx.device, &command_pool_info, nil, &r_ctx.frames[i].command_pool))

			// allocate the default command buffer that we will use for rendering
			cmd_alloc_info := vk.CommandBufferAllocateInfo{}
			cmd_alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO
			cmd_alloc_info.pNext = nil
			cmd_alloc_info.commandPool = r_ctx.frames[i].command_pool
			cmd_alloc_info.commandBufferCount = 1
			cmd_alloc_info.level = .PRIMARY

			vk_check(vk.AllocateCommandBuffers(r_ctx.device, &cmd_alloc_info, &r_ctx.frames[i].main_command_buffer))
		}

		vk_check(vk.CreateCommandPool(r_ctx.device, &command_pool_info, nil, &r_ctx.imm_command_pool))

		// allocate the command buffer for immediate submits
		cmd_alloc_info := init_command_buffer_allocate_info(r_ctx.imm_command_pool, 1)

		vk_check(vk.AllocateCommandBuffers(r_ctx.device, &cmd_alloc_info, &r_ctx.imm_command_buffer))

		defer_destroy(&r_ctx.global_arena, r_ctx.imm_command_pool)
	}

	{
		fence_create_info := init_fence_create_info({.SIGNALED})
		semaphore_create_info := init_semaphore_create_info({})

		for &frame in &r_ctx.frames {
			vk_check(vk.CreateFence(r_ctx.device, &fence_create_info, nil, &frame.render_fence))

			vk_check(vk.CreateSemaphore(r_ctx.device, &semaphore_create_info, nil, &frame.swapchain_semaphore))
			vk_check(vk.CreateSemaphore(r_ctx.device, &semaphore_create_info, nil, &frame.render_semaphore))
		}

		vk.CreateFence(r_ctx.device, &fence_create_info, nil, &r_ctx.imm_fence)
		defer_destroy(&r_ctx.global_arena, r_ctx.imm_fence)
	}

	{
		//create a descriptor pool that will hold 10 sets with 1 image each
		ratio: f32 = 1.0 / 3.0
		sizes: []PoolSizeRatio = {{.SAMPLER, ratio}, {.SAMPLED_IMAGE, ratio}, {.STORAGE_IMAGE, ratio}}
		init_descriptor_allocator(&r_ctx.global_descriptor_allocator, r_ctx.device, 10, sizes, {.UPDATE_AFTER_BIND})
	}

	init_bindless_descriptors()

	return true
}

cleanup_vulkan :: proc() {
	vk.DeviceWaitIdle(r_ctx.device)
	shutdown_bindless_descriptors()

	// Cleanup queued resources
	flush_vk_arena(&r_ctx.global_arena)
	delete_vk_arena(r_ctx.global_arena)

	for &frame in r_ctx.frames {
		vk.DestroyCommandPool(r_ctx.device, frame.command_pool, nil)

		vk.DestroyFence(r_ctx.device, frame.render_fence, nil)
		vk.DestroySemaphore(r_ctx.device, frame.render_semaphore, nil)
		vk.DestroySemaphore(r_ctx.device, frame.swapchain_semaphore, nil)

		flush_vk_arena(&frame.arena)
		delete_vk_arena(frame.arena)
	}

	destroy_pools(&r_ctx.global_descriptor_allocator, r_ctx.device)
	destroy_descriptor_allocator(&r_ctx.global_descriptor_allocator)

	if r_ctx.swapchain.swapchain != 0 {
		destroy_swapchain_resources(&r_ctx.swapchain)
	}

	// Headless mode
	if r_ctx.surface != 0 {
		vk.DestroySurfaceKHR(r_ctx.instance, r_ctx.surface, nil)
	}

	vma.DestroyAllocator(r_ctx.allocator)
	vk.DestroyDevice(r_ctx.device, nil)

	if r_ctx.debug_messenger != 0 {
		vk.DestroyDebugUtilsMessengerEXT(r_ctx.instance, r_ctx.debug_messenger, nil)
	}

	vk.DestroyInstance(r_ctx.instance, nil)
}

set_viewport_and_scissor_2d :: proc(cmd: vk.CommandBuffer, extent: vk.Extent2D) {
	set_viewport_and_scissor_3d(cmd, {extent.width, extent.height, 1})
}

set_viewport_and_scissor_3d :: proc(cmd: vk.CommandBuffer, extent: vk.Extent3D) {
	//set dynamic viewport and scissor
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(extent.width),
		height   = f32(extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}

	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = {extent.width, extent.height},
	}

	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

set_viewport_and_scissor :: proc {
	set_viewport_and_scissor_3d,
	set_viewport_and_scissor_2d,
}

LAST_WRITE: time.Time

is_shaders_updated :: proc() -> bool {
	lib_last_write, _ := os.last_write_time_by_name("./shaders/out/gradient.comp.spv")

	if LAST_WRITE == lib_last_write {
		return false
	}

	LAST_WRITE = lib_last_write

	return true
}

// Called by the user before they start drawing to the screen.
// This command can fail if the window changes size, if `ok` returns false, then don't
// draw anything to the screen. Wait for the window to finish polling.
begin_command_buffer :: proc() -> (cmd: vk.CommandBuffer, ready, swapchain_resized: bool) {
	vk_check(vk.WaitForFences(r_ctx.device, 1, &current_frame().render_fence, true, 1_000_000_000))

	// Delete resources for the current frame
	flush_vk_arena(&current_frame().arena)

	acquire_image_result := vk.AcquireNextImageKHR(
		r_ctx.device,
		r_ctx.swapchain.swapchain,
		1_000_000_000,
		current_frame().swapchain_semaphore,
		0,
		&r_ctx.swapchain.swapchain_image_index,
	)

	if acquire_image_result == .ERROR_OUT_OF_DATE_KHR {
		swapchain_resized = resize_swapchain()
		return nil, false, swapchain_resized
	}
	if acquire_image_result == .SUBOPTIMAL_KHR {
		r_ctx.swapchain_suboptimal = true
	} else {
		vk_check(acquire_image_result)
	}

	r_ctx.draw_extent.width = r_ctx.draw_image.extent.width
	r_ctx.draw_extent.height = r_ctx.draw_image.extent.height

	vk_check(vk.ResetFences(r_ctx.device, 1, &current_frame().render_fence))

	// now that we are sure that the commands finished executing, we can safely
	// reset the command buffer to begin recording again.
	vk_check(vk.ResetCommandBuffer(current_frame().main_command_buffer, {.RELEASE_RESOURCES}))

	// naming it cmd for shorter writing
	cmd = current_frame().main_command_buffer

	// begin the command buffer recording. We will use this command buffer exactly once, so we want to let vulkan know that
	cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT})

	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	return cmd, true, false
}

copy_image_to_swapchain :: proc(cmd: vk.CommandBuffer, source: vk.Image, src_size: vk.Extent2D) {
	transition_vk_image(cmd, r_ctx.swapchain.swapchain_images[r_ctx.swapchain.swapchain_image_index], .UNDEFINED, .TRANSFER_DST_OPTIMAL)

	copy_image_to_image(
		cmd,
		source,
		r_ctx.swapchain.swapchain_images[r_ctx.swapchain.swapchain_image_index],
		src_size,
		r_ctx.swapchain.swapchain_extent,
	)
}

// Called by the user when they end drawing to the screen.
submit :: proc(cmd: vk.CommandBuffer) -> (swapchain_resized: bool) {
	// set swapchain image layout to Present so we can show it on the screen
	transition_vk_image(
		cmd,
		r_ctx.swapchain.swapchain_images[r_ctx.swapchain.swapchain_image_index],
		.TRANSFER_DST_OPTIMAL,
		.PRESENT_SRC_KHR,
	)

	//finalize the command buffer (we can no longer add commands, but it can now be executed)
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := init_command_buffer_submit_info(cmd)

	wait_info := init_semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT}, current_frame().swapchain_semaphore)
	signal_info := init_semaphore_submit_info({.ALL_GRAPHICS}, current_frame().render_semaphore)

	submit := init_submit_info(&cmd_info, &signal_info, &wait_info)

	vk_check(vk.QueueSubmit2(r_ctx.graphics_queue, 1, &submit, current_frame().render_fence))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pSwapchains        = &r_ctx.swapchain.swapchain,
		swapchainCount     = 1,
		pWaitSemaphores    = &current_frame().render_semaphore,
		waitSemaphoreCount = 1,
		pImageIndices      = &r_ctx.swapchain.swapchain_image_index,
	}

	queue_present_result := vk.QueuePresentKHR(r_ctx.graphics_queue, &present_info)

	if queue_present_result == .ERROR_OUT_OF_DATE_KHR ||
	   queue_present_result == .SUBOPTIMAL_KHR ||
	   r_ctx.swapchain_suboptimal {
		swapchain_resized = resize_swapchain()
		r_ctx.swapchain_suboptimal = false
	} else {
		// TODO: Do normal assert check, maybe other cases though?
		vk_check(queue_present_result)
	}

	r_ctx.frame_number += 1

	return
}

InitConfig :: struct {
	window:                   glfw.WindowHandle,
	msaa_samples:             vk.SampleCountFlag,
	enable_validation_layers: bool,
	enable_logs:              bool,
}

init :: proc(config := InitConfig{}) -> ^Renderer {
	r_ctx = new(Renderer)

	if !init_vulkan(config) {
		assert(false)
	}

	return r_ctx
}

choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// FIFO is vsync (no tearing) and is guaranteed available by the Vulkan spec.
	return .FIFO
}

choose_swap_extent :: proc(window: glfw.WindowHandle, capabilities: ^vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if (capabilities.currentExtent.width != max(u32)) {
		return capabilities.currentExtent
	} else {
		width, height := glfw.GetFramebufferSize(window)

		actual_extent := vk.Extent2D{u32(width), u32(height)}

		actual_extent.width = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

		return actual_extent
	}
}

supports_required_features :: proc(required: $T, test: T) -> bool {
	required := required
	test := test

	id := typeid_of(T)
	names := reflect.struct_field_names(id)
	types := reflect.struct_field_types(id)
	offsets := reflect.struct_field_offsets(id)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, " - ")
	reflect.write_type(&builder, type_info_of(T))
	strings.write_string(&builder, "\n")

	has_any_flags := false
	supports_all_flags := true

	for i in 0 ..< len(offsets) {
		// The flags are of type boolean
		if reflect.type_kind(types[i].id) == .Boolean {
			offset := offsets[i]

			// Grab the values at the offsets
			required_value := (cast(^b32)(uintptr(&required) + offset))^
			test_value := (cast(^b32)(uintptr(&test) + offset))^

			// Check if the flag is required
			if required_value {
				strings.write_string(&builder, "   + ")
				strings.write_string(&builder, names[i])

				// Returns false if the test doesn't have the required flag.
				if required_value != test_value {
					strings.write_string(&builder, " \xE2\x9D\x8C\n")
					supports_all_flags = false
				} else {
					strings.write_string(&builder, " \xE2\x9C\x94\n")
					has_any_flags = true
				}
			}
		}
	}

	if has_any_flags {
		log_normal(strings.to_string(builder))
	}

	return supports_all_flags
}

is_device_suitable :: proc(device: vk.PhysicalDevice) -> (is_suitable: bool, is_discrete: bool) {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(device, &properties)

    log_normal("GPU:", string(properties.deviceName[:]))

    vk_ray_query_features := vk.PhysicalDeviceRayQueryFeaturesKHR {
        sType = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR,
    }

	vk_accel_features := vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
		sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
        pNext = &vk_ray_query_features,
	}

	vk_13_features := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext = &vk_accel_features,
	}

	vk_12_features := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &vk_13_features,
	}

	vk_11_features := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &vk_12_features,
	}

	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vk_11_features,
	}

	vk.GetPhysicalDeviceFeatures2(device, &features)

	log_normal("Required Features:")
	supports_features :=
		supports_required_features(REQUIRED_FEATURES, features) &&
		supports_required_features(REQUIRED_VK_11_FEATURES, vk_11_features) &&
		supports_required_features(REQUIRED_VK_12_FEATURES, vk_12_features) &&
		supports_required_features(REQUIRED_VK_13_FEATURES, vk_13_features)

	extensions_supported := check_device_extension_support(device)

	// Headless mode
	if r_ctx.swapchain.swapchain == 0 {
		return extensions_supported && supports_features, properties.deviceType == .DISCRETE_GPU
	}

	swapchain_adequate := false
	if extensions_supported {
		format_count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, r_ctx.surface, &format_count, nil)
		present_mode_count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, r_ctx.surface, &present_mode_count, nil)

		swapchain_adequate = format_count > 0 && present_mode_count > 0
	}

	return swapchain_adequate && extensions_supported && supports_features, properties.deviceType == .DISCRETE_GPU
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
	extension_count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)

	available_extensions := make([]vk.ExtensionProperties, extension_count)
	defer delete(available_extensions)
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(available_extensions))

	for &expected_extension in DEVICE_EXTENSIONS {
		found := false
		for &available in &available_extensions {
			if strings.compare(string(cstring(&available.extensionName[0])), string(expected_extension)) == 0 {
				found = true
				break
			}
		}

        if !found {
            log_normal("Extension not available:", expected_extension)
        }

		found or_return
	}

	return true
}

debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	log_normal(callback_data.pMessage)
	for i in 0 ..< callback_data.objectCount {
		name := callback_data.pObjects[i].pObjectName

		if len(name) > 0 {
			log_normal(" -", callback_data.pObjects[i].pObjectName)
		}
	}
	log_normal()

	return false
}

check_validation_layers :: proc() -> bool {
	layer_count: u32 = 0
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	available_layers := make([]vk.LayerProperties, layer_count)
	defer delete(available_layers)
	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))

	for layer_name in VALIDATION_LAYERS {
		layer_found := false

		for &layer_property in &available_layers {
			if strings.compare(string(layer_name), string(cstring(&layer_property.layerName[0]))) == 0 {
				layer_found = true
				break
			}
		}

		layer_found or_return
	}


	return true
}

get_required_extensions :: proc(enable_validation_layers: bool) -> [dynamic]cstring {
	glfw_extensions := glfw.GetRequiredInstanceExtensions()

	extension_count := len(glfw_extensions)

	extensions: [dynamic]cstring
	resize(&extensions, extension_count)

	for ext, i in glfw_extensions {
		extensions[i] = ext
	}

	if enable_validation_layers {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	return extensions
}

// If the renderer is in a shared library, make sure to call this after hot reloading
load_vulkan_addresses :: proc() {
	// Loads vulkan api functions needed to create an instance
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	// Fallback if glfw is not inialized (headless mode)
	if vk.GetInstanceProcAddr == nil {
		lib := dynlib.load_library("vulkan-1.dll") or_else panic("Can't load vulkan-1 library")
		get_instance_proc_address := dynlib.symbol_address(lib, "vkGetInstanceProcAddr") or_else panic("Can't find vkGetInstanceProcAdr")

		vk.load_proc_addresses_global(get_instance_proc_address)
	}

	vk.load_proc_addresses_instance(r_ctx.instance)
}


shutdown :: proc() {
	if r_ctx == nil do return
	cleanup_vulkan()
	free(r_ctx)
	r_ctx = nil
}
