package game

import "core:encoding/json"
import "core:os"
import "gfx"

Material_JSON :: struct {
	using base:             Asset_Base,
	base_color:             string,
	normal_map:             string,
	proughness_metallic_ao: string,
}

@(shader_shared)
GPUMaterial :: struct #max_field_align(16) {
	base_color_id:            gfx.ImageId `Image2D`,
	normal_map_id:            gfx.ImageId `Image2D`,
	ao_roughness_metallic_id: gfx.ImageId `Image2D`,
}

Material_Store :: struct {
	materials:        [dynamic]GPUMaterial,
	materials_buffer: gfx.Buffer(GPUMaterial),
}

load_material_from_file :: proc(path: string, allocator := context.allocator) -> GPUMaterial {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	assert(read_err == nil, "Failed to read font json")
	defer delete(bytes)

	parsed: Material_JSON
	parse_err := json.unmarshal(bytes, &parsed, spec = .Bitsquid, allocator = context.allocator)
	defer delete(parsed.base_color)
	defer delete(parsed.normal_map)
	defer delete(parsed.proughness_metallic_ao)

	// TODO: asset system...
	gpu_material := GPUMaterial {
		base_color_id            = gfx.add_image(gfx.load_image_from_file(parsed.base_color)),
		normal_map_id            = gfx.add_image(gfx.load_image_from_file(parsed.normal_map)),
		ao_roughness_metallic_id = gfx.add_image(gfx.load_image_from_file(parsed.proughness_metallic_ao)),
	}

	return gpu_material
}

add_material :: proc(material: GPUMaterial) -> MaterialId {
    material_store := &game.render_state.material_store

	scene_resources := &game.render_state.scene_resources
	material_id := MaterialId(len(material_store.materials))

	append(&material_store.materials, material)

	gfx.staging_write_buffer_slice(&material_store.materials_buffer, material_store.materials[:])

	return material_id
}
