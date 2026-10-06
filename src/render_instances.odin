package game

import "core:log"
import "gfx"
import vk "vendor:vulkan"

MAX_RENDER_INSTANCES :: 16_384

@(shader_shared)
GPURenderInstance :: struct #max_field_align(16) {
	model_to_world: Mat4x4,
	vertex_buffer:  gfx.Ptr(Vertex),
	index_buffer:   gfx.Ptr(u32),
	material_index: MaterialId,
}

RenderInstance :: struct {
	data:         GPURenderInstance,
	index_buffer: vk.Buffer,
	index_count:  u32,
	blas_address: vk.DeviceAddress,
}

submit_render_instance :: proc(instance: RenderInstance) {
	frame := current_frame_game()
	if len(frame.instances) >= MAX_RENDER_INSTANCES {
		log.error("Render instance overflow, dropping instance")
		return
	}
	append(&frame.instances, instance)
}

prepare_render_instances :: proc(frame: ^GameFrameData) {
	data := make([]GPURenderInstance, len(frame.instances), context.temp_allocator)

	for instance, i in frame.instances {
		data[i] = instance.data
	}

	if len(data) > 0 {
		gfx.write_buffer_slice(&frame.instances_buffer, data)
	}

	prepare_raytracing(&frame.rt, frame.instances[:])
}
