package game

import b3 "vendor:box3d"

@(entity)
StaticMesh :: struct {
	using entity:   ^Entity,
	mesh_asset:     Handle(Static_Mesh_Asset),
	material_asset: Handle(Material_Asset),
	body:           b3.BodyId,
	scale:          Vec3,
}

init_static_mesh :: proc(
	static_mesh: ^StaticMesh,
	mesh: Handle(Static_Mesh_Asset),
	material: Handle(Material_Asset),
	translation: Vec3 = {0, 0, 0},
	rotation: Quat = Quat(1),
	scale: Vec3 = {1, 1, 1},
) {
	static_mesh.translation = translation
	static_mesh.rotation = rotation
	static_mesh.scale = scale

	static_mesh.mesh_asset = mesh
	static_mesh.material_asset = material

	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = translation
	body_def.rotation = rotation
	body_def.userData = entity_id_to_rawptr(static_mesh.id)
	static_mesh.body = b3.CreateBody(game.phys.world, body_def)

	shape_def := b3.DefaultShapeDef()
	shape_def.baseMaterial = phys_default_material()

	static_mesh_asset := load_asset(static_mesh.mesh_asset)
	load_asset(static_mesh.material_asset)

	_ = b3.CreateMeshShape(static_mesh.body, shape_def, static_mesh_asset.phys_mesh_data, {1, 1, 1})
}

static_mesh_destroy :: proc(static_mesh: ^StaticMesh) {
	if b3.IS_NON_NULL(static_mesh.body) {
		b3.DestroyBody(static_mesh.body)
		static_mesh.body = b3.nullBodyId
	}

	release_asset(static_mesh.material_asset)
	release_asset(static_mesh.mesh_asset)
}
