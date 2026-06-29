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
	VmaBuffer,
	VmaImage,
	CommandPool,
	DescriptorPool,
	DescriptorSetLayout,
	Fence,
	ImageView,
	Pipeline,
	PipelineLayout,
	Sampler,
	AccelerationStructure,
}

destroy_resource :: proc(
	handle: $T,
	allocation: vma.Allocation = nil,
) {
	when T == vk.Buffer || T == vk.Image {
		when allocation == nil {
			#assert(false)
		}
	}

	ty := resource_type_of_handle(T)

	switch ty {
	case .VmaBuffer:
		vma.DestroyBuffer(r_ctx.allocator, cast(vk.Buffer)resource.handle, resource.allocation)
	case .VmaImage:
		vma.DestroyImage(r_ctx.allocator, cast(vk.Image)resource.handle, resource.allocation)
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
	case .Sampler:
		vk.DestroySampler(r_ctx.device, cast(vk.Sampler)resource.handle, nil)
	case .AccelerationStructure:
		vk.DestroyAccelerationStructureKHR(r_ctx.device, cast(vk.AccelerationStructureKHR)resource.handle, nil)
	}
}

vk_destroy_resource_by_handle :: proc(resource: ResourceHandle) {
	when false {
		log_normal("DEBUG: Destroy", resource.ty, "@", resource.caller_location, "-", resource.debug_info)
	}

	if resource_requires_allocation(resource.ty) {
		assert(resource.allocation != nil)
	}

	switch resource.ty {
	case .VmaBuffer:
		vma.DestroyBuffer(r_ctx.allocator, cast(vk.Buffer)resource.handle, resource.allocation)
	case .VmaImage:
		vma.DestroyImage(r_ctx.allocator, cast(vk.Image)resource.handle, resource.allocation)
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
	case .Sampler:
		vk.DestroySampler(r_ctx.device, cast(vk.Sampler)resource.handle, nil)
	case .AccelerationStructure:
		vk.DestroyAccelerationStructureKHR(r_ctx.device, cast(vk.AccelerationStructureKHR)resource.handle, nil)
	}
}

resource_type_of_handle :: proc($T: typeid) -> ResourceType {
	//odinfmt: disable
	return \
		.VmaBuffer when T == vk.Buffer else
		.VmaImage when T == vk.Image else
		.ImageView when T == vk.ImageView else
		.CommandPool when T == vk.CommandPool else
		.DescriptorPool when T == vk.DescriptorPool else
		.DescriptorSetLayout when T == vk.DescriptorSetLayout else
		.Fence when T == vk.Fence else
		.Pipeline when T == vk.Pipeline else
		.PipelineLayout when T == vk.PipelineLayout else
		.Sampler when T == vk.Sampler else
		.AccelerationStructure when T == vk.AccelerationStructureKHR else
		#panic("Handle type is not a valid resource")
	//odinfmt: enable
}

type_requires_allocation :: proc($T: typeid) -> bool {
	return \
		true when T == vk.Buffer else
		true when T == vk.Image else
		false
	//odinfmt: enable
}

resource_requires_allocation :: proc(type: ResourceType) -> bool {
	#partial switch type {
	case .VmaBuffer:
		return true
	case .VmaImage:
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

defer_destroy_buffer :: proc(
	arena: ^ResourceArena,
	buffer: GPUBuffer($T),
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)buffer.buffer, .VmaBuffer, buffer.allocation);
}

defer_destroy_gpu_image :: proc(
	arena: ^ResourceArena,
	image: GPUImage,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)image.image, .VmaImage, image.allocation, debug, loc);
	if image.image_view != 0 {
		defer_destroy_resource(arena, transmute(u64)image.image_view, .ImageView, nil, debug, loc);
	}
}

defer_destroy_graphics_pipeline :: proc(
	arena: ^ResourceArena,
	pipeline: GraphicsPipeline,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)pipeline.pipeline, .Pipeline, nil, debug, loc);
	defer_destroy_resource(arena, transmute(u64)pipeline.layout, .PipelineLayout, nil, debug, loc);
}

defer_destroy_compute_pipeline :: proc(
	arena: ^ResourceArena,
	pipeline: ComputePipeline,
	debug: string = "UNKNOWN",
	loc := #caller_location,
) {
	defer_destroy_resource(arena, transmute(u64)pipeline.pipeline, .Pipeline, nil, debug, loc);
	defer_destroy_resource(arena, transmute(u64)pipeline.layout, .PipelineLayout, nil, debug, loc);
}

defer_destroy_vk_buffer :: proc(
    arena: ^ResourceArena,
    handle: vk.Buffer,
    allocation: vma.Allocation = nil,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
    defer_destroy_resource(arena, transmute(u64)handle, .VmaBuffer, allocation, debug, loc)
}

defer_destroy_vk_image :: proc(
    arena: ^ResourceArena,
    handle: vk.Image,
    allocation: vma.Allocation = nil,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
    defer_destroy_resource(arena, transmute(u64)handle, .VmaImage, allocation, debug, loc)
}

defer_destroy_vk_image_view :: proc(
    arena: ^ResourceArena,
    handle: vk.ImageView,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
    defer_destroy_resource(arena, transmute(u64)handle, .ImageView, nil, debug, loc)
}

defer_destroy_vk_command_pool :: proc(
    arena: ^ResourceArena,
    handle: vk.CommandPool,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
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

defer_destroy_vk_fence :: proc(
    arena: ^ResourceArena,
    handle: vk.Fence,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
    defer_destroy_resource(arena, transmute(u64)handle, .Fence, nil, debug, loc)
}

defer_destroy_vk_pipeline :: proc(
    arena: ^ResourceArena,
    handle: vk.Pipeline,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
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

defer_destroy_vk_sampler :: proc(
    arena: ^ResourceArena,
    handle: vk.Sampler,
    debug: string = "UNKNOWN",
    loc := #caller_location,
) {
    defer_destroy_resource(arena, transmute(u64)handle, .Sampler, nil, debug, loc)
}

defer_destroy :: proc {
    defer_destroy_buffer,
    defer_destroy_gpu_image,
    defer_destroy_graphics_pipeline,
    defer_destroy_compute_pipeline,

    // Vulkan-specific handle overloads
    defer_destroy_vk_buffer,
    defer_destroy_vk_image,
    defer_destroy_vk_image_view,
    defer_destroy_vk_command_pool,
    defer_destroy_vk_descriptor_pool,
    defer_destroy_vk_descriptor_set_layout,
    defer_destroy_vk_fence,
    defer_destroy_vk_pipeline,
    defer_destroy_vk_pipeline_layout,
    defer_destroy_vk_sampler,
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
