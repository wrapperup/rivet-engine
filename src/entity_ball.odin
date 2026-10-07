package game

import "core:log"

import b3 "vendor:box3d"

@(entity, init = init_ball)
Ball :: struct {
	using entity: ^Entity,
	translation: Vec3,
	velocity:    Vec3,
	rotation:    Quat,
	material:     MaterialId,
	num:          int,
	rigid:        b3.BodyId,
}

init_ball :: proc(ball: ^Ball) {
	ball.num = len_entities(Ball) - 1

	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = ball.translation
	body_def.linearVelocity = ball.velocity
	body_def.linearDamping = 0.1
	body_def.angularDamping = 0.1
	body_def.sleepThreshold = 0.1
	body_def.userData = entity_id_to_rawptr(ball.id) // TODO: This is sketchy.
	ball.rigid = b3.CreateBody(game.phys.world, body_def)

	sphere := b3.Sphere {
		center = {0, 0, 0},
		radius = 1.0,
	}
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 10.0
	shape_def.baseMaterial = phys_default_material()

	_ = b3.CreateSphereShape(ball.rigid, shape_def, &sphere)
}

update_ball_fixed :: proc(ball: ^Ball) {
	xform := b3.Body_GetTransform(ball.rigid)
	ball.translation = transmute(Vec3)xform.p
	ball.rotation = xform.q
}
