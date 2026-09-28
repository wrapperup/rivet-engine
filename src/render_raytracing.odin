package game

import vk "vendor:vulkan"
import "gfx"

RaytracingResources :: struct {
	instances_buffer: gfx.Buffer(vk.AccelerationStructureInstanceKHR),
	instance_count:   u32,
	tlas:             gfx.Raytracing_Accel,
}

init_raytracing :: proc() {
	for &frame in game.render_state.frame_data {
		frame.rt.instances_buffer = gfx.create_buffer(vk.AccelerationStructureInstanceKHR, MAX_RENDER_INSTANCES, .AccelInstances)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, frame.rt.instances_buffer)
	}
}

prepare_raytracing :: proc(rt: ^RaytracingResources, instances: []RenderInstance) {
	build_instances := make([]vk.AccelerationStructureInstanceKHR, len(instances), context.temp_allocator)
	rt.instance_count = 0
	for instance, i in instances {
		if instance.blas_address == 0 do continue
		build_instance := &build_instances[rt.instance_count]
		build_instance.transform = mat4_to_vk_transform(instance.data.model_to_world)
		build_instance.mask = 0xFF

		// Preserve the shared renderer index when some instances are excluded.
		build_instance.instanceCustomIndex = u32(i)
		build_instance.accelerationStructureReference = u64(instance.blas_address)
		rt.instance_count += 1
	}
	if rt.instance_count > 0 {
		gfx.write_buffer_slice(&rt.instances_buffer, build_instances[:rt.instance_count])
	}
}

record_raytracing :: proc(cmd: gfx.CommandBuffer, rt: ^RaytracingResources) {
	gfx.defer_destroy_accel(&gfx.current_frame().arena, rt.tlas)
	rt.tlas = {}

	if rt.instance_count == 0 do return

	scratch: gfx.Buffer(u8)
	rt.tlas, scratch = gfx.build_tlas(cmd, rt.instances_buffer, rt.instance_count)
	gfx.defer_destroy(&gfx.current_frame().arena, scratch)

	gfx.buffer_barrier(
		cmd,
		rt.tlas.buffer,
		src_access = .AccelerationStructureBuildWrite,
		dst_access = .AccelerationStructureRead,
	)
}

mat4_to_vk_transform :: proc(m: Mat4x4) -> vk.TransformMatrixKHR {
	t: vk.TransformMatrixKHR
	for r in 0 ..< 3 {
		for c in 0 ..< 4 {
			t.mat[r][c] = m[r, c]
		}
	}
	return t
}
