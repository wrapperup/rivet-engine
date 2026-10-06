package gfx

import "base:runtime"
import vma "deps:odin-vma"
import vk "vendor:vulkan"

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

ResourceArena :: struct {
	resource_arena: [dynamic]ResourceHandle,
}

ResourceHandle :: struct {
	ty:              ResourceType,
	handle:          u64,
	allocation:      vma.Allocation,
	debug_info:      string,
	caller_location: runtime.Source_Code_Location,
}

ResourceType :: enum {
	BindlessImage,
	BindlessSampler,
	VmaBuffer,
	CommandPool,
	DescriptorPool,
	DescriptorSetLayout,
	Fence,
	ImageView,
	Pipeline,
	PipelineLayout,
	AccelerationStructure,
	Swapchain,
}

vk_destroy_resource_by_handle :: proc(resource: ResourceHandle) {
	when false {
		log_normal("DEBUG: Destroy", resource.ty, "@", resource.caller_location, "-", resource.debug_info)
	}

	if resource_requires_allocation(resource.ty) {
		assert(resource.allocation != nil)
	}

	switch resource.ty {
	case .BindlessImage:
		destroy_image(ImageId(resource.handle))
	case .BindlessSampler:
		destroy_sampler(SamplerId(resource.handle))
	case .VmaBuffer:
		vma.DestroyBuffer(r_ctx.allocator, cast(vk.Buffer)resource.handle, resource.allocation)
	case .CommandPool:
		vk.DestroyCommandPool(r_ctx.device, cast(vk.CommandPool)resource.handle, nil)
	case .DescriptorPool:
		vk.DestroyDescriptorPool(r_ctx.device, cast(vk.DescriptorPool)resource.handle, nil)
	case .DescriptorSetLayout:
		vk.DestroyDescriptorSetLayout(r_ctx.device, cast(vk.DescriptorSetLayout)resource.handle, nil)
	case .Fence:
		vk.DestroyFence(r_ctx.device, cast(vk.Fence)resource.handle, nil)
	case .ImageView:
		vk.DestroyImageView(r_ctx.device, cast(vk.ImageView)resource.handle, nil)
	case .Pipeline:
		vk.DestroyPipeline(r_ctx.device, cast(vk.Pipeline)resource.handle, nil)
	case .PipelineLayout:
		vk.DestroyPipelineLayout(r_ctx.device, cast(vk.PipelineLayout)resource.handle, nil)
	case .AccelerationStructure:
		vk.DestroyAccelerationStructureKHR(r_ctx.device, cast(vk.AccelerationStructureKHR)resource.handle, nil)
	case .Swapchain:
		vk.DestroySwapchainKHR(r_ctx.device, cast(vk.SwapchainKHR)resource.handle, nil)
	}
}

resource_type_of_handle :: proc($T: typeid) -> ResourceType {
	//odinfmt: disable
	return \
		.VmaBuffer when T == vk.Buffer else
		.BindlessImage when T == ImageId else
		.BindlessSampler when T == SamplerId else
		.ImageView when T == vk.ImageView else
		.CommandPool when T == vk.CommandPool else
		.DescriptorPool when T == vk.DescriptorPool else
		.DescriptorSetLayout when T == vk.DescriptorSetLayout else
		.Fence when T == vk.Fence else
		.Pipeline when T == vk.Pipeline else
		.PipelineLayout when T == vk.PipelineLayout else
		.AccelerationStructure when T == vk.AccelerationStructureKHR else
		.Swapchain when T == vk.SwapchainKHR else
		#panic("Handle type is not a valid resource")
	//odinfmt: enable
}

type_requires_allocation :: proc($T: typeid) -> bool {
	return T == vk.Buffer
	//odinfmt: enable
}

resource_requires_allocation :: proc(type: ResourceType) -> bool {
	#partial switch type {
	case .VmaBuffer:
		return true
	case:
		return false
	}
}

defer_destroy_resource :: proc(
	arena: ^ResourceArena,
	handle: u64,
	resource_type: ResourceType,
	allocation: vma.Allocation = nil,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	if resource_requires_allocation(resource_type) {
		assert(allocation != nil, "Resource of this type requires an allocation to be passed in.", loc)
	}

	resource_handle := ResourceHandle {
		handle          = handle,
		ty              = resource_type,
		allocation      = allocation,
		debug_info      = debug,
		caller_location = loc,
	}

	append(&arena.resource_arena, resource_handle)
}

defer_destroy_buffer :: proc(arena: ^ResourceArena, buffer: Buffer($T), debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)buffer.buffer, .VmaBuffer, buffer.allocation)
}

defer_destroy_image :: proc(arena: ^ResourceArena, id: ImageId, debug: string = "UNKNOWN", loc := #caller_location) {
	// Keep the slot alive until the owning arena is safe to flush. destroy_image
	// handles view-only IDs and releases the slot after destroying the resource.
	defer_destroy_resource(arena, u64(id), .BindlessImage, nil, debug, loc)
}

defer_destroy_sampler :: proc(arena: ^ResourceArena, id: SamplerId, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, u64(id), .BindlessSampler, nil, debug, loc)
}

defer_destroy_graphics_pipeline :: proc(
	arena: ^ResourceArena,
	pipeline: GraphicsPipeline,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)pipeline.pipeline, .Pipeline, nil, debug, loc)
	defer_destroy_resource(arena, transmute(u64)pipeline.layout, .PipelineLayout, nil, debug, loc)
}

defer_destroy_compute_pipeline :: proc(
	arena: ^ResourceArena,
	pipeline: ComputePipeline,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)pipeline.pipeline, .Pipeline, nil, debug, loc)
	defer_destroy_resource(arena, transmute(u64)pipeline.layout, .PipelineLayout, nil, debug, loc)
}

defer_destroy_vk_command_pool :: proc(arena: ^ResourceArena, handle: vk.CommandPool, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .CommandPool, nil, debug, loc)
}

defer_destroy_vk_descriptor_pool :: proc(
	arena: ^ResourceArena,
	handle: vk.DescriptorPool,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .DescriptorPool, nil, debug, loc)
}

defer_destroy_vk_descriptor_set_layout :: proc(
	arena: ^ResourceArena,
	handle: vk.DescriptorSetLayout,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .DescriptorSetLayout, nil, debug, loc)
}

defer_destroy_vk_fence :: proc(arena: ^ResourceArena, handle: vk.Fence, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Fence, nil, debug, loc)
}

defer_destroy_vk_pipeline :: proc(arena: ^ResourceArena, handle: vk.Pipeline, debug: string = "UNKNOWN", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Pipeline, nil, debug, loc)
}

defer_destroy_vk_pipeline_layout :: proc(
	arena: ^ResourceArena,
	handle: vk.PipelineLayout,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)handle, .PipelineLayout, nil, debug, loc)
}

defer_destroy_vk_swapchain :: proc(arena: ^ResourceArena, handle: vk.SwapchainKHR, debug := "", loc := #caller_location) {
	defer_destroy_resource(arena, transmute(u64)handle, .Swapchain, nil, debug, loc)
}

defer_destroy :: proc {
	defer_destroy_buffer,
	defer_destroy_image,
	defer_destroy_sampler,
	defer_destroy_graphics_pipeline,
	defer_destroy_compute_pipeline,

	// Vulkan-specific handle overloads
	defer_destroy_vk_command_pool,
	defer_destroy_vk_descriptor_pool,
	defer_destroy_vk_descriptor_set_layout,
	defer_destroy_vk_fence,
	defer_destroy_vk_pipeline,
	defer_destroy_vk_pipeline_layout,
	defer_destroy_vk_swapchain,
}

flush_vk_arena :: proc(arena: ^ResourceArena) {
	#reverse for &resource in arena.resource_arena {
		vk_destroy_resource_by_handle(resource)
	}

	clear(&arena.resource_arena)
}

delete_vk_arena :: proc(arena: ResourceArena) {
	delete(arena.resource_arena)
}
