package gfx

import "core:container/queue"
import "core:log"
import "base:runtime"
import "core:dynlib"
import "core:reflect"
import "core:strings"

import vma "deps:odin-vma"
import "vendor:glfw"
import vk "vendor:vulkan"

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

Capabilities :: struct {
	ray_query: bool,
}

Queue_Kind :: enum {
    Main,
    Compute,
    Transfer,
}

Queue :: struct {
    queue:                vk.Queue,
    family_index:         u32,
    vk_index:             u32,

    semaphore:            Semaphore,
	command_pool:         vk.CommandPool,
	free_command_buffers: [dynamic]struct {
        cmd: vk.CommandBuffer,
        value: u64,
    },
    last_value:           u64,
}

Renderer :: struct {
	debug_messenger: vk.DebugUtilsMessengerEXT,
	enable_logs:     bool,
    debug_logger:    log.Logger,

	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
	allocator:       vma.Allocator,

    queues:          [Queue_Kind]Queue,

	bindless_system:  BindlessSystem,
	current_pipeline: Pipeline,

	limits:       vk.PhysicalDeviceLimits, // TODO: Too big?
	capabilities: Capabilities,
}

init_vulkan :: proc(config: InitConfig) -> bool {
	r_ctx.enable_logs = config.enable_logs
    r_ctx.debug_logger = context.logger

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
		app_info.pApplicationName = "gfx"
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

		log.info("Available Extensions:")

		for &ext in &extension_props {
			log.info(" -", cstring(&ext.extensionName[0]))
		}

		if config.enable_validation_layers && !check_validation_layers() {
			panic("Validation layers are not available")
		}
	}

	{
		if config.enable_validation_layers {
			log.info("Creating Debug Messenger")
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

        // algo below is shamelessly inspired by no_gfx_api, just simpler-ish
        families: [Queue_Kind]u32
        found_graphics := true

        // find dedicated
        for queue_family, i in &queue_families {
            has_graphics := .GRAPHICS in queue_family.queueFlags
            has_compute  := .COMPUTE  in queue_family.queueFlags
            has_transfer := .TRANSFER in queue_family.queueFlags

            if families[.Main] == 0 && has_graphics && has_compute && has_transfer {
                found_graphics = true
                families[.Main] = u32(i)
            }
            if families[.Compute] == 0 && !has_graphics && has_compute && has_transfer {
                families[.Compute] = u32(i)
            }
            if families[.Transfer] == 0 && !has_graphics && !has_compute && has_transfer {
                families[.Transfer] = u32(i)
            }
        }

        assert(found_graphics, "Graphics queue type not available!")

        // fallback if a dedicated one doesn't exist
        for queue_family, i in &queue_families {
            has_compute  := .COMPUTE  in queue_family.queueFlags
            has_transfer := .TRANSFER in queue_family.queueFlags

            if families[.Compute] == 0 && has_compute {
                families[.Compute] = u32(i)
            }
            if families[.Transfer] == 0 && has_transfer {
                families[.Transfer] = u32(i)
            }
        }

        queue_create_infos: [dynamic]vk.DeviceQueueCreateInfo

        for &queue_a, i in &r_ctx.queues {
            for queue_b in &r_ctx.queues {
                if queue_a.family_index == queue_b.family_index {
                    queue_a = queue_b
                    continue
                }
            }

            queue_a.family_index = families[i]
            queue_a.vk_index = 0 // currently we only do 1 queue per family

            append(&queue_create_infos, {
                sType            = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = queue_a.family_index,
                queueCount       = 1,
            })
        }

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pNext                   = &REQUIRED_FEATURES,

			pQueueCreateInfos       = raw_data(queue_create_infos),
			queueCreateInfoCount    = u32(len(queue_create_infos)),

			ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
			enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
		}

		vk_check(vk.CreateDevice(r_ctx.physical_device, &device_create_info, nil, &r_ctx.device))

		assert(r_ctx.device != nil)

        for &queue in &r_ctx.queues {
            vk.GetDeviceQueue(r_ctx.device, queue.family_index, queue.vk_index, &queue.queue)
            queue.semaphore = create_semaphore(0)
        }
	}

	{
		vulkan_functions := vma.create_vulkan_functions()

		allocator_info := vma.AllocatorCreateInfo {
			vulkanApiVersion = vk.API_VERSION_1_3,
			physicalDevice   = r_ctx.physical_device,
			device           = r_ctx.device,
			instance         = r_ctx.instance,
			flags            = {.BUFFER_DEVICE_ADDRESS, .EXT_MEMORY_BUDGET},
			pVulkanFunctions = &vulkan_functions,
		}

		vma.CreateAllocator(&allocator_info, &r_ctx.allocator)
	}

	{
        for i in 0..<len(Queue_Kind) {
            kind := Queue_Kind(i)

            command_pool_info := vk.CommandPoolCreateInfo{
                sType = .COMMAND_POOL_CREATE_INFO,
                pNext = nil,
                flags = {.RESET_COMMAND_BUFFER},
                queueFamilyIndex = r_ctx.queues[kind].family_index,
            }

			vk_check(vk.CreateCommandPool(r_ctx.device, &command_pool_info, nil, &r_ctx.queues[kind].command_pool))
        }

	}

	init_bindless_descriptors()

	return true
}

cleanup_vulkan :: proc() {
	vk.DeviceWaitIdle(r_ctx.device)

	// Deferred image/sampler destruction resolves IDs through these tables.
	shutdown_bindless_descriptors()

	vma.DestroyAllocator(r_ctx.allocator)
	vk.DestroyDevice(r_ctx.device, nil)

	if r_ctx.debug_messenger != 0 {
		vk.DestroyDebugUtilsMessengerEXT(r_ctx.instance, r_ctx.debug_messenger, nil)
	}

	vk.DestroyInstance(r_ctx.instance, nil)
}

set_viewport_and_scissor_2d :: proc(cmd: CommandBuffer, extent: vk.Extent2D) {
	set_viewport_and_scissor_3d(cmd, {extent.width, extent.height, 1})
}

set_viewport_and_scissor_3d :: proc(cmd: CommandBuffer, extent: vk.Extent3D) {
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

_get_command_buffer :: proc(kind: Queue_Kind) -> CommandBuffer {
    queue := &r_ctx.queues[kind]
    cmd: vk.CommandBuffer

    if len(r_ctx.queues[kind].free_command_buffers) > 0 {
        free := pop(&r_ctx.queues[kind].free_command_buffers)
        if get_semaphore_value(queue.semaphore) >= free.value {
            return free.cmd
        }

        // otherwise, push to the end of the list and try later.
        append(&r_ctx.queues[kind].free_command_buffers, free)
    }
    
    // allocate one
    log.warn("Allocating command buffer.")

    alloc_info := vk.CommandBufferAllocateInfo{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        pNext = nil,
        commandPool = r_ctx.queues[kind].command_pool,
        commandBufferCount = 1,
        level = .PRIMARY,
    }

    vk_check(vk.AllocateCommandBuffers(r_ctx.device, &alloc_info, &cmd))
    return cmd
}

// Called by the user before they start drawing to the screen.
// This command can fail if the window changes size, if `ok` returns false, then don't
// draw anything to the screen. Wait for the window to finish polling.
begin_command_buffer :: proc(kind: Queue_Kind) -> (cmd: CommandBuffer) {
    cmd = _get_command_buffer(kind)

	vk_check(vk.ResetCommandBuffer(cmd, {.RELEASE_RESOURCES}))

	begin_info := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        pNext = nil,
        pInheritanceInfo = nil,
        flags = {.ONE_TIME_SUBMIT},
    }

	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	return cmd
}

copy_image_to_swapchain :: proc(cmd: CommandBuffer, image_id: ImageId, src_size: vk.Extent2D, swapchain: ^Swapchain) {
    assert(swapchain != nil, "Swapchain is nil.")

	transition_image(cmd, swapchain.swapchain_images[swapchain.swapchain_image_index], .TRANSFER_DST_OPTIMAL)

	copy_image_to_image(
		cmd,
		image_id,
		swapchain.swapchain_images[swapchain.swapchain_image_index],
		src_size,
		swapchain.swapchain_extent,
	)
}

// Called by the user when they end drawing to the screen.
queue_submit :: proc(
    kind: Queue_Kind,
    cmd: CommandBuffer,
    sema_waits: []Semaphore_Pair = {},
    sema_signals: []Semaphore_Pair = {},
    swapchain: ^Swapchain = nil
) -> (done_semaphore: Semaphore_Pair) {
    queue := &r_ctx.queues[kind]
    if swapchain != nil {
        transition_image(cmd, swapchain.swapchain_images[swapchain.swapchain_image_index], .PRESENT_SRC_KHR)
    }

	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := init_command_buffer_submit_info(cmd)

    has_swapchain_count := swapchain == nil ? 0 : 1

    waits := make([]vk.SemaphoreSubmitInfo, len(sema_waits) + has_swapchain_count, context.temp_allocator)
    signals := make([]vk.SemaphoreSubmitInfo, len(sema_signals) + has_swapchain_count + 1, context.temp_allocator)

    for &wait, i in sema_waits {
        waits[i] = {
            sType       = .SEMAPHORE_SUBMIT_INFO,
            pNext       = nil,
            semaphore   = vk.Semaphore(wait.sema),
            stageMask   = {.ALL_COMMANDS},
            deviceIndex = 0,
            value       = wait.value,
        }
    }
    
    for &signal, i in sema_signals {
        signals[i] = {
            sType       = .SEMAPHORE_SUBMIT_INFO,
            pNext       = nil,
            semaphore   = vk.Semaphore(signal.sema),
            stageMask   = {.ALL_COMMANDS},
            deviceIndex = 0,
            value       = signal.value,
        }
    }

    if swapchain != nil {
        // wait for swapchain to acquire
        wait_info := vk.SemaphoreSubmitInfo {
            sType       = .SEMAPHORE_SUBMIT_INFO,
            pNext       = nil,
            semaphore   = swapchain.acquire_semaphores[swapchain.frame_index],
            stageMask   = {.COLOR_ATTACHMENT_OUTPUT},
            deviceIndex = 0,
            value       = 1,
        }

        // signal present when we have an image acquired
        signal_info := vk.SemaphoreSubmitInfo {
            sType       = .SEMAPHORE_SUBMIT_INFO,
            pNext       = nil,
            semaphore   = swapchain.present_semaphores[swapchain.frame_index],
            stageMask   = {.ALL_GRAPHICS},
            deviceIndex = 0,
            value       = 1,
        }

        waits[len(waits) - 1] = wait_info
        signals[len(signals) - 2] = signal_info
    }

    // signal when the cmd buffer is safe to reuse
    // append to free list with timestamp of the last value
    {
        queue.last_value += 1

        signals[len(signals) - 1] = {
            sType       = .SEMAPHORE_SUBMIT_INFO,
            pNext       = nil,
            semaphore   = vk.Semaphore(queue.semaphore),
            stageMask   = {.ALL_COMMANDS},
            deviceIndex = 0,
            value       = queue.last_value,
        }

        append(&r_ctx.queues[kind].free_command_buffers, {
            cmd = cmd,
            value = queue.last_value,
        })

        done_semaphore = {
            queue.semaphore,
            queue.last_value,
        }
    }

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		pNext                    = nil,
		waitSemaphoreInfoCount   = u32(len(waits)),
		pWaitSemaphoreInfos      = raw_data(waits),
		signalSemaphoreInfoCount = u32(len(signals)),
		pSignalSemaphoreInfos    = raw_data(signals),
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &vk.CommandBufferSubmitInfo{
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = cmd,
        },
	}

	vk_check(vk.QueueSubmit2(r_ctx.queues[kind].queue, 1, &submit_info, {}))

    if swapchain != nil {
        present_info := vk.PresentInfoKHR {
            sType              = .PRESENT_INFO_KHR,
            pSwapchains        = &swapchain.swapchain,
            swapchainCount     = 1,
            pWaitSemaphores    = &swapchain.present_semaphores[swapchain.frame_index],
            waitSemaphoreCount = 1,
            pImageIndices      = &swapchain.swapchain_image_index,
        }

        // TODO: handle this.
        queue_present_result := vk.QueuePresentKHR(r_ctx.queues[kind].queue, &present_info)
    }

	return
}

InitConfig :: struct {
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
		log.info(strings.to_string(builder))
	}

	return supports_all_flags
}

is_device_suitable :: proc(device: vk.PhysicalDevice) -> (is_suitable: bool, is_discrete: bool) {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(device, &properties)

	log.info("GPU:", string(properties.deviceName[:]))

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

	log.info("Required Features:")
	supports_features :=
		supports_required_features(REQUIRED_FEATURES, features) &&
		supports_required_features(REQUIRED_VK_11_FEATURES, vk_11_features) &&
		supports_required_features(REQUIRED_VK_12_FEATURES, vk_12_features) &&
		supports_required_features(REQUIRED_VK_13_FEATURES, vk_13_features)

	extensions_supported := check_device_extension_support(device)

	return extensions_supported && supports_features, properties.deviceType == .DISCRETE_GPU
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
			log.info("Extension not available:", expected_extension)
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
    context.logger = r_ctx.debug_logger
	log.debug(callback_data.pMessage)
	for i in 0 ..< callback_data.objectCount {
		name := callback_data.pObjects[i].pObjectName

		if len(name) > 0 {
			log.info(" -", callback_data.pObjects[i].pObjectName)
		}
	}
	log.debug()

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
