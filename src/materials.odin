package game

import "gfx"

//TODO: support shaders

MaterialId :: distinct u32

@(shader_shared)
GPUMaterial_Flag :: enum u32 {
	Temp_World_Space,
}

@(shader_shared)
GPUMaterial_Flags :: bit_set[GPUMaterial_Flag;u32]

@(shader_shared)
GPUMaterial :: struct #max_field_align(16) {
	flags:                    GPUMaterial_Flags,
	world_space_uv_scale:     f32,
	base_color_id:            gfx.Image_Id `Image2D`,
	normal_map_id:            gfx.Image_Id `Image2D`,
	ao_roughness_metallic_id: gfx.Image_Id `Image2D`,
}

Material_Store :: struct {
	materials_gpu:    [dynamic]GPUMaterial,
	materials_buffer: gfx.Buffer(GPUMaterial),
	free_materials:   [dynamic]MaterialId,
}

init_material_store :: proc() {
	material_store := &game.render_state.material_store

	material_store.materials_buffer = gfx.create_buffer(GPUMaterial, 20)
	gfx.defer_destroy(frame_arena(), material_store.materials_buffer)
}

add_material :: proc(material: GPUMaterial) -> (material_id: MaterialId) {
	material_store := &game.render_state.material_store

	scene_resources := &game.render_state.scene_resources

	if len(material_store.free_materials) > 0 {
		material_id = pop(&material_store.free_materials)
		material_store.materials_gpu[material_id] = material
	} else {
		material_id = MaterialId(len(material_store.materials_gpu))
		append(&material_store.materials_gpu, material)
	}

    staging := gfx.create_buffer(GPUMaterial, 20, .Host_Sequential_Write)
    defer gfx.destroy_buffer(&staging)

    {
        cmd := gfx.begin_command_buffer(.Main)

        gfx.write_buffer_slice(&staging, material_store.materials_gpu[:])
        gfx.cmd_copy_buffer(cmd, staging, material_store.materials_buffer)

        done := gfx.queue_submit(.Main, cmd)
        gfx.wait_semaphore(done)
    }

	return material_id
}

remove_material :: proc(id: MaterialId) {
	material_store := &game.render_state.material_store
	append(&material_store.free_materials, id)
}
