package gfx

import "core:fmt"
import "core:mem"
import vma "deps:odin-vma"
import vk "vendor:vulkan"

Buffer :: struct($T: typeid) {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.AllocationInfo,
	ptr:        Ptr(T),
	count:      u64,
}

BufferAccess :: enum {
	None,
	AllReads,
	AllWrites,
	AllReadsWrites,
	ComputeShaderRead,
	ComputeShaderWrite,
	VertexShaderRead,
	FragmentShaderRead,
	TransferRead,
	TransferWrite,
	AccelerationStructureBuildRead,
	AccelerationStructureBuildWrite,
	AccelerationStructureRead,
}

// This is hopefully very common kinds of buffers
// you may typically want to create. Uniform and Storage
// buffers will always create a valid Ptr(T).
BufferKind :: enum {
	Storage, // Includes ptr
    Index,
    Staging, // For CPU -> GPU writes onto device-local buffers.
    AccelStorage, // Raytracing accel structures.
    AccelInstances, // Host-mapped TLAS instance buffer (AS build input).
    Uniform, // Includes ptr. However, prefer uniform access for speed.
    DynUniform, // Mapped uniform buffer // TODO: HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT
	Readback, // For GPU -> CPU reads from device-local buffers.
}

vk_buffer_flags :: proc(kind: BufferKind) -> (vk.BufferUsageFlags, vma.AllocationCreateFlags) {
	rt := vk.BufferUsageFlags{}

    // TODO: Query.
	if true {
		rt = {.ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR}
	}

	switch kind {
	case .Storage:
		return {.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS} + rt, {}
	case .Index:
		return {.TRANSFER_DST, .INDEX_BUFFER, .SHADER_DEVICE_ADDRESS} + rt, {}
	case .Staging:
		return {.TRANSFER_SRC}, {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE}
	case .AccelStorage:
		return {.ACCELERATION_STRUCTURE_STORAGE_KHR, .SHADER_DEVICE_ADDRESS}, {}
	case .AccelInstances:
		return {.ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR, .SHADER_DEVICE_ADDRESS}, {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE}
    // LEGACY
	case .Uniform:
		return {.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {}
	case .DynUniform:
		return {.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {.MAPPED, .HOST_ACCESS_RANDOM}
	case .Readback:
		return {.TRANSFER_DST}, {.MAPPED, .HOST_ACCESS_RANDOM}
	}

	unreachable()
}

// This allocates on the GPU, make sure to call `destroy_buffer` or add to deletion queue when you are finished with the buffer.
create_buffer :: proc(
	$T: typeid,
	#any_int size: vk.DeviceSize = 1,
	kind: BufferKind = .Storage,
	name: cstring = nil,
	loc := #caller_location,
) -> Buffer(T) {
	alloc_size := cast(vk.DeviceSize)(size_of(T) * size)

	vk_usage_flags, vma_create_flags := vk_buffer_flags(kind)

	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = alloc_size,
		usage = vk_usage_flags,
	}

	vma_alloc_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = vma_create_flags,
	}

	new_buffer: Buffer(T)
	new_buffer.count = u64(size)
	vk_check(
		vma.CreateBuffer(r_ctx.allocator, &buffer_info, &vma_alloc_info, &new_buffer.buffer, &new_buffer.allocation, &new_buffer.info),
		loc,
	)

	if .SHADER_DEVICE_ADDRESS in vk_usage_flags {
		new_buffer.ptr.address = get_buffer_device_address(new_buffer)
	}

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


// Only purpose of this is to be captured during bindgen.
Ptr :: struct($T: typeid) {
	address: vk.DeviceAddress,
}

// GPU-side array view.
Slice :: struct($T: typeid) {
	data:  Ptr(T),
	count: u64,
}

#assert(size_of(Slice(u32)) == 16)
#assert(offset_of(Slice(u32), data) == 0)
#assert(offset_of(Slice(u32), count) == 8)

slice_from_ptr :: proc(data: Ptr($T), count: u64) -> Slice(T) {
	return {data = data, count = count}
}

slice_from_buffer :: proc(
	buffer: Buffer($T),
	first: u64 = 0,
	count: Maybe(u64) = nil,
) -> Slice(T) {
	assert(buffer.ptr.address != 0, "GPU slices require a device-addressable buffer")
	total_count := buffer.count
	assert(first <= total_count, "GPU slice starts outside its buffer")

	slice_count := total_count - first
	if requested_count, ok := count.?; ok {
		assert(requested_count <= total_count - first, "GPU slice extends outside its buffer")
		slice_count = requested_count
	}

	return {
		data = {
			address = buffer.ptr.address +
				vk.DeviceAddress(first) * vk.DeviceAddress(size_of(T)),
		},
		count = slice_count,
	}
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

// Uploads the data via a staging buffer. This is useful if your buffer is GPU only.
staging_write_buffer :: proc(buffer: ^Buffer($Z), in_data: ^$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	size := size_of(T)
	assert(buffer.info.size >= vk.DeviceSize(u64(size) + u64(offset)), "The size of the data and offset is larger than the buffer", loc)

	staging := create_buffer(u8, vk.DeviceSize(size_of(T)), .Staging)
	write_buffer(&staging, in_data)

	if cmd, ok := immediate_submit(); ok {
		region := vk.BufferCopy {
			dstOffset = offset,
			srcOffset = 0,
			size      = vk.DeviceSize(size),
		}

		vk.CmdCopyBuffer(cmd, staging.buffer, buffer.buffer, 1, &region)
	}

	destroy_buffer(&staging)
}

// Uploads the data via a staging buffer. This is useful if your buffer is GPU only.
staging_write_buffer_slice :: proc(buffer: ^Buffer($Z), in_data: []$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	size := size_of(T) * len(in_data)
	assert(buffer.info.size >= vk.DeviceSize(u64(size) + u64(offset)), "The size of the slice and offset is larger than the buffer", loc)

	staging := create_buffer(u8, size, .Staging)
	write_buffer_slice(&staging, in_data)

	if cmd, ok := immediate_submit(); ok {
		region := vk.BufferCopy {
			dstOffset = offset,
			srcOffset = 0,
			size      = vk.DeviceSize(size),
		}

		vk.CmdCopyBuffer(cmd, staging.buffer, buffer.buffer, 1, &region)
	}

	destroy_buffer(&staging)
}

@(private)
buffer_access_masks :: proc(access: BufferAccess) -> (vk.PipelineStageFlags2, vk.AccessFlags2) {
	switch access {
	case .None:
		return {}, {}
	case .AllReads:
		return {.ALL_COMMANDS}, {.MEMORY_READ}
	case .AllWrites:
		return {.ALL_COMMANDS}, {.MEMORY_WRITE}
	case .AllReadsWrites:
		return {.ALL_COMMANDS}, {.MEMORY_READ, .MEMORY_WRITE}
	case .ComputeShaderRead:
		return {.COMPUTE_SHADER}, {.SHADER_READ}
	case .ComputeShaderWrite:
		return {.COMPUTE_SHADER}, {.SHADER_WRITE}
	case .VertexShaderRead:
		return {.VERTEX_SHADER}, {.SHADER_READ}
	case .FragmentShaderRead:
		return {.FRAGMENT_SHADER}, {.SHADER_READ}
	case .TransferRead:
		return {.ALL_TRANSFER}, {.TRANSFER_READ}
	case .TransferWrite:
		return {.ALL_TRANSFER}, {.TRANSFER_WRITE}
	case .AccelerationStructureBuildRead:
		return {.ACCELERATION_STRUCTURE_BUILD_KHR}, {.ACCELERATION_STRUCTURE_READ_KHR}
	case .AccelerationStructureBuildWrite:
		return {.ACCELERATION_STRUCTURE_BUILD_KHR}, {.ACCELERATION_STRUCTURE_WRITE_KHR}
	case .AccelerationStructureRead:
		return {.ALL_COMMANDS}, {.ACCELERATION_STRUCTURE_READ_KHR}
	}

	unreachable()
}

buffer_barrier :: proc(
	cmd: vk.CommandBuffer,
	buffer: Buffer($T),
	src_access: BufferAccess,
	dst_access: BufferAccess,
	offset: u64 = 0,
	size: u64 = 0,
) {
	src_stage_mask, src_access_mask := buffer_access_masks(src_access)
	dst_stage_mask, dst_access_mask := buffer_access_masks(dst_access)

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

// TODO: Do we need this? It would be useful I think at some point.
// It's specific push/pop functions will update a buffer automatically,
// and maps to an Odin dynamic array.
//DynamicArray :: struct {
//	using _: Buffer,
//}
