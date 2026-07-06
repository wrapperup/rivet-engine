package game

import "core:log"

import b3 "vendor:box3d"

@(entity)
Ball :: struct {
	using entity:       ^Entity,
	material:           MaterialId,
	num:                int,
	rigid:              b3.BodyId,

	// Skeleton stuff
	skel_mesh_instance: SkeletalMeshInstance,
	skel_anim:          ^SkeletalAnimation,
	skel_animator:      SkeletonAnimator,
	use_game_time:      bool,
	sample_time:        f32,
}

init_ball :: proc(ball: ^Ball, pos: Vec3, vel: [3]f32 = 0, skeleton: ^Skeleton, anim: ^SkeletalAnimation) {
	ball.skel_mesh_instance = init_skeletal_mesh_instance(skeleton, anim)
	ball.material = 1

	init_skeleton_animator(&ball.skel_animator, skeleton, anim)

	ball.num = len_entities(Ball) - 1

	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = transmute(b3.Pos)pos
	body_def.linearVelocity = transmute(b3.Vec3)vel
	body_def.linearDamping = 0.1
	body_def.angularDamping = 0.1
	body_def.sleepThreshold = 0.1
	body_def.userData = entity_id_to_rawptr(ball.id)
	ball.rigid = b3.CreateBody(game.phys.world, body_def)

	sphere := b3.Sphere {
		center = {0, 0, 0},
		radius = 1.3,
	}
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 10.0
	shape_def.baseMaterial = phys_default_material()
	_ = b3.CreateSphereShape(ball.rigid, shape_def, &sphere)
}

update_ball_fixed :: proc(ball: ^Ball) {
	sample_animation(&ball.skel_animator, ball.sample_time)
	ball.sample_time += 0.005

	xform := b3.Body_GetTransform(ball.rigid)
	ball.translation = transmute(Vec3)xform.p
	ball.rotation = xform.q
}

on_ball_collide :: proc(ball: ^Ball) {
	log.info("hi", ball)
}
