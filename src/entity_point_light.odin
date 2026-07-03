package game

@(shader_shared)
GPUPointLight :: struct #max_field_align(16) {
	color:     Vec3,
	radius:    f32,
	world_pos: Vec3,
	lumens:    f32,
}

@(entity)
PointLight :: struct {
	using entity: ^Entity,
	color:        Vec3,
	radius:       f32,
	lumens:       f32,
}

point_light_to_gpu :: proc(light: PointLight) -> GPUPointLight {
    // odinfmt: disable
	return GPUPointLight{
        color = light.color,
        radius = light.radius,
        world_pos = light.translation,
        lumens = light.lumens
    }
    // odinfmt: enable
}

init_point_light :: proc(light: ^PointLight, position: Vec3, color: Vec3, radius: f32, lumens: f32) {
	light.translation = position
	light.color = color
	light.radius = radius
	light.lumens = lumens
}
