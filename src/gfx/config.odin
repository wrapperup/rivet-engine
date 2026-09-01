package gfx

import vk "vendor:vulkan"

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
	sType                  = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	pNext                  = &REQUIRED_VK_13_FEATURES,
	bufferDeviceAddress         = true,
	descriptorIndexing          = true,
	storagePushConstant8        = true,
	shaderInt8                  = true,
	runtimeDescriptorArray      = true,
	scalarBlockLayout           = true,
	vulkanMemoryModel           = true,
	vulkanMemoryModelDeviceScope = true,
	timelineSemaphore           = true,
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

// Number of frames to provide in flight.
FRAME_OVERLAP :: 2
