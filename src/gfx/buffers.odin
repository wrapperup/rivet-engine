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
BufferMemoryFlag :: enum {
	nil,
	Host_Sequential_Write,
	Host_Random,
}
BufferMemoryFlags :: bit_set[BufferMemoryFlag]

vk_buffer_flags :: proc(alloc_flags: BufferMemoryFlags) -> (vk.BufferUsageFlags, vma.AllocationCreateFlags) {
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
	alloc_flags: BufferMemoryFlag = {},
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

// Uploads the data via a staging buffer. This is useful if your buffer is GPU only.
staging_write_buffer :: proc(buffer: ^Buffer($Z), in_data: ^$T, offset: vk.DeviceSize = 0, loc := #caller_location) {
	size := size_of(T)
	assert(buffer.info.size >= vk.DeviceSize(u64(size) + u64(offset)), "The size of the data and offset is larger than the buffer", loc)

	staging := create_buffer(u8, vk.DeviceSize(size_of(T)), .Host_Sequential_Write)
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

	staging := create_buffer(u8, size, .Host_Sequential_Write)
	write_buffer_slice(&staging, in_data)

	{
		cmd := immediate_submit()

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
	cmd: CommandBuffer,
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

Scratch :: struct {
	buffer:         Buffer(u8),
	current_offset: vk.DeviceSize,
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

// TODO: Do we need this? It would be useful I think at some point.
// It's specific push/pop functions will update a buffer automatically,
// and maps to an Odin dynamic array.
//DynamicArray :: struct {
//	using _: Buffer,
//}
