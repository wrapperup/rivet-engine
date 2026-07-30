package gfx

import vma "deps:odin-vma"
import vk "vendor:vulkan"

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

    return {
        scratch_align = as_props.minAccelerationStructureScratchOffsetAlignment,
        max_instances = as_props.maxInstanceCount,
    }
}

_build_accel :: proc(
    cmd:             vk.CommandBuffer,
    type:            vk.AccelerationStructureTypeKHR,
    geometry:        ^vk.AccelerationStructureGeometryKHR,
    primitive_count: u32,
    loc := #caller_location,
) -> (accel: Raytracing_Accel, scratch: Buffer(u8)) {
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
    accel.buffer = create_buffer(u8, sizes.accelerationStructureSize, .AccelStorage, loc = loc)

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
    vertex_addr:   vk.DeviceAddress,
    vertex_count:  u32,
    vertex_stride: vk.DeviceSize,
    index_addr:    vk.DeviceAddress,
    index_count:   u32,
) -> (blas: Raytracing_Accel) {
    triangles := vk.AccelerationStructureGeometryTrianglesDataKHR {
        sType        = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
        vertexFormat = .R32G32B32_SFLOAT,
        vertexData   = {deviceAddress = vertex_addr},
        vertexStride = vertex_stride,
        maxVertex    = vertex_count - 1,
        indexType    = .UINT32,
        indexData    = {deviceAddress = index_addr},
    }
    geo := vk.AccelerationStructureGeometryKHR {
        sType        = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
        geometryType = .TRIANGLES,
        geometry     = {triangles = triangles},
        flags        = {.OPAQUE},
    }

    scratch: Buffer(u8)
    if cmd, ok := immediate_submit(); ok {
        blas, scratch = _build_accel(cmd, .BOTTOM_LEVEL, &geo, index_count / 3)
    }
    destroy_buffer(&scratch)
    return
}

build_tlas :: proc(
    cmd:       vk.CommandBuffer,
    instances: Buffer(vk.AccelerationStructureInstanceKHR),
    count:     u32,
) -> (tlas: Raytracing_Accel, scratch: Buffer(u8)) {
    geo := vk.AccelerationStructureGeometryKHR {
        sType        = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
        geometryType = .INSTANCES,
        geometry     = {
            instances = {
                sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR,
                data  = {deviceAddress = instances.ptr.address},
            },
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
defer_destroy_accel :: proc(arena: ^ResourceArena, accel: Raytracing_Accel, loc := #caller_location) {
    if accel.accel == 0 do return // never built
    defer_destroy_buffer(arena, accel.buffer, loc = loc)
    defer_destroy_resource(arena, transmute(u64)accel.accel, .AccelerationStructure, loc = loc)
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
