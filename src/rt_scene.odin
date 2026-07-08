package game

import "core:log"

import vk "vendor:vulkan"

import "gfx"

// File-private alias mirrors renderer.odin so the @shader_shared bindgen sees the
// bare name (GPUPtr).
@(private = "file")
GPUPtr :: gfx.GPUPtr

RT_MAX_INSTANCES :: 16_384

// Per-instance indirection for ray-hit shading: a ray hit gives instance/primitive
// indices but no vertex data, so this table (indexed by instanceCustomIndex) points
// back at the mesh's buffers + material. Plain BDA buffer, not a bindless descriptor.
@(shader_shared)
GPUGeometry :: struct #max_field_align(16) {
	vertex_buffer:  GPUPtr(Vertex),
	index_buffer:   GPUPtr(u32),
	material_index: MaterialId,
	_pad:           [3]u32,
}

// Per-frame-slot raytraced scene: BLAS instances + the parallel geometry table.
// draw_mesh appends instances inline (single source of truth with the raster draw
// list), then rt_scene_build turns them into a TLAS once per frame.
RaytracingScene :: struct {
	// CPU staging, appended by rt_scene_add, cleared at end of frame. Parallel
	// arrays: instances[i].instanceCustomIndex == i indexes geometries.
	instances:         [dynamic]vk.AccelerationStructureInstanceKHR,
	geometries:        [dynamic]GPUGeometry,

	// GPU side, created once per frame slot.
	instances_buffer:  gfx.GPUBuffer(vk.AccelerationStructureInstanceKHR),
	geometries_buffer: gfx.GPUBuffer(GPUGeometry),
	tlas:              gfx.Raytracing_Accel,
}

rt_scene_init :: proc(rt: ^RaytracingScene) {
	rt.instances_buffer = gfx.create_buffer(vk.AccelerationStructureInstanceKHR, RT_MAX_INSTANCES, .AccelInstances)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rt.instances_buffer)

	rt.geometries_buffer = gfx.create_buffer(GPUGeometry, RT_MAX_INSTANCES, .DynUniform)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rt.geometries_buffer)
}

rt_scene_add :: proc(rt: ^RaytracingScene, mesh: GPUMeshBuffers, material: MaterialId, transform: Mat4x4) {
	if mesh.blas.address == 0 do return // no BLAS (e.g. skeletal)
	if len(rt.instances) >= RT_MAX_INSTANCES {
		log.error("RaytracingScene instance overflow, dropping instance")
		return
	}

	inst: vk.AccelerationStructureInstanceKHR
	inst.transform = mat4_to_vk_transform(transform)
	inst.mask = 0xFF
	inst.instanceCustomIndex = u32(len(rt.instances)) // -> geometry-table slot
	inst.accelerationStructureReference = u64(mesh.blas.address)
	append(&rt.instances, inst)

	append(
		&rt.geometries,
		GPUGeometry {
			vertex_buffer = mesh.vertex_buffer.ptr,
			index_buffer = mesh.index_buffer.ptr,
			material_index = material,
		},
	)
}

// Rebuilds the scene TLAS from the instances collected this frame, recording the
// build into `cmd`. Scratch + the previous TLAS for this frame slot are deferred
// on the frame arena (freed once this slot's fence signals).
rt_scene_build :: proc(rt: ^RaytracingScene, cmd: vk.CommandBuffer) {
	gfx.defer_destroy_accel(&gfx.current_frame().arena, rt.tlas)
	rt.tlas = {}

	if len(rt.instances) == 0 do return

	gfx.write_buffer_slice(&rt.instances_buffer, rt.instances[:])
	gfx.write_buffer_slice(&rt.geometries_buffer, rt.geometries[:])

	scratch: gfx.GPUBuffer(u8)
	rt.tlas, scratch = gfx.build_tlas(cmd, rt.instances_buffer, u32(len(rt.instances)))
	gfx.defer_destroy(&gfx.current_frame().arena, scratch)

	// AS build write -> ray query read.
	gfx.transition_buffer(
		cmd,
		rt.tlas.buffer,
		{.ACCELERATION_STRUCTURE_WRITE_KHR},
		{.ACCELERATION_STRUCTURE_READ_KHR},
		gfx.r_ctx.graphics_queue_family,
	)
}

rt_scene_reset :: proc(rt: ^RaytracingScene) {
	clear(&rt.instances)
	clear(&rt.geometries)
}

// Row-major 3x4 expected by VkAccelerationStructureInstanceKHR. m[r, c] is the
// mathematical element regardless of Odin's column-major storage.
mat4_to_vk_transform :: proc(m: Mat4x4) -> vk.TransformMatrixKHR {
	t: vk.TransformMatrixKHR
	for r in 0 ..< 3 {
		for c in 0 ..< 4 {
			t.mat[r][c] = m[r, c]
		}
	}
	return t
}
