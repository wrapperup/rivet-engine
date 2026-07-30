package game

import "core:log"

import vk "vendor:vulkan"

import "gfx"

RT_MAX_INSTANCES :: 16_384

// Per-instance indirection for ray-hit shading: a ray hit gives instance/primitive
// indices but no vertex data, so this table (indexed by instanceCustomIndex) points
// back at the mesh's buffers + material. Plain BDA buffer, not a bindless descriptor.
@(shader_shared)
GPUGeometry :: struct #max_field_align(16) {
	vertex_buffer:  gfx.Ptr(Vertex),
	index_buffer:   gfx.Ptr(u32),
	material_index: MaterialId,
	_pad:           [3]u32,
}

// Per-frame-slot raytraced scene: BLAS instances + the parallel geometry table.
// draw_mesh appends instances inline (single source of truth with the raster draw
// list), then record_rt_scene_pass turns them into a TLAS once per frame.
RaytracingScene :: struct {
	// CPU staging, appended by rt_scene_add, cleared at end of frame. Parallel
	// arrays: instances[i].instanceCustomIndex == i indexes geometries.
	instances:         [dynamic]vk.AccelerationStructureInstanceKHR,
	geometries:        [dynamic]GPUGeometry,

	// GPU side, created once per frame slot.
	instances_buffer:  gfx.Buffer(vk.AccelerationStructureInstanceKHR),
	geometries_buffer: gfx.Buffer(GPUGeometry),
	tlas:              gfx.Raytracing_Accel,
}

init_rt_scene_pass :: proc() {
	for &frame in game.render_state.frame_data {
		rt_scene_init(&frame.rt)
	}
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

rt_scene_prepare :: proc(rt: ^RaytracingScene) {
	if len(rt.instances) == 0 do return

	gfx.write_buffer_slice(&rt.instances_buffer, rt.instances[:])
	gfx.write_buffer_slice(&rt.geometries_buffer, rt.geometries[:])
}

// Rebuilds the scene TLAS from the instance data uploaded by rt_scene_prepare.
// Scratch + the previous TLAS for this frame slot are deferred on the frame arena.
record_rt_scene_pass :: proc(cmd: vk.CommandBuffer, rt: ^RaytracingScene) {
	gfx.defer_destroy_accel(&gfx.current_frame().arena, rt.tlas)
	rt.tlas = {}

	if len(rt.instances) == 0 do return

	scratch: gfx.Buffer(u8)
	rt.tlas, scratch = gfx.build_tlas(cmd, rt.instances_buffer, u32(len(rt.instances)))
	gfx.defer_destroy(&gfx.current_frame().arena, scratch)

	// AS build write -> ray query read.
	gfx.buffer_barrier(
		cmd,
		rt.tlas.buffer,
		src_access = .AccelerationStructureBuildWrite,
		dst_access = .AccelerationStructureRead,
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
