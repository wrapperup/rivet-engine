package gfx

import "core:container/pool"
import "core:mem"
import "core:slice"
import "core:fmt"
import "core:container/queue"
import "core:log"
import "base:runtime"
import "core:dynlib"
import "core:reflect"
import "core:strings"

import vma "deps:odin-vma"
import "vendor:glfw"
import vk "vendor:vulkan"

import dynamic_pool "../containers/dynamic_pool"

MAX_BINDLESS_IMAGES :: 1024
MAX_BINDLESS_SAMPLERS :: 128

BINDLESS_SAMPLED_IMAGES: u32 : 0
BINDLESS_SAMPLERS: u32 : 1
BINDLESS_STORAGE_IMAGES: u32 : 2

DEFAULT_VERTEX_ENTRY: cstring : "vertex_main"
DEFAULT_FRAGMENT_ENTRY: cstring : "fragment_main"
DEFAULT_COMPUTE_ENTRY: cstring : "compute_main"

Image_Id :: distinct u32
Sampler_Id :: distinct u32

Command_Buffer :: vk.CommandBuffer
Clear_Value :: vk.ClearValue
Shader_Module :: vk.ShaderModule

Gfx_Context :: struct {
	debug_messenger:  vk.DebugUtilsMessengerEXT,
	enable_logs:      bool,
    debug_logger:     log.Logger,

	instance:         vk.Instance,
	physical_device:  vk.PhysicalDevice,
	device:           vk.Device,
	allocator:        vma.Allocator,

    queues:           [Queue_Kind]Queue,

	bindless_system:  Bindless_System,
	current_pipeline: Pipeline,

	limits:           vk.PhysicalDeviceLimits, // TODO: Too big?
	capabilities:     Capabilities,
}

Capabilities :: struct {
	ray_query: bool,
}

Queue_Kind :: enum {
    Main,
    Compute,
    Transfer,
}

Queue :: struct {
    queue:        vk.Queue,
    family_index: u32,
    vk_index:     u32,

	command_pool:         vk.CommandPool,
	free_command_buffers: [dynamic]struct {
        cmd: vk.CommandBuffer,
        value: u64,
    },

    semaphore:            Semaphore,
    last_value:           u64,
}

Init_Config :: struct {
	enable_validation_layers: bool,
	enable_logs:              bool,
}

Image :: struct {
	image:          vk.Image,
	image_view:     vk.ImageView,
	allocation:     vma.Allocation,
	extent:         Extent_3D,
	format:         vk.Format,
	mip_levels:     u32,
	array_layers:   u32,
	current_layout: Image_Layout,
	usage:          vk.ImageUsageFlags,
	view_type:      vk.ImageViewType,
	owns_image:     bool,
}

Image_Access :: enum {
	None,
	All_Writes,
	All_Reads_Writes,
	Compute_Shader_Read,
	Compute_Shader_Write,
	Compute_Shader_Read_Write,
	All_Shader_Read,
	Compute_Fragment_Shader_Read,
	Fragment_Shader_Read,
	Color_Attachment_Read_Write,
	Depth_Attachment_Read_Write,
	Transfer_Read,
	Transfer_Write,
}

// A count of zero covers all remaining mip levels or array layers.
Image_Subresource_Range :: struct {
	base_mip_level:   u32,
	mip_count:        u32,
	base_array_layer: u32,
	layer_count:      u32,
}

Descriptor_Binding :: struct {
	binding: u32,
	type:    vk.DescriptorType,
	count:   u32,
}

Descriptor_Write :: struct {
	binding:      u32,
	type:         vk.DescriptorType,
	image_view:   vk.ImageView,
	sampler:      vk.Sampler,
	image_layout: vk.ImageLayout,
	buffer:       vk.Buffer,
	array_index:  u32,
}

Deletion_Queue :: struct {
	queue: [dynamic]Resource_Handle,
}

Resource_Handle :: struct {
	ty:              Resource_Type,
	handle:          u64,
	allocation:      vma.Allocation,
	debug_info:      string,
	caller_location: runtime.Source_Code_Location,
}

Resource_Type :: enum {
	Bindless_Image,
	Bindless_Sampler,
	Vma_Buffer,
	Command_Pool,
	Descriptor_Pool,
	Descriptor_Set_Layout,
	Fence,
	Image_View,
	Pipeline,
	Pipeline_Layout,
	Acceleration_Structure,
	Swapchain,
	Surface,
	Semaphore,
}

Rendering_Attachment_Info :: struct {
	view:        Image_Id,
	clear_value: ^vk.ClearValue,
}

Buffer :: struct($T: typeid) {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.AllocationInfo,
	ptr:        Ptr(T),
	count:      u64,
}

Buffer_Access :: enum {
	None,
	All_Reads,
	All_Writes,
	All_Reads_Writes,
	Compute_Shader_Read,
	Compute_Shader_Write,
	Vertex_Shader_Read,
	Fragment_Shader_Read,
	Transfer_Read,
	Transfer_Write,
	Acceleration_Structure_Build_Read,
	Acceleration_Structure_Build_Write,
	Acceleration_Structure_Read,
}

// This is hopefully very common kinds of buffers
// you may typically want to create. Uniform and Storage
// buffers will always create a valid Ptr(T).
Buffer_Memory_Flag :: enum {
	nil,
	Host_Sequential_Write,
	Host_Random,
}
Buffer_Memory_Flags :: bit_set[Buffer_Memory_Flag]

Ptr :: struct($T: typeid) {
	address: vk.DeviceAddress,
}

// GPU-side array view.
Slice :: struct($T: typeid) {
	data:  Ptr(T),
	count: u64,
}

Scratch :: struct {
	buffer:         Buffer(u8),
	current_offset: vk.DeviceSize,
}

// TODO: Do we need this? It would be useful I think at some point.
// It's specific push/pop functions will update a buffer automatically,
// and maps to an Odin dynamic array.
//DynamicArray :: struct {
//	using _: Buffer,
//}

Bindless_System :: struct {
	descriptor_layout: vk.DescriptorSetLayout,
	pool:              vk.DescriptorPool,
	descriptor_set:    vk.DescriptorSet,

	// StorageHandle_Pool
	images:            dynamic_pool.Dynamic_Pool(Image, Image_Id),
	samplers:          dynamic_pool.Dynamic_Pool(vk.Sampler, Sampler_Id),
}

Pipeline :: struct {
	layout:      vk.PipelineLayout,
	pipeline:    vk.Pipeline,
	stage_flags: vk.ShaderStageFlags,
	bind_point:  vk.PipelineBindPoint,
}

Pipeline_Blend_Mode :: enum {
	None,
	Additive,
	Alpha,
}

Topology :: enum u8 {
	Triangle_List,
	Triangle_Strip,
	Line_List,
}

Depth_State :: struct {
	format:        vk.Format,
	compare_op:    vk.CompareOp,
	write_enabled: b32,
}

Graphics_Pipeline_Desc :: struct {
	topology:          Topology,
	polygon_mode:      vk.PolygonMode,
	front_face:        vk.FrontFace,
	cull_mode:         vk.CullModeFlags,
	depth:             Depth_State,
	depth_clamp:       bool,
	blend_mode:        Pipeline_Blend_Mode,
	color_format:      vk.Format,
	msaa_sample_count: vk.SampleCountFlag,
	depth_only:        bool,
	vertex_entry:      cstring,
	fragment_entry:    cstring,
}

Compute_Pipeline_Desc :: struct {
	entry: cstring,
}

Pipeline_Desc :: union {
	Graphics_Pipeline_Desc,
	Compute_Pipeline_Desc,
}

Swapchain :: struct {
	swapchain:              vk.SwapchainKHR,
	_old_swapchain:          vk.SwapchainKHR,

    surface:                vk.SurfaceKHR,
	swapchain_images:       []Image_Id,
	swapchain_image_index:  u32,
	swapchain_image_format: vk.Format,
	swapchain_extent:       Extent_2D,
    present_semaphores:     []vk.Semaphore,
    acquire_semaphores:     []vk.Semaphore,
    present_mode:           vk.PresentModeKHR,
    max_frames_in_flight:   int,
    frame_index:            int,
	arena:                  Deletion_Queue,
}


// Timeline semaphores only.
Semaphore :: distinct vk.Semaphore

Semaphore_Pair :: struct {
    sema: Semaphore,
    value: u64,
}

Raytracing_Accel :: struct {
	accel:   vk.AccelerationStructureKHR,
	buffer:  Buffer(u8), // .AccelStorage backing
	address: vk.DeviceAddress,
	type:    vk.AccelerationStructureTypeKHR,
}

Raytracing_Props :: struct {
	scratch_align: u32,
	max_instances: u64,
}


Extent_2D :: [2]u32
Extent_3D :: [3]u32

Offset_2D :: [2]i32
Offset_3D :: [3]i32

Rect_2D :: struct {
	offset: Offset_2D,
	extent: Extent_2D,
}

Image_Layout :: enum {
    Undefined,
    General,
    Present_Src,
}


// Set required features to enable here. These are used to pick the physical device as well.
REQUIRED_FEATURES := vk.PhysicalDeviceFeatures2 {
	sType = .PHYSICAL_DEVICE_FEATURES_2,
	features = {
		samplerAnisotropy = true,
		shaderStorageImageMultisample = true,
		shaderImageGatherExtended = true,
		multiDrawIndirect = true,
		geometryShader = true,
		depthClamp = true,
		shaderInt64 = true,
		shaderInt16 = true,
		shaderFloat64 = true,
		fragmentStoresAndAtomics = true,
		vertexPipelineStoresAndAtomics = true,
	},
	pNext = &REQUIRED_VK_11_FEATURES,
}

REQUIRED_VK_11_FEATURES := vk.PhysicalDeviceVulkan11Features {
	sType                         = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
	pNext                         = &REQUIRED_VK_12_FEATURES,
	variablePointers              = true,
	variablePointersStorageBuffer = true,
	shaderDrawParameters          = true,
}

REQUIRED_VK_12_FEATURES := vk.PhysicalDeviceVulkan12Features {
	sType                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	pNext                        = &REQUIRED_VK_13_FEATURES,
	bufferDeviceAddress          = true,
	descriptorIndexing           = true,
	storagePushConstant8         = true,
	shaderInt8                   = true,
	runtimeDescriptorArray       = true,
	scalarBlockLayout            = true,
	vulkanMemoryModel            = true,
	vulkanMemoryModelDeviceScope = true,
	timelineSemaphore            = true,
}

REQUIRED_VK_13_FEATURES := vk.PhysicalDeviceVulkan13Features {
	sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	pNext            = &REQUIRED_VK_RAY_ACCEL_FEATURES,
	dynamicRendering = true,
	synchronization2 = true,
}

REQUIRED_VK_RAY_ACCEL_FEATURES := vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
	sType                 = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
	pNext                 = &REQUIRED_VK_RAY_QUERY_FEATURES,
	accelerationStructure = true,
}

REQUIRED_VK_RAY_QUERY_FEATURES := vk.PhysicalDeviceRayQueryFeaturesKHR {
	sType    = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR,
	rayQuery = true,
}

// Set required extensions to support.
DEVICE_EXTENSIONS := []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME, // Enabled by default in 1.3
	vk.KHR_SHADER_NON_SEMANTIC_INFO_EXTENSION_NAME, // Enable by default in 1.3
	vk.KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,
	vk.KHR_RAY_QUERY_EXTENSION_NAME,
	vk.KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,
}

// Set validation layers to enable.
VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}
VALIDATION_FEATURES := []vk.ValidationFeatureEnableEXT{}

r_ctx: ^Gfx_Context


/////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////


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

init_vulkan :: proc(config: Init_Config) -> bool {
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

        priority := f32(1.0)
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
                pQueuePriorities = &priority
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

_get_command_buffer :: proc(kind: Queue_Kind) -> Command_Buffer {
    queue := &r_ctx.queues[kind]

    if len(queue.free_command_buffers) > 0 {
        oldest := queue.free_command_buffers[0]
        if get_semaphore_value(queue.semaphore) >= oldest.value {
            ordered_remove(&queue.free_command_buffers, 0)
            return oldest.cmd
        }
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

    cmd: Command_Buffer
    vk_check(vk.AllocateCommandBuffers(r_ctx.device, &alloc_info, &cmd))

    return cmd
}

// Called by the user before they start drawing to the screen.
// This command can fail if the window changes size, if `ok` returns false, then don't
// draw anything to the screen. Wait for the window to finish polling.
begin_command_buffer :: proc(kind: Queue_Kind) -> (cmd: Command_Buffer) {
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

// Called by the user when they end drawing to the screen.
queue_submit :: proc(
    kind: Queue_Kind,
    cmd: Command_Buffer,
    sema_waits: []Semaphore_Pair = {},
    sema_signals: []Semaphore_Pair = {},
    swapchain: ^Swapchain = nil
) -> (done_semaphore: Semaphore_Pair) {
    queue := &r_ctx.queues[kind]
    if swapchain != nil {
        transition_image(cmd, swapchain.swapchain_images[swapchain.swapchain_image_index], .Present_Src)
    }

	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		pNext         = nil,
		commandBuffer = cmd,
		deviceMask    = 0,
	}

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
            semaphore   = swapchain.present_semaphores[swapchain.swapchain_image_index],
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

	return
}

init :: proc(config := Init_Config{}) -> ^Gfx_Context {
	r_ctx = new(Gfx_Context)

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

cleanup_vulkan :: proc() {
	vk.DeviceWaitIdle(r_ctx.device)

    for queue in r_ctx.queues {
        vk.DestroyCommandPool(r_ctx.device, queue.command_pool, nil)
        destroy_semaphore(queue.semaphore)
    }

	// Deferred image/sampler destruction resolves IDs through these tables.
	shutdown_bindless_descriptors()

	vma.DestroyAllocator(r_ctx.allocator)
	vk.DestroyDevice(r_ctx.device, nil)

	if r_ctx.debug_messenger != 0 {
		vk.DestroyDebugUtilsMessengerEXT(r_ctx.instance, r_ctx.debug_messenger, nil)
	}

	vk.DestroyInstance(r_ctx.instance, nil)
}


// This allocates on the GPU, make sure to call `destroy_image` or add to the deletion queue when you are finished with the image.
create_image :: proc(
	format: vk.Format,
	extent: Extent_3D,
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
) -> Image_Id {
	img_alloc_info := vma.AllocationCreateInfo {
		usage         = usage,
		requiredFlags = {.DEVICE_LOCAL},
		flags         = alloc_flags,
	}

	img_info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		imageType   = image_type,
		format      = format,
		extent      = {**extent},
		mipLevels   = mip_levels,
		arrayLayers = array_layers,
		samples     = {msaa_samples},
		tiling      = tiling,
		usage       = image_usage_flags,
		flags       = flags,
	}

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
		extent       = {**extent},
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
	extent: Extent_3D,
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
) -> Image_Id {
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
		extent       = {**extent},
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
	id: Image_Id,
	format: vk.Format,
	view_type: vk.ImageViewType = .D2,
	#any_int base_mip_level: u32 = 0,
	#any_int mip_levels: u32 = 1,
	#any_int base_array_layer: u32 = 0,
	#any_int array_layers: u32 = 1,
) -> Image_Id {
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
) -> Sampler_Id {
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

destroy_sampler :: proc(id: Sampler_Id) {
	sampler := sampler_meta(id)
	vk.DestroySampler(r_ctx.device, sampler, nil)
	_remove_sampler(id)
}

image_access_masks :: proc(access: Image_Access) -> (vk.PipelineStageFlags2, vk.AccessFlags2) {
	switch access {
	case .None:
		return {}, {}
	case .All_Writes:
		return {.ALL_COMMANDS}, {.MEMORY_WRITE}
	case .All_Reads_Writes:
		return {.ALL_COMMANDS}, {.MEMORY_READ, .MEMORY_WRITE}
	case .Compute_Shader_Read:
		return {.COMPUTE_SHADER}, {.SHADER_READ}
	case .Compute_Shader_Write:
		return {.COMPUTE_SHADER}, {.SHADER_WRITE}
	case .Compute_Shader_Read_Write:
		return {.COMPUTE_SHADER}, {.SHADER_READ, .SHADER_WRITE}
	case .All_Shader_Read:
		return {.ALL_COMMANDS}, {.SHADER_READ}
	case .Compute_Fragment_Shader_Read:
		return {.COMPUTE_SHADER, .FRAGMENT_SHADER}, {.SHADER_READ}
	case .Fragment_Shader_Read:
		return {.FRAGMENT_SHADER}, {.SHADER_READ}
	case .Color_Attachment_Read_Write:
		return {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
	case .Depth_Attachment_Read_Write:
		return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
	case .Transfer_Read:
		return {.ALL_TRANSFER}, {.TRANSFER_READ}
	case .Transfer_Write:
		return {.ALL_TRANSFER}, {.TRANSFER_WRITE}
	}

	unreachable()
}

image_layout_to_vk_layout :: proc(image_layout: Image_Layout) -> vk.ImageLayout {
    switch image_layout {
    case .Undefined:   return .UNDEFINED
    case .General:     return .GENERAL
    case .Present_Src: return .PRESENT_SRC_KHR
    }

    return .UNDEFINED
}

image_barrier :: proc(
	cmd: Command_Buffer,
	image_id: Image_Id,
	src_access: Image_Access,
	dst_access: Image_Access,
	new_layout: Image_Layout = .Undefined,
	range: Image_Subresource_Range = {},
) -> bool {
	src_stage_mask, src_access_mask := image_access_masks(src_access)
	dst_stage_mask, dst_access_mask := image_access_masks(dst_access)

	image := image_meta(image_id)

	vk_new_layout := image_layout_to_vk_layout(new_layout)
	current_layout := image.current_layout
    target_layout := current_layout

	if new_layout != .Undefined {
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

	if vk_new_layout != .UNDEFINED {
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
		oldLayout = image_layout_to_vk_layout(current_layout),
		newLayout = image_layout_to_vk_layout(target_layout),
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

	if vk_new_layout != .UNDEFINED {
		image.current_layout = target_layout
	}

	return true
}

transition_image :: proc(cmd: Command_Buffer, image: Image_Id, new_layout: Image_Layout) -> bool {
	return image_barrier(cmd, image, src_access = .All_Writes, dst_access = .All_Reads_Writes, new_layout = new_layout)
}

copy_image_to_image :: proc(cmd: Command_Buffer, src_id: Image_Id, dst_id: Image_Id, src_size: Offset_2D, dst_size: Offset_2D) {
	source := image_meta(src_id)
	destination := image_meta(dst_id)

	blit_region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		pNext = nil,
	}

	blit_region.srcOffsets[1].x = src_size.x
	blit_region.srcOffsets[1].y = src_size.y
	blit_region.srcOffsets[1].z = 1

	blit_region.dstOffsets[1].x = dst_size.x
	blit_region.dstOffsets[1].y = dst_size.y
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
		dstImageLayout = .GENERAL,
		srcImage       = source.image,
		srcImageLayout = .GENERAL,
		filter         = .LINEAR,
		regionCount    = 1,
		pRegions       = &blit_region,
	}

	vk.CmdBlitImage2(cmd, &blit_info)
}

destroy_image :: proc(id: Image_Id) {
	image := image_meta(id)

	vk.DestroyImageView(r_ctx.device, image.image_view, nil)

	if image.owns_image {
		vma.DestroyImage(r_ctx.allocator, image.image, image.allocation)
	}

	_remove_image(id)
}

create_descriptor_set_layout :: proc(
	bindings: []Descriptor_Binding,
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

is_image_descriptor_type :: proc(ty: vk.DescriptorType) -> bool {
	return ty == .STORAGE_IMAGE || ty == .SAMPLED_IMAGE || ty == .SAMPLER
}

is_sampler_descriptor_type :: proc(ty: vk.DescriptorType) -> bool {
	return ty == .SAMPLER
}

// TODO: This should not allocate.
write_descriptor_set :: proc(descriptor_set: vk.DescriptorSet, writes: []Descriptor_Write, loc := #caller_location) {
	// Collect writes in the convenient format into vk's.
	descriptor_writes: [dynamic]vk.WriteDescriptorSet
	image_infos: [dynamic]vk.DescriptorImageInfo
	buffer_infos: [dynamic]vk.DescriptorBufferInfo

	for write in writes {
		if is_image_descriptor_type(write.type) {
			assert(write.buffer == 0, "Descriptor write is an image type, but the buffer field was set.", loc = loc)

			if write.type == .SAMPLER {
                fmt.assertf(write.sampler != 0, "Descriptor write has a null sampler! array_index: %d", write.array_index, loc = loc)
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

// The deletion arena is implemented a bit differently to the one found
// in vkguide. Since Odin doesn't have convenient lambdas, and since Vulkan
// handles are (usually) all 64-bit pointers/handles, we can generalize an API
// that has similar ergonomics.
//
// The API usage is simpler: Just pass the handle instead of
// a lambda/procedure. If you allocated with VMA, you can also
// pass in the allocation.
//
// The deletion arena is now basically a (crappy) state machine.

vk_destroy_resource_by_handle :: proc(resource: Resource_Handle) {
	when false {
		log_normal("DEBUG: Destroy", resource.ty, "@", resource.caller_location, "-", resource.debug_info)
	}

	if resource_requires_allocation(resource.ty) {
		assert(resource.allocation != nil)
	}

	switch resource.ty {
	case .Bindless_Image:
		destroy_image(Image_Id(resource.handle))
	case .Bindless_Sampler:
		destroy_sampler(Sampler_Id(resource.handle))
	case .Vma_Buffer:
		vma.DestroyBuffer(r_ctx.allocator, cast(vk.Buffer)resource.handle, resource.allocation)
	case .Command_Pool:
		vk.DestroyCommandPool(r_ctx.device, cast(vk.CommandPool)resource.handle, nil)
	case .Descriptor_Pool:
		vk.DestroyDescriptorPool(r_ctx.device, cast(vk.DescriptorPool)resource.handle, nil)
	case .Descriptor_Set_Layout:
		vk.DestroyDescriptorSetLayout(r_ctx.device, cast(vk.DescriptorSetLayout)resource.handle, nil)
	case .Fence:
		vk.DestroyFence(r_ctx.device, cast(vk.Fence)resource.handle, nil)
	case .Image_View:
		vk.DestroyImageView(r_ctx.device, cast(vk.ImageView)resource.handle, nil)
	case .Pipeline:
		vk.DestroyPipeline(r_ctx.device, cast(vk.Pipeline)resource.handle, nil)
	case .Pipeline_Layout:
		vk.DestroyPipelineLayout(r_ctx.device, cast(vk.PipelineLayout)resource.handle, nil)
	case .Acceleration_Structure:
		vk.DestroyAccelerationStructureKHR(r_ctx.device, cast(vk.AccelerationStructureKHR)resource.handle, nil)
	case .Swapchain:
		vk.DestroySwapchainKHR(r_ctx.device, cast(vk.SwapchainKHR)resource.handle, nil)
    case .Surface:
		vk.DestroySurfaceKHR(r_ctx.instance, cast(vk.SurfaceKHR)resource.handle, nil)
    case .Semaphore:
        vk.DestroySemaphore(r_ctx.device, cast(vk.Semaphore)resource.handle, nil)
	}
}

resource_type_of_handle :: proc($T: typeid) -> Resource_Type {
	//odinfmt: disable
	return \
		.Vma_Buffer when T == vk.Buffer else
		.Bindless_Image when T == Image_Id else
		.Bindless_Sampler when T == Sampler_Id else
		.Image_View when T == vk.ImageView else
		.Command_Pool when T == vk.CommandPool else
		.Descriptor_Pool when T == vk.DescriptorPool else
		.Descriptor_Set_Layout when T == vk.DescriptorSetLayout else
		.Fence when T == vk.Fence else
		.Pipeline when T == vk.Pipeline else
		.Pipeline_Layout when T == vk.PipelineLayout else
		.Acceleration_Structure when T == vk.AccelerationStructureKHR else
		.Swapchain when T == vk.SwapchainKHR else
		.Surface when T == vk.SurfaceKHR else
		#panic("Handle type is not a valid resource")
	//odinfmt: enable
}

type_requires_allocation :: proc($T: typeid) -> bool {
	return T == vk.Buffer
	//odinfmt: enable
}

resource_requires_allocation :: proc(type: Resource_Type) -> bool {
	#partial switch type {
	case .Vma_Buffer:
		return true
	case:
		return false
	}
}

defer_destroy_resource :: proc(
	arena: ^Deletion_Queue,
	handle: u64,
	resource_type: Resource_Type,
	allocation: vma.Allocation = nil,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	if resource_requires_allocation(resource_type) {
		assert(allocation != nil, "Resource of this type requires an allocation to be passed in.", loc)
	}

	resource_handle := Resource_Handle {
		handle          = handle,
		ty              = resource_type,
		allocation      = allocation,
		debug_info      = debug,
		caller_location = loc,
	}

	append(&arena.queue, resource_handle)
}

defer_destroy_buffer :: proc(arena: ^Deletion_Queue, buffer: Buffer($T), debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)buffer.buffer, .Vma_Buffer, buffer.allocation)
}

defer_destroy_scratch :: proc(arena: ^Deletion_Queue, scratch: Scratch, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)scratch.buffer.buffer, .Vma_Buffer, scratch.buffer.allocation)
}

defer_destroy_image :: proc(arena: ^Deletion_Queue, id: Image_Id, debug: string = "UNKNOWN", loc := #caller_location) {
	// Keep the slot alive until the owning arena is safe to flush. destroy_image
	// handles view-only IDs and releases the slot after destroying the resource.
	defer_destroy_resource(arena, u64(id), .Bindless_Image, nil, debug, loc)
}

defer_destroy_sampler :: proc(arena: ^Deletion_Queue, id: Sampler_Id, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, u64(id), .Bindless_Sampler, nil, debug, loc)
}

defer_destroy_pipeline :: proc(arena: ^Deletion_Queue, pipeline: Pipeline, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)pipeline.pipeline, .Pipeline, nil, debug, loc)
	defer_destroy_resource(arena, transmute(u64)pipeline.layout, .Pipeline_Layout, nil, debug, loc)
}

defer_destroy_surface :: proc(arena: ^Deletion_Queue, surface: vk.SurfaceKHR, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)surface, .Surface, nil, debug, loc)
}

defer_destroy_semaphore :: proc(arena: ^Deletion_Queue, sema: Semaphore, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)sema, .Semaphore, nil, debug, loc)
}

defer_destroy_vk_command_pool :: proc(arena: ^Deletion_Queue, handle: vk.CommandPool, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Command_Pool, nil, debug, loc)
}

defer_destroy_vk_descriptor_pool :: proc(
	arena: ^Deletion_Queue,
	handle: vk.DescriptorPool,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .Descriptor_Pool, nil, debug, loc)
}

defer_destroy_vk_descriptor_set_layout :: proc(
	arena: ^Deletion_Queue,
	handle: vk.DescriptorSetLayout,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .Descriptor_Set_Layout, nil, debug, loc)
}

defer_destroy_vk_fence :: proc(arena: ^Deletion_Queue, handle: vk.Fence, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Fence, nil, debug, loc)
}

defer_destroy_vk_pipeline :: proc(arena: ^Deletion_Queue, handle: vk.Pipeline, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Pipeline, nil, debug, loc)
}

defer_destroy_vk_pipeline_layout :: proc(
	arena: ^Deletion_Queue,
	handle: vk.PipelineLayout,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .Pipeline_Layout, nil, debug, loc)
}

defer_destroy_vk_swapchain :: proc(arena: ^Deletion_Queue, handle: vk.SwapchainKHR, debug := "", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Swapchain, nil, debug, loc)
}

defer_destroy_vk_semaphore :: proc(arena: ^Deletion_Queue, sema: vk.Semaphore, debug := "", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)sema, .Semaphore, nil, debug, loc)
}

defer_destroy :: proc {
	defer_destroy_buffer,
	defer_destroy_scratch,
	defer_destroy_image,
	defer_destroy_sampler,
	defer_destroy_pipeline,
	defer_destroy_surface,
	defer_destroy_semaphore,

	// Vulkan-specific handle overloads
	defer_destroy_vk_command_pool,
	defer_destroy_vk_descriptor_pool,
	defer_destroy_vk_descriptor_set_layout,
	defer_destroy_vk_fence,
	defer_destroy_vk_pipeline,
	defer_destroy_vk_pipeline_layout,
	defer_destroy_vk_swapchain,
	defer_destroy_vk_semaphore,
}

flush_vk_arena :: proc(arena: ^Deletion_Queue) {
	#reverse for &resource in arena.queue {
		vk_destroy_resource_by_handle(resource)
	}

	clear(&arena.queue)
}

delete_vk_arena :: proc(arena: Deletion_Queue) {
	delete(arena.queue)
}

object_type_of_handle :: proc($T: typeid) -> vk.ObjectType {
	//odinfmt: disable
	return \
		.BUFFER when T == vk.Buffer else
		.IMAGE when T == vk.Image else
		.IMAGE_VIEW when T == vk.ImageView else
		.COMMAND_POOL when T == vk.CommandPool else
		.DESCRIPTOR_POOL when T == vk.DescriptorPool else
		.DESCRIPTOR_SET_LAYOUT when T == vk.DescriptorSetLayout else
		.DESCRIPTOR_SET when T == vk.DescriptorSet else
		.FENCE when T == vk.Fence else
		.PIPELINE when T == vk.Pipeline else
		.PIPELINE_LAYOUT when T == vk.PipelineLayout else
		.SAMPLER when T == vk.Sampler else
		.SEMAPHORE when T == vk.Semaphore else
		#panic("Handle type is not a valid resource")
	//odinfmt: enable
}

debug_set_object_name :: proc(handle: $T/u64, object_name: cstring) {
	if r_ctx.debug_messenger == 0 do return

	object_type := object_type_of_handle(T)

	name_info := vk.DebugUtilsObjectNameInfoEXT {
		sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
		objectType   = object_type,
		pObjectName  = object_name,
		objectHandle = u64(handle),
	}

	vk.SetDebugUtilsObjectNameEXT(r_ctx.device, &name_info)
}

cmd_bind_pipeline_value :: #force_inline proc(cmd: Command_Buffer, pipeline: Pipeline) {
	vk.CmdBindDescriptorSets(cmd, pipeline.bind_point, pipeline.layout, 0, 1, &r_ctx.bindless_system.descriptor_set, 0, nil)
	vk.CmdBindPipeline(cmd, pipeline.bind_point, pipeline.pipeline)

	r_ctx.current_pipeline = pipeline
}

cmd_bind_pipeline_ptr :: #force_inline proc(cmd: Command_Buffer, pipeline: ^Pipeline) {
	cmd_bind_pipeline_value(cmd, pipeline^)
}

cmd_bind_pipeline :: proc {
	cmd_bind_pipeline_value,
	cmd_bind_pipeline_ptr,
}


cmd_push_constants :: #force_inline proc(cmd: Command_Buffer, push_constants: $T, offset: u32 = 0) {
	push_constants := push_constants
	vk.CmdPushConstants(cmd, r_ctx.current_pipeline.layout, r_ctx.current_pipeline.stage_flags, 0, size_of(T), &push_constants)
}

cmd_bind_index_buffer :: #force_inline proc(
	cmd: Command_Buffer,
	buffer: vk.Buffer,
	offset: vk.DeviceSize = 0,
	index_type: vk.IndexType = .UINT32,
) {
	vk.CmdBindIndexBuffer(cmd, buffer, offset, index_type)
}

cmd_draw :: #force_inline proc(
	cmd: Command_Buffer,
	vertex_count: u32,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDraw(cmd, vertex_count, instance_count, first_vertex, first_instance)
}

cmd_draw_indexed :: #force_inline proc(
	cmd: Command_Buffer,
	index_count: u32,
	instance_count: u32 = 1,
	first_index: u32 = 0,
	vertex_offset: i32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, first_instance)
}

cmd_draw_indirect :: #force_inline proc(
	cmd: Command_Buffer,
	buffer: Buffer($T),
    draw_count := 0,
    offset := 0,
) {
    stride := size_of(T)
    vk.CmdDrawIndirect(cmd, buffer.buffer, offset, draw_count, auto_cast stride)
}

cmd_dispatch :: #force_inline proc(cmd: Command_Buffer, group_count_x: u32 = 1, group_count_y: u32 = 1, group_count_z: u32 = 1) {
	vk.CmdDispatch(cmd, group_count_x, group_count_y, group_count_z)
}

cmd_begin_rendering :: proc(
	cmd: Command_Buffer,
	area: Extent_2D,
	color_attachment: ^Rendering_Attachment_Info = nil,
	depth_attachment: ^Rendering_Attachment_Info = nil,
) {
	vk_color_attachment: vk.RenderingAttachmentInfo
    has_color := false
	vk_depth_attachment: vk.RenderingAttachmentInfo
    has_depth := false

	if color_attachment != nil {
		color_attachment_meta := image_meta(color_attachment.view)
        vk_color_attachment = vk.RenderingAttachmentInfo {
            sType              = .RENDERING_ATTACHMENT_INFO,
            imageView          = color_attachment_meta.image_view,
            imageLayout        = .GENERAL,
            loadOp             = color_attachment.clear_value != nil ? .CLEAR : .LOAD,
            storeOp            = .STORE,
            clearValue         = color_attachment.clear_value != nil ? color_attachment.clear_value^ : {},
        }

        has_color = true
	}

	if depth_attachment != nil {
		depth_attachment_meta := image_meta(depth_attachment.view)
        vk_depth_attachment = vk.RenderingAttachmentInfo {
            sType              = .RENDERING_ATTACHMENT_INFO,
            imageView          = depth_attachment_meta.image_view,
            imageLayout        = .GENERAL,
            loadOp             = depth_attachment.clear_value != nil ? .CLEAR : .LOAD,
            storeOp            = .STORE,
            clearValue         = depth_attachment.clear_value != nil ? depth_attachment.clear_value^ : {},
        }

        has_depth = true
	}

	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		layerCount = 1,
		renderArea = {extent = {**area}},
        pColorAttachments = has_color ? &vk_color_attachment : nil,
		colorAttachmentCount = has_color ? 1 : 0,
        pDepthAttachment = has_depth ? &vk_depth_attachment : nil,
	}

	cmd_set_viewport(cmd, {width = f32(area.x), height = f32(area.y), maxDepth = 1.0})
	cmd_set_scissor(cmd, {extent = area})

	vk.CmdBeginRendering(cmd, &render_info)
}

cmd_end_rendering :: #force_inline proc(cmd: Command_Buffer) {
	vk.CmdEndRendering(cmd)
}

cmd_begin_label :: proc(cmd: Command_Buffer, label: cstring, color: [4]f32 = 1) {
	if r_ctx.debug_messenger != 0 {
		vk_label := vk.DebugUtilsLabelEXT {
			sType      = .DEBUG_UTILS_LABEL_EXT,
			pLabelName = label,
			color      = color,
		}

		vk.CmdBeginDebugUtilsLabelEXT(cmd, &vk_label)
	}
}

cmd_end_label :: #force_inline proc(cmd: Command_Buffer) {
	if r_ctx.debug_messenger != 0 {
		vk.CmdEndDebugUtilsLabelEXT(cmd)
	}
}

cmd_copy_buffer_to_image :: proc(cmd: Command_Buffer, src_buffer: Buffer($T), dst_image_id: Image_Id, buffer_copies: []vk.BufferImageCopy) {
	dst_image := image_meta(dst_image_id)
	vk.CmdCopyBufferToImage(
		cmd,
		src_buffer.buffer,
		dst_image.image,
		.GENERAL,
		u32(len(buffer_copies)),
		raw_data(buffer_copies),
	)
}

cmd_clear_color_image :: proc(
	cmd: Command_Buffer,
	image_id: Image_Id,
	clear_value: ^vk.ClearColorValue,
	ranges: []vk.ImageSubresourceRange,
) {
	image := image_meta(image_id)
	vk.CmdClearColorImage(cmd, image.image, .GENERAL, clear_value, u32(len(ranges)), raw_data(ranges))
}

cmd_resolve_image :: proc(cmd: Command_Buffer, src_image_id: Image_Id, dst_image_id: Image_Id, resolves: []vk.ImageResolve) {
	src_image := image_meta(src_image_id)
	dst_image := image_meta(dst_image_id)

	vk.CmdResolveImage(
		cmd,
		src_image.image,
		.GENERAL,
		dst_image.image,
		.GENERAL,
		u32(len(resolves)),
		raw_data(resolves),
	)
}

cmd_copy_buffer :: proc(cmd: Command_Buffer, src_buffer: Buffer($T), dst_buffer: Buffer($U), length := 0, offset := 0) {
    length := length

    if length == 0 {
        length = int(src_buffer.count)
    }

    size := size_of(T) * length

    region := vk.BufferCopy {
        dstOffset = vk.DeviceSize(offset),
        srcOffset = 0,
        size      = vk.DeviceSize(size),
    }

	vk.CmdCopyBuffer(
		cmd,
		src_buffer.buffer,
		dst_buffer.buffer,
        1,
        &region,
	)
}

cmd_set_viewport :: proc(cmd: Command_Buffer, viewport: vk.Viewport) {
    viewport := viewport
    vk.CmdSetViewport(cmd, 0, 1, &viewport)
}

cmd_set_scissor :: proc(cmd: Command_Buffer, scissor: Rect_2D) {
    scissor := vk.Rect2D{
        {**scissor.offset},
        {**scissor.extent},
    }

	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

vk_buffer_flags :: proc(alloc_flags: Buffer_Memory_Flags) -> (vk.BufferUsageFlags, vma.AllocationCreateFlags) {
	usage_flags := vk.BufferUsageFlags {
		.INDEX_BUFFER,
		.TRANSFER_SRC,
		.TRANSFER_DST,
		.STORAGE_BUFFER,
		.INDIRECT_BUFFER,
		.SHADER_DEVICE_ADDRESS,
	}
	vma_alloc_flags := vma.AllocationCreateFlags{}

	// TODO: Query.
	if true {
		usage_flags |= {.ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR, .ACCELERATION_STRUCTURE_STORAGE_KHR}
	}

	if .Host_Sequential_Write in alloc_flags {
		vma_alloc_flags |= {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE}
	}
	if .Host_Random in alloc_flags {
		vma_alloc_flags |= {.MAPPED, .HOST_ACCESS_RANDOM}
	}

	return usage_flags, vma_alloc_flags
}

// This allocates on the GPU, make sure to call `destroy_buffer` or add to deletion queue when you are finished with the buffer.
create_buffer :: proc(
	$T: typeid,
	#any_int size: vk.DeviceSize = 1,
	alloc_flags: Buffer_Memory_Flag = {},
	name: cstring = nil,
	loc := #caller_location,
) -> Buffer(T) {
	alloc_size := cast(vk.DeviceSize)(size_of(T) * size)

	vk_usage_flags, vma_create_flags := vk_buffer_flags({alloc_flags})

	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = alloc_size,
		usage = vk_usage_flags,
	}

	vma_alloc_info := vma.AllocationCreateInfo {
		usage = .AUTO_PREFER_DEVICE,
		flags = vma_create_flags,
	}

	new_buffer: Buffer(T)
	new_buffer.count = u64(size)
	vk_check(
		vma.CreateBuffer(r_ctx.allocator, &buffer_info, &vma_alloc_info, &new_buffer.buffer, &new_buffer.allocation, &new_buffer.info),
		loc,
	)

	new_buffer.ptr.address = get_buffer_device_address(new_buffer)

	when ODIN_DEBUG {
		if name == nil {
			debug_set_object_name(new_buffer.buffer, fmt.ctprint(loc))
		} else {
			debug_set_object_name(new_buffer.buffer, name)
		}
	}

	return new_buffer
}

destroy_buffer :: proc(allocated_buffer: ^Buffer($T)) {
	vma.DestroyBuffer(r_ctx.allocator, allocated_buffer.buffer, allocated_buffer.allocation)
}

slice_from_ptr :: proc(data: Ptr($T), count: u64) -> Slice(T) {
	return {data = data, count = count}
}

slice_from_buffer :: proc(buffer: Buffer($T), first: u64 = 0, count: Maybe(u64) = nil) -> Slice(T) {
	assert(buffer.ptr.address != 0, "GPU slices require a device-addressable buffer")
	total_count := buffer.count
	assert(first <= total_count, "GPU slice starts outside its buffer")

	slice_count := total_count - first
	if requested_count, ok := count.?; ok {
		assert(requested_count <= total_count - first, "GPU slice extends outside its buffer")
		slice_count = requested_count
	}

	return {data = {address = buffer.ptr.address + vk.DeviceAddress(first) * vk.DeviceAddress(size_of(T))}, count = slice_count}
}

slice :: proc {
	slice_from_ptr,
	slice_from_buffer,
}

get_buffer_device_address :: proc(buffer: Buffer($T)) -> vk.DeviceAddress {
	device_address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = buffer.buffer,
	}

	return vk.GetBufferDeviceAddress(r_ctx.device, &device_address_info)
}

// Writes to the buffer with the input data at offset.
write_buffer :: proc(buffer: ^Buffer($Z), in_data: ^$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	size := size_of(T)
	assert(buffer.info.size >= vk.DeviceSize(u64(size) + u64(offset)), "The size of the data and offset is larger than the buffer", loc)

	data := cast([^]u8)buffer.info.pMappedData

	assert(data != nil, "Buffer is not mapped.")

	mem.copy(data[offset:], in_data, size)
}

// Writes to the buffer with the input slice at offset.
write_buffer_slice :: proc(buffer: ^Buffer($Z), in_data: []$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	size := size_of(T) * len(in_data)
	assert(buffer.info.size >= vk.DeviceSize(u64(size) + u64(offset)), "The size of the slice and offset is larger than the buffer", loc)

	data := cast([^]u8)buffer.info.pMappedData

	assert(data != nil, "Buffer is not mapped.")
	assert(raw_data(in_data) != nil)

	mem.copy(data[offset:], raw_data(in_data), size)
}

_buffer_access_masks :: proc(access: Buffer_Access) -> (vk.PipelineStageFlags2, vk.AccessFlags2) {
	switch access {
	case .None:
		return {}, {}
	case .All_Reads:
		return {.ALL_COMMANDS}, {.MEMORY_READ}
	case .All_Writes:
		return {.ALL_COMMANDS}, {.MEMORY_WRITE}
	case .All_Reads_Writes:
		return {.ALL_COMMANDS}, {.MEMORY_READ, .MEMORY_WRITE}
	case .Compute_Shader_Read:
		return {.COMPUTE_SHADER}, {.SHADER_READ}
	case .Compute_Shader_Write:
		return {.COMPUTE_SHADER}, {.SHADER_WRITE}
	case .Vertex_Shader_Read:
		return {.VERTEX_SHADER}, {.SHADER_READ}
	case .Fragment_Shader_Read:
		return {.FRAGMENT_SHADER}, {.SHADER_READ}
	case .Transfer_Read:
		return {.ALL_TRANSFER}, {.TRANSFER_READ}
	case .Transfer_Write:
		return {.ALL_TRANSFER}, {.TRANSFER_WRITE}
	case .Acceleration_Structure_Build_Read:
		return {.ACCELERATION_STRUCTURE_BUILD_KHR}, {.ACCELERATION_STRUCTURE_READ_KHR}
	case .Acceleration_Structure_Build_Write:
		return {.ACCELERATION_STRUCTURE_BUILD_KHR}, {.ACCELERATION_STRUCTURE_WRITE_KHR}
	case .Acceleration_Structure_Read:
		return {.ALL_COMMANDS}, {.ACCELERATION_STRUCTURE_READ_KHR}
	}

	unreachable()
}

buffer_barrier :: proc(
	cmd: Command_Buffer,
	buffer: Buffer($T),
	src_access: Buffer_Access,
	dst_access: Buffer_Access,
	offset: u64 = 0,
	size: u64 = 0,
) {
	src_stage_mask, src_access_mask := _buffer_access_masks(src_access)
	dst_stage_mask, dst_access_mask := _buffer_access_masks(dst_access)

	buffer_size := u64(buffer.info.size)
	assert(offset <= buffer_size, "Buffer barrier offset exceeds the buffer size")
	assert(size == 0 || size <= buffer_size - offset, "Buffer barrier range exceeds the buffer size")

	vk_size := vk.DeviceSize(size)
	if vk_size == 0 {
		vk_size = vk.DeviceSize(vk.WHOLE_SIZE)
	}

	barrier := vk.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		pNext               = nil,
		srcStageMask        = src_stage_mask,
		srcAccessMask       = src_access_mask,
		dstStageMask        = dst_stage_mask,
		dstAccessMask       = dst_access_mask,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = buffer.buffer,
		offset              = vk.DeviceSize(offset),
		size                = vk_size,
	}

	dep_info := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		pNext                    = nil,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

create_scratch :: proc(#any_int size: vk.DeviceSize, name: cstring = nil, loc := #caller_location) -> Scratch {
	return {buffer = create_buffer(u8, size, .Host_Sequential_Write, name, loc)}
}

reset_scratch :: proc(scratch: ^Scratch) {
	scratch.current_offset = 0
}

write_scratch :: proc(scratch: ^Scratch, in_data: ^$T, loc := #caller_location) -> Ptr(T) {
	return write_scratch_slice(buffer, slice.from_ptr(in_data, 1), loc).data
}

write_scratch_slice :: proc(scratch: ^Scratch, in_data: []$T, loc := #caller_location) -> Slice(T) {
	size := size_of(T) * len(in_data)

	offset := vk.DeviceSize(mem.align_forward_uint(uint(scratch.current_offset), uint(max(align_of(T), 16))))

	assert(uint(offset) + uint(size) <= uint(scratch.buffer.info.size), "Scratch buffer overflow", loc)
	scratch.current_offset = offset + vk.DeviceSize(size)

	write_buffer_slice(&scratch.buffer, in_data, offset, loc)
	return {data = {address = scratch.buffer.ptr.address + vk.DeviceAddress(offset)}, count = u64(len(in_data))}
}

destroy_scratch :: proc(scratch: ^Scratch) {
	destroy_buffer(&scratch.buffer)
}

init_bindless_descriptors :: proc() {
	bindless_system := &r_ctx.bindless_system

	bindless_system.descriptor_layout = create_descriptor_set_layout(
		{
			{binding = BINDLESS_SAMPLED_IMAGES, type = .SAMPLED_IMAGE, count = MAX_BINDLESS_IMAGES},
			{binding = BINDLESS_SAMPLERS,       type = .SAMPLER,       count = MAX_BINDLESS_SAMPLERS},
			{binding = BINDLESS_STORAGE_IMAGES, type = .STORAGE_IMAGE, count = MAX_BINDLESS_IMAGES},
		},
		{.UPDATE_AFTER_BIND_POOL},
		{.VERTEX, .FRAGMENT, .COMPUTE},
	)

	bindless_system.pool = create_pool(
		1,
		{
			{type = .SAMPLER,       descriptorCount = MAX_BINDLESS_SAMPLERS},
			{type = .SAMPLED_IMAGE, descriptorCount = MAX_BINDLESS_IMAGES},
			{type = .STORAGE_IMAGE, descriptorCount = MAX_BINDLESS_IMAGES},
		},
		{.UPDATE_AFTER_BIND},
		"Bindless Descriptor Pool",
	)
	bindless_system.descriptor_set = allocate_descriptor_set(bindless_system.pool, bindless_system.descriptor_layout)

    // burn one
    dynamic_pool.append(&bindless_system.images,   {})
    dynamic_pool.append(&bindless_system.samplers, {})
}

shutdown_bindless_descriptors :: proc() {
	dynamic_pool.destroy(r_ctx.bindless_system.images)
	dynamic_pool.destroy(r_ctx.bindless_system.samplers)
    vk.DestroyDescriptorSetLayout(r_ctx.device, r_ctx.bindless_system.descriptor_layout, nil)
    vk.DestroyDescriptorPool(r_ctx.device, r_ctx.bindless_system.pool, nil)
	r_ctx.bindless_system = {}
}

image_meta :: proc(id: Image_Id) -> ^Image {
	return dynamic_pool.get(r_ctx.bindless_system.images, id)
}

sampler_meta :: proc(id: Sampler_Id) -> vk.Sampler {
	return dynamic_pool.get(r_ctx.bindless_system.samplers, id)^
}

add_image_impl :: proc(image: Image) -> Image_Id {
	bindless_system := &r_ctx.bindless_system

	// assert(.STORAGE in image.usage || .SAMPLED in image.usage)
    image_id := dynamic_pool.append(&bindless_system.images, image)
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

    assert(image_id != 0)

	return image_id
}

add_image_with_view_impl :: proc(image: Image, view: vk.ImageView) -> Image_Id {
	image := image
	image.image_view = view
	image.owns_image = false
	return add_image_impl(image)
}

add_sampler :: proc(sampler: vk.Sampler) -> Sampler_Id {
	bindless_system := &r_ctx.bindless_system

    sampler_id := dynamic_pool.append(&bindless_system.samplers, sampler)
	assert(u32(sampler_id) < MAX_BINDLESS_SAMPLERS, "bindless sampler slots exhausted")

	write_descriptor_set(
		bindless_system.descriptor_set,
		{{binding = BINDLESS_SAMPLERS, type = .SAMPLER, sampler = sampler, array_index = u32(sampler_id)}},
	)

    assert(sampler_id != 0)

	return sampler_id
}

_remove_image :: proc(handle: Image_Id) {
    dynamic_pool.remove(&r_ctx.bindless_system.images, handle)
}

_remove_sampler :: proc(handle: Sampler_Id) {
    dynamic_pool.remove(&r_ctx.bindless_system.samplers, handle)
}

_create_pipeline_layout :: proc(
	debug_name: cstring,
	descriptor_set_layout: ^vk.DescriptorSetLayout,
	push_constants_size: u32,
	stage_flags: vk.ShaderStageFlags = {.VERTEX, .FRAGMENT},
	loc := #caller_location,
) -> (
	pipeline_layout: vk.PipelineLayout,
) {
	buffer_range := vk.PushConstantRange {
		offset     = 0,
		size       = push_constants_size,
		stageFlags = stage_flags,
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	if push_constants_size > 0 {
		pipeline_layout_info.pPushConstantRanges = &buffer_range
		pipeline_layout_info.pushConstantRangeCount = 1
	}
	pipeline_layout_info.pSetLayouts = descriptor_set_layout
	pipeline_layout_info.setLayoutCount = descriptor_set_layout != nil ? 1 : 0

	vk_check(vk.CreatePipelineLayout(r_ctx.device, &pipeline_layout_info, nil, &pipeline_layout))

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(pipeline_layout, fmt.ctprint(loc))
		} else {
			debug_set_object_name(pipeline_layout, debug_name)
		}
	}

	return
}

create_graphics_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	$push_constants: typeid,
	desc: Graphics_Pipeline_Desc = {},
	loc := #caller_location,
) -> Pipeline {
	return create_pipeline_from_desc(name, shader, desc, size_of(push_constants), loc)
}

create_compute_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	$push_constants: typeid,
	entry: cstring = nil,
	loc := #caller_location,
) -> Pipeline {
	return create_pipeline_from_desc(name, shader, Compute_Pipeline_Desc{entry = entry}, size_of(push_constants), loc)
}

create_pipeline_from_desc :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
	switch d in desc {
	case Graphics_Pipeline_Desc:
		return _create_graphics_pipeline(name, shader, d, push_constants_size, loc)
	case Compute_Pipeline_Desc:
		return _create_compute_pipeline(name, shader, d, push_constants_size, loc)
	}
	panic("Empty pipeline desc", loc)
}

destroy_pipeline :: proc(pipeline: Pipeline) {
	if pipeline.pipeline != 0 {
		vk.DestroyPipeline(r_ctx.device, pipeline.pipeline, nil)
	}
	if pipeline.layout != 0 {
		vk.DestroyPipelineLayout(r_ctx.device, pipeline.layout, nil)
	}
}

_create_graphics_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Graphics_Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
    desc := desc

	stage_flags := vk.ShaderStageFlags{.VERTEX, .FRAGMENT}
	pipeline_layout := _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants_size, stage_flags, loc = loc)

	vertex_entry := desc.vertex_entry != nil ? desc.vertex_entry : DEFAULT_VERTEX_ENTRY
	fragment_entry := desc.fragment_entry != nil ? desc.fragment_entry : DEFAULT_FRAGMENT_ENTRY

	topology: vk.PrimitiveTopology
	switch desc.topology {
	case .Triangle_List:
		topology = .TRIANGLE_LIST
	case .Triangle_Strip:
		topology = .TRIANGLE_STRIP
	case .Line_List:
		topology = .LINE_LIST
	}

    dst_color_blend_factor: vk.BlendFactor
	switch desc.blend_mode {
	case .None:
	case .Additive:
		dst_color_blend_factor = .ONE
	case .Alpha:
		dst_color_blend_factor = .ONE_MINUS_SRC_ALPHA
	}

    shader_stages := make([dynamic]vk.PipelineShaderStageCreateInfo, context.temp_allocator)

    append(&shader_stages, {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.VERTEX},
        module = shader,
        pName  = vertex_entry,
    })

	if !desc.depth_only {
        append(&shader_stages, {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.FRAGMENT},
            module = shader,
            pName  = fragment_entry,
        })
    }

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,

		pNext               = &vk.PipelineRenderingCreateInfo {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            colorAttachmentCount = desc.color_format != .UNDEFINED ? 1 : 0,
            pColorAttachmentFormats = &desc.color_format,
            depthAttachmentFormat = desc.depth.format
        },

		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
            sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        },

		pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = topology,
        },

		pViewportState = &vk.PipelineViewportStateCreateInfo {
            sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount = 1,
            scissorCount  = 1,
        },

		pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
            sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            polygonMode = desc.polygon_mode,
            lineWidth = 1, // TODO: expose?
            cullMode = desc.cull_mode,
            frontFace = desc.front_face,
            depthClampEnable = b32(desc.depth_clamp),
        },

		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
            sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            sampleShadingEnable = false,
            rasterizationSamples = {desc.msaa_sample_count},
            minSampleShading = 1.0,
            pSampleMask = nil,
            alphaToCoverageEnable = desc.msaa_sample_count != ._1,
            alphaToOneEnable = false,
        },

		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            logicOpEnable   = false,
            logicOp         = .COPY,
            attachmentCount = 1,
            pAttachments    = &vk.PipelineColorBlendAttachmentState {
                colorWriteMask = {.R, .G, .B, .A},
                blendEnable = desc.blend_mode != .None,
                srcColorBlendFactor = .SRC_ALPHA,
                dstColorBlendFactor = dst_color_blend_factor,
                colorBlendOp = .ADD,
                srcAlphaBlendFactor = .ONE,
                dstAlphaBlendFactor = .ZERO,
                alphaBlendOp = .ADD,
            },
        },

		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
            sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable = desc.depth.format != .UNDEFINED,
            depthWriteEnable = desc.depth.write_enabled,
            depthCompareOp = desc.depth.compare_op,
            minDepthBounds = 0.0,
            maxDepthBounds = 1.0,
        },

		pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
            sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            pDynamicStates    = raw_data([]vk.DynamicState{.VIEWPORT, .SCISSOR}),
            dynamicStateCount = 2,
        },

		pStages             = raw_data(shader_stages),
		stageCount          = u32(len(shader_stages)),
		layout              = pipeline_layout,
	}

	pipeline: vk.Pipeline
    vk_check(vk.CreateGraphicsPipelines(r_ctx.device, 0, 1, &pipeline_info, nil, &pipeline))

	debug_set_object_name(pipeline, name)

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = stage_flags, bind_point = .GRAPHICS}
}

_create_compute_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Compute_Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
	pipeline_layout := _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants_size, {.COMPUTE}, loc = loc)

	stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = shader,
		pName  = desc.entry != nil ? desc.entry : DEFAULT_COMPUTE_ENTRY,
	}

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = pipeline_layout,
		stage  = stage_info,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(r_ctx.device, 0, 1, &compute_pipeline_create_info, nil, &pipeline), loc)

	debug_set_object_name(pipeline, name)

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = {.COMPUTE}, bind_point = .COMPUTE}
}

// ====================================================================

load_shader_module_from_bytes :: proc(bytes: []u8) -> (vk.ShaderModule, bool) {
	// Byte length needs to be a multiple of 4
	if len(bytes) % 4 != 0 {
		return 0, false
	}

	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytes), // codeSize needs to be in bytes
		pCode    = raw_data(slice.reinterpret([]u32, bytes)), // code needs to be in 32bit words
	}

	module: vk.ShaderModule
	if vk.CreateShaderModule(r_ctx.device, &info, nil, &module) != .SUCCESS {
		return 0, false
	}

	return module, true
}

destroy_shader_module :: proc(module: vk.ShaderModule) {
	vk.DestroyShaderModule(r_ctx.device, module, nil)
}

r_rt_props: Raytracing_Props

query_raytracing_props :: proc() -> Raytracing_Props {
	as_props := vk.PhysicalDeviceAccelerationStructurePropertiesKHR {
		sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR,
	}

	props := vk.PhysicalDeviceProperties2 {
		sType = .PHYSICAL_DEVICE_PROPERTIES_2,
		pNext = &as_props,
	}

	vk.GetPhysicalDeviceProperties2(r_ctx.physical_device, &props)

	return {scratch_align = as_props.minAccelerationStructureScratchOffsetAlignment, max_instances = as_props.maxInstanceCount}
}

_build_accel :: proc(
	cmd: vk.CommandBuffer,
	type: vk.AccelerationStructureTypeKHR,
	geometry: ^vk.AccelerationStructureGeometryKHR,
	primitive_count: u32,
	loc := #caller_location,
) -> (
	accel: Raytracing_Accel,
	scratch: Buffer(u8),
) {
	accel.type = type

	build_info := vk.AccelerationStructureBuildGeometryInfoKHR {
		sType         = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
		type          = type,
		flags         = {.PREFER_FAST_TRACE},
		mode          = .BUILD,
		geometryCount = 1,
		pGeometries   = geometry,
	}

	// 1. Query sizes. dst + scratch addresses are ignored here; only the max
	//    primitive count matters.
	sizes := vk.AccelerationStructureBuildSizesInfoKHR {
		sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR,
	}
	prim_count := primitive_count
	vk.GetAccelerationStructureBuildSizesKHR(r_ctx.device, .DEVICE, &build_info, &prim_count, &sizes)

	// 2. Backing storage + the AS handle (kind is fixed here, matched at build).
	accel.buffer = create_buffer(u8, sizes.accelerationStructureSize, loc = loc)

	create_info := vk.AccelerationStructureCreateInfoKHR {
		sType  = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
		buffer = accel.buffer.buffer,
		offset = 0,
		size   = sizes.accelerationStructureSize,
		type   = type,
	}
	vk_check(vk.CreateAccelerationStructureKHR(r_ctx.device, &create_info, nil, &accel.accel), loc)

	// 3. Scratch buffer + device address, aligned to the AS limit.
	scratch = _create_scratch_buffer(sizes.buildScratchSize, loc)

	// 4. Record the build.
	build_info.dstAccelerationStructure = accel.accel
	build_info.scratchData.deviceAddress = scratch.ptr.address

	range := vk.AccelerationStructureBuildRangeInfoKHR {
		primitiveCount = primitive_count,
	}

	p_range := ([^]vk.AccelerationStructureBuildRangeInfoKHR)(&range)
	vk.CmdBuildAccelerationStructuresKHR(cmd, 1, &build_info, &p_range)

	// 5. Device address (BLAS -> instance ref, TLAS -> shader push constant).
	addr_info := vk.AccelerationStructureDeviceAddressInfoKHR {
		sType                 = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR,
		accelerationStructure = accel.accel,
	}
	accel.address = vk.GetAccelerationStructureDeviceAddressKHR(r_ctx.device, &addr_info)

	return
}

// One BLAS per mesh, built once at upload. Self-submitting: immediate_submit
// blocks on a fence, so the scratch is safe to free as soon as it returns.
build_blas :: proc(
    cmd: Command_Buffer,
	vertex_addr: vk.DeviceAddress,
	vertex_count: u32,
	vertex_stride: vk.DeviceSize,
	index_addr: vk.DeviceAddress,
	index_count: u32,
) -> (
	blas: Raytracing_Accel,
    scratch: Buffer(u8),
) {
	triangles := vk.AccelerationStructureGeometryTrianglesDataKHR {
		sType = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
		vertexFormat = .R32G32B32_SFLOAT,
		vertexData = {deviceAddress = vertex_addr},
		vertexStride = vertex_stride,
		maxVertex = vertex_count - 1,
		indexType = .UINT32,
		indexData = {deviceAddress = index_addr},
	}
	geo := vk.AccelerationStructureGeometryKHR {
		sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
		geometryType = .TRIANGLES,
		geometry = {triangles = triangles},
		flags = {.OPAQUE},
	}

    blas, scratch = _build_accel(cmd, .BOTTOM_LEVEL, &geo, index_count / 3)
	return
}

build_tlas :: proc(
	cmd: vk.CommandBuffer,
	instances: Buffer(vk.AccelerationStructureInstanceKHR),
	count: u32,
) -> (
	tlas: Raytracing_Accel,
	scratch: Buffer(u8),
) {
	geo := vk.AccelerationStructureGeometryKHR {
		sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
		geometryType = .INSTANCES,
		geometry = {
			instances = {sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR, data = {deviceAddress = instances.ptr.address}},
		},
	}
	tlas, scratch = _build_accel(cmd, .TOP_LEVEL, &geo, count)
	return
}

destroy_accel :: proc(accel: ^Raytracing_Accel) {
	vk.DestroyAccelerationStructureKHR(r_ctx.device, accel.accel, nil)
	destroy_buffer(&accel.buffer)
}

// Queue the buffer first, then the AS handle: the arena flushes in reverse, so the
// AS is destroyed before the backing buffer it sits on (required by the spec).
defer_destroy_accel :: proc(arena: ^Deletion_Queue, accel: Raytracing_Accel, loc := #caller_location) {
	if accel.accel == 0 do return // never built
	defer_destroy_buffer(arena, accel.buffer, loc = loc)
	defer_destroy_resource(arena, transmute(u64)accel.accel, .Acceleration_Structure, loc = loc)
}

_create_scratch_buffer :: proc(size: vk.DeviceSize, loc := #caller_location) -> Buffer(u8) {
	if r_rt_props.scratch_align == 0 {
		r_rt_props = query_raytracing_props()
	}

	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = size,
		usage = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
	}
	vma_info := vma.AllocationCreateInfo {
		usage = .AUTO,
	}

	out_buffer: Buffer(u8)
	vk_check(
		vma.CreateBufferWithAlignment(
			r_ctx.allocator,
			&buffer_info,
			&vma_info,
			vk.DeviceSize(r_rt_props.scratch_align),
			&out_buffer.buffer,
			&out_buffer.allocation,
			&out_buffer.info,
		),
		loc,
	)
	out_buffer.ptr.address = get_buffer_device_address(out_buffer)
	return out_buffer
}

create_swapchain :: proc(
    surface: vk.SurfaceKHR,
    present_mode: vk.PresentModeKHR,
    window_size: Extent_2D,
    max_frames_in_flight: int,
    _old_swapchain: vk.SwapchainKHR = {}
) -> Swapchain {
    swapchain: Swapchain
    swapchain.surface = surface
    swapchain.present_mode = present_mode
    swapchain.max_frames_in_flight = max_frames_in_flight
    swapchain._old_swapchain = _old_swapchain

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r_ctx.physical_device, swapchain.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, swapchain.surface, &format_count, nil)

	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r_ctx.physical_device, swapchain.surface, &format_count, raw_data(formats))

	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, swapchain.surface, &present_mode_count, nil)

	present_modes := make([]vk.PresentModeKHR, present_mode_count)
	defer delete(present_modes)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r_ctx.physical_device, swapchain.surface, &present_mode_count, raw_data(present_modes))

	surface_format := formats[0]

	for format in formats {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			surface_format = format
		}
	}

	extent := _choose_swap_extent(window_size, &capabilities)

	image_count := capabilities.minImageCount + 1

	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
		surface               = swapchain.surface,
		minImageCount         = image_count,
		imageFormat           = surface_format.format,
		imageColorSpace       = surface_format.colorSpace,
		imageExtent           = {**extent},
		imageArrayLayers      = 1,
		imageUsage            = {.COLOR_ATTACHMENT, .TRANSFER_DST, .SAMPLED},

		imageSharingMode      = .EXCLUSIVE,
		queueFamilyIndexCount = 0,
		pQueueFamilyIndices   = nil,
		preTransform          = capabilities.currentTransform,
		compositeAlpha        = {.OPAQUE},
		presentMode           = present_mode,
		clipped               = true,
		oldSwapchain          = _old_swapchain,
	}

    vk_swapchain: vk.SwapchainKHR
	vk_check(vk.CreateSwapchainKHR(r_ctx.device, &create_info, nil, &vk_swapchain))
	defer_destroy(&swapchain.arena, swapchain.swapchain)

    swapchain.swapchain = vk_swapchain
	swapchain.swapchain_image_format = surface_format.format
	swapchain.swapchain_extent = extent

	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, nil)
	vk_swapchain_images := make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(r_ctx.device, swapchain.swapchain, &image_count, raw_data(vk_swapchain_images))

	swapchain.swapchain_images = make([]Image_Id, image_count)
	for i in 0 ..< len(swapchain.swapchain_images) {
		swapchain.swapchain_images[i] = wrap_image(
			vk_swapchain_images[i],
			swapchain.swapchain_image_format,
			{**swapchain.swapchain_extent, 0},
			{.COLOR_ATTACHMENT, .TRANSFER_DST, .SAMPLED},
		)
		defer_destroy(&swapchain.arena, swapchain.swapchain_images[i])
	}

    // create sync structures
    swapchain.acquire_semaphores = make([]vk.Semaphore, swapchain.max_frames_in_flight)
    for i in 0 ..< swapchain.max_frames_in_flight {
        vk_check(vk.CreateSemaphore(r_ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &swapchain.acquire_semaphores[i]))
        defer_destroy(&swapchain.arena, swapchain.acquire_semaphores[i])
    }

    swapchain.present_semaphores = make([]vk.Semaphore, image_count)
    for i in 0 ..< image_count {
        vk_check(vk.CreateSemaphore(r_ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &swapchain.present_semaphores[i]))
        defer_destroy(&swapchain.arena, swapchain.present_semaphores[i])
    }

    return swapchain
}

swapchain_resize :: proc(swapchain: ^Swapchain, new_size: Extent_2D) {
    vk.DeviceWaitIdle(r_ctx.device)

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r_ctx.physical_device, swapchain.surface, &capabilities)

	extent := _choose_swap_extent(new_size, &capabilities)

    flush_vk_arena(&swapchain.arena)

    // destroy the _old_ old swapchain.
    if swapchain._old_swapchain != {} {
        vk.DestroySwapchainKHR(r_ctx.device, swapchain._old_swapchain, nil)
    }

    new_swapchain := create_swapchain(
       swapchain.surface,
       swapchain.present_mode,
       new_size,
       swapchain.max_frames_in_flight,
       _old_swapchain = swapchain.swapchain)

    swapchain^ = new_swapchain
}

swapchain_acquire_next_image :: proc(swapchain: ^Swapchain) -> (image: Image_Id) {
	result := vk.AcquireNextImageKHR(
		r_ctx.device,
		swapchain.swapchain,
		1_000_000_000,
		swapchain.acquire_semaphores[swapchain.frame_index],
		0,
		&swapchain.swapchain_image_index,
	)

    if result == .ERROR_OUT_OF_DATE_KHR {
        log.warn("Swapchain out of date!")
        return {}
    }

    if result != .SUBOPTIMAL_KHR {
        vk_check(result)
    }

    return swapchain.swapchain_images[swapchain.swapchain_image_index]
}

swapchain_destroy :: proc(swapchain: ^Swapchain) {
    flush_vk_arena(&swapchain.arena)
    vk.DestroySwapchainKHR(r_ctx.device, swapchain.swapchain, nil)
    if swapchain._old_swapchain != {} {
        vk.DestroySwapchainKHR(r_ctx.device, swapchain._old_swapchain, nil)
    }
}

_choose_swap_extent :: proc(desired: Extent_2D, capabilities: ^vk.SurfaceCapabilitiesKHR) -> Extent_2D {
	if (capabilities.currentExtent.width != max(u32)) {
		return {capabilities.currentExtent.width, capabilities.currentExtent.height}
	} else {
		actual_extent := desired
		actual_extent.x = clamp(actual_extent.x, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		actual_extent.y = clamp(actual_extent.y, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

		return actual_extent
	}
}

swapchain_present :: proc(swapchain: ^Swapchain, queue_kind: Queue_Kind) -> (out_of_date: bool) {
    present_info := vk.PresentInfoKHR {
        sType              = .PRESENT_INFO_KHR,
        pSwapchains        = &swapchain.swapchain,
        swapchainCount     = 1,
        pWaitSemaphores    = &swapchain.present_semaphores[swapchain.swapchain_image_index],
        waitSemaphoreCount = 1,
        pImageIndices      = &swapchain.swapchain_image_index,
    }

    // TODO: do we actually care?
    queue_present_result := vk.QueuePresentKHR(r_ctx.queues[queue_kind].queue, &present_info)
    swapchain.frame_index = (swapchain.frame_index + 1) % swapchain.max_frames_in_flight

    return
}

create_semaphore :: proc(init_value: u64, debug_name: cstring = nil, loc := #caller_location) -> Semaphore {
    sema: vk.Semaphore

    result := vk.CreateSemaphore(
        r_ctx.device,
        &vk.SemaphoreCreateInfo{
            sType = .SEMAPHORE_CREATE_INFO,
            pNext = &vk.SemaphoreTypeCreateInfo {
                sType = .SEMAPHORE_TYPE_CREATE_INFO,
                semaphoreType = .TIMELINE,
                initialValue = init_value,
            },
        },
        nil,
        &sema,
    )
    vk_check(result)

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(sema, fmt.ctprint(loc))
		} else {
			debug_set_object_name(sema, debug_name)
		}
	}

    return Semaphore(sema)
}

destroy_semaphore :: proc(sema: Semaphore) {
    vk.DestroySemaphore(r_ctx.device, vk.Semaphore(sema), nil)
}

wait_semaphore :: proc(sema_pair: Semaphore_Pair) {
    sema := vk.Semaphore(sema_pair.sema)
    wait_value := sema_pair.value

    if sema == {} {
        // just no-op
        return
    }

    vk.WaitSemaphores(r_ctx.device, &{
        sType = .SEMAPHORE_WAIT_INFO,
        pSemaphores = &sema,
        pValues = &wait_value,
        semaphoreCount = 1,
    }, max(u64))
}

get_semaphore_value :: proc(sema: Semaphore) -> u64 {
    value: u64
    vk.GetSemaphoreCounterValue(r_ctx.device, vk.Semaphore(sema), &value)

    return value
}

wait_idle :: proc() {
    vk_check(vk.DeviceWaitIdle(r_ctx.device))
}
