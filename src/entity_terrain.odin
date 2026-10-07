package game

import b3 "vendor:box3d"

HEIGHTFIELD_FILE_VERSION :: 1
HEIGHTFIELD_HEADER_SIZE :: 40
HEIGHTFIELD_MAX_AXIS :: 8193

@(entity, init = terrain_init, destroy = terrain_destroy)
Terrain :: struct {
	using entity: ^Entity,
	translation:  Vec3,
	rotation:     Quat,
	material:     Handle(Material_Asset),
	body:         b3.BodyId,
	heightfield:  Handle(Heightfield_Asset),
}

terrain_init :: proc(terrain: ^Terrain) {
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = terrain.translation
	body_def.rotation = terrain.rotation
	body_def.userData = entity_id_to_rawptr(terrain.id)
	terrain.body = b3.CreateBody(game.phys.world, body_def)

	shape_def := b3.DefaultShapeDef()
	shape_def.baseMaterial = phys_default_material()

	source := load_asset(terrain.heightfield)

	_ = b3.CreateHeightFieldShape(terrain.body, shape_def, source.phys_heightfield)

	load_asset(terrain.material)
}

terrain_destroy :: proc(terrain: ^Terrain) {
	if b3.IS_NON_NULL(terrain.body) {
		b3.DestroyBody(terrain.body)
		terrain.body = b3.nullBodyId
	}
	release_asset(terrain.material)
	release_asset(terrain.heightfield)
}
