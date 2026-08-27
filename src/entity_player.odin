package game

import "core:math"
import "core:math/linalg"

import "gfx"

Move_Mode :: enum {
	Ground,
	Noclip,
}

Fire_Mode :: enum {
	CreatePointLight,
	LaunchForward,
}

@(entity)
Player :: struct {
	using entity:               ^Entity,
	//
	eye_pos:                    Vec3,
	move_mode:                  Move_Mode,
	camera_rot:                 Vec3,
	camera_fov_deg:             f32,
	grounded:                   bool,
	ground_normal:              Vec3,
	fire_time:                  f64,
	momentum:                   f32,
	is_grounded_last_frame:     bool,
	footstep_distance_traveled: f32,
	footstep_time:              f64,
	footstep:                   u32,
	camera_shake_time:          f64,
	temp_cycler:                u32,
	fire_mode:                  Fire_Mode,
}

slope_limit_deg: f32 : 45.0
capsule_half_height: f32 : 0.5
capsule_radius: f32 : 0.5

init_player :: proc(player: ^Player) {
	player.translation = {0, 10, 0}
}

update_player :: proc(player: ^Player, dt: f64) {
	// Values / Constants
	max_ground_acceleration: f32 = 50
	max_air_acceleration: f32 = 50
	max_braking_acceleration: f32 = 80

	max_ground_speed: f32 = 10
	max_sprinting_ground_speed: f32 = 10
	max_air_speed: f32 = 10

	camera_forward: Vec3
	// camera_right: Vec3
	forward: Vec3
	right: Vec3
	{
		// Look scheme
		yaw_delta: f32
		pitch_delta: f32

		mouse_x := axis_get_value(.LookRight)
		mouse_y := axis_get_value(.LookUp)

		if action_just_pressed(.LockCamera) {
			toggle_lock_mouse()
		}

		yaw_delta = linalg.to_radians(f32(mouse_x)) * 0.025
		pitch_delta = linalg.to_radians(f32(mouse_y)) * -0.025

		player.camera_rot += {f32(pitch_delta), f32(yaw_delta), 0}
		player.camera_rot.x = math.clamp(player.camera_rot.x, -math.PI / 2, math.PI / 2)
		player.camera_rot.y = math.wrap(player.camera_rot.y, math.PI * 2)

		pitch := linalg.quaternion_angle_axis(player.camera_rot.x, Vec3{1, 0, 0})
		yaw := linalg.quaternion_angle_axis(player.camera_rot.y, Vec3{0, -1, 0})

		look := yaw * pitch

		camera_forward = linalg.quaternion_mul_vector3(player.rotation, Vec3{0, 0, -1})
		forward = linalg.quaternion_mul_vector3(yaw, Vec3{0, 0, -1})
		right = linalg.vector_cross3(forward, Vec3{0, 1, 0})

		tilt_angle := math.atan(linalg.dot(player.velocity / 100, right)) / 5
		player.camera_rot.z = linalg.lerp(player.camera_rot.z, tilt_angle, 20.0 * f32(dt))
		tilt := linalg.quaternion_angle_axis(player.camera_rot.z, Vec3{0, 0, -1})

		// General Movement

		player.rotation = look * tilt
	}

	f, r := axis_get_2d_normalized(.MoveForward, .MoveRight)
	move_forward, move_right := cast(f32)f, cast(f32)r

	move_direction := move_forward * forward + move_right * right
	move_direction_n := linalg.normalize0(move_forward * forward + move_right * right)

	if action_just_pressed(.ToggleNoclip) {
		player.move_mode += Move_Mode(1)
		player.move_mode = Move_Mode(int(player.move_mode) % len(Move_Mode))
	}

	set_listener_position(player.translation, camera_forward)

	switch player.move_mode {
	case .Ground:
		is_grounded := player.grounded

		acceleration: Vec3

		last_player_translation := player.translation

		player.fire_time += dt

		if action_is_pressed(.Sprint) {
			max_ground_speed = max_sprinting_ground_speed
		}

		if linalg.length(move_direction) > 0.01 {
			max_acceleration := is_grounded ? max_ground_acceleration : max_air_acceleration
			max_speed := is_grounded ? max_ground_speed : max_air_speed
			acceleration.xz += apply_acceleration(move_direction_n, max_speed, max_acceleration, player.velocity, is_grounded, dt).xz
		} else if is_grounded && linalg.length(player.velocity.xz) >= 1 {
			acceleration.xz +=
				apply_acceleration(-linalg.normalize0(player.velocity), 10, max_braking_acceleration, player.velocity, is_grounded, dt).xz
		} else if is_grounded && linalg.length(player.velocity.xz) < 1 {
			acceleration.xz = 0
			player.velocity = 0
		}

		if !is_grounded {
			player.velocity += {0, -70, 0} * f32(dt)
		}

		if action_just_pressed(.AltFire) {
			player.fire_mode = Fire_Mode((u32(player.fire_mode) + 1) % len(Fire_Mode))
		}

		if action_just_pressed(.Fire) {
			switch player.fire_mode {
			case .CreatePointLight:
				if player.fire_time > 0.1 {
					point_light := new_entity(PointLight)
					color: Vec3 = 0
					switch player.temp_cycler {
					case 0:
						color = {1, 0, 0}
					case 1:
						color = {0, 1, 0}
					case 2:
						color = {0, 0, 1}
					}

					init_point_light(point_light, player.translation, color, 10, 10)

					player.temp_cycler = (player.temp_cycler + 1) % 3

					player.fire_time = 0
				}
			case .LaunchForward:
				player.velocity.xz += move_direction_n.xz * 15
				player.velocity += {0, 1, 0} * 10
			}
		}

		player.velocity += acceleration * f32(dt)
		player.is_grounded_last_frame = is_grounded

		if action_is_pressed(.Jump) && is_grounded {
			player.velocity.y = 20
			player.is_grounded_last_frame = false
		}

		if player.is_grounded_last_frame {
			player.velocity.y = 0
		}

		displacement := player.velocity * f32(dt)

		new_center, new_velocity, moved_grounded, moved_normal := physics_mover_move(
			player.translation,
			displacement,
			player.velocity,
			player.is_grounded_last_frame,
			f32(dt),
		)
		player.translation = new_center
		player.velocity = new_velocity
		player.grounded = moved_grounded
		player.ground_normal = moved_normal

		if is_grounded {
			if player.footstep_distance_traveled > 3.5 && player.footstep_time > 0.15 {
				player.footstep_distance_traveled = 0
				player.footstep_time = 0

				STEP_TABLE: []Asset_Name = {
					.a_step1,
					.a_step2,
					.a_step3,
					.a_step4,
					.a_step5,
					.a_step6,
					.a_step7,
					.a_step8,
					.a_step9,
					.a_step10,
					.a_step11,
					.a_step12,
					.a_step13,
					.a_step14,
					.a_step15,
					.a_step16,
					.a_step17,
					.a_step18,
					.a_step19,
					.a_step20,
				}

				play_sound(STEP_TABLE[player.footstep])
				player.footstep += 1
				player.footstep = player.footstep % 20
			}

			player.footstep_distance_traveled += linalg.length(last_player_translation.xz - player.translation.xz)
		} else {
			player.footstep_distance_traveled = 2
		}

		player.footstep_time += dt

	case .Noclip:
		max_noclip_speed: f32 = 15

		if action_is_pressed(.Fire) {
			max_noclip_speed = 50
		}

		player.velocity = move_direction_n * max_noclip_speed

		if action_is_pressed(.Jump) {
			player.velocity.y = max_noclip_speed
		}
		if action_is_pressed(.Sprint) {
			player.velocity.y = -max_noclip_speed
		}

		player.translation += player.velocity * f32(dt)
	}

	player.eye_pos = player.translation + VEC3_UP * 1
}

average_normal :: proc(normals: []Vec3) -> (n: Vec3, ok: bool) {
	if len(normals) == 0 {
		return Vec3{}, false
	}

	for v in normals {
		n += v
	}

	n_len := linalg.length(n)

	if n_len <= 1e-4 {
		return Vec3{}, false
	}

	return n / n_len, true
}

project_onto_plane :: proc(v, n: Vec3) -> Vec3 {
	// remove component along n
	return v - n * linalg.dot(v, n)
}

// Returns the change in acceleration to apply to the player's current acceleration.
apply_acceleration :: proc(
	requested_dir: Vec3,
	max_speed: f32,
	max_acceleration: f32,
	current_velocity: Vec3,
	has_traction: bool,
	dt: f64,
) -> Vec3 {
	current_speed := linalg.dot(current_velocity, requested_dir)
	add_speed := max_speed - current_speed

	if add_speed < 0 && !has_traction {
		return 0
	}

	acceleration_change := ((max_speed * requested_dir) - current_velocity) / f32(dt)
	acceleration_change = linalg.clamp_length(acceleration_change, max_acceleration)

	return acceleration_change
}

get_current_projection_matrix :: proc() -> Mat4x4 {
	player := get_entity(game.state.player_id)
	//return player_get_projection_matrix(player)
	return player_get_projection_matrix(player)
}

get_current_projection_matrix_clipped :: proc(near, far: f32) -> Mat4x4 {
	player := get_entity(game.state.player_id)
	return player_get_projection_matrix_clipped(player, near, far)
}

get_current_view_matrix :: proc() -> Mat4x4 {
	player := get_entity(game.state.player_id)

	// TODO: Make this an editor flag!!!!
	when GAME_EDITOR {
		if .ViewFromThirdPerson in debug_vis_flags() {
			return linalg.matrix4_look_at_f32({0, 10, 0}, player.eye_pos, {0, 1, 0})
		}
	}

	return player_get_view_matrix(player)
}

get_current_projection_view_matrix :: proc() -> Mat4x4 {
	return get_current_projection_matrix() * get_current_view_matrix()
}

player_get_view_matrix :: proc(player: ^Player) -> Mat4x4 {
	translation := linalg.matrix4_translate(player != nil ? player.eye_pos : {})
	rotation := linalg.matrix4_from_quaternion(player != nil ? player.rotation : {})

	return linalg.inverse(linalg.mul(translation, rotation))
}

player_get_projection_matrix :: proc(player: ^Player, near: f32 = 0.1) -> Mat4x4 {
	aspect_ratio := f32(gfx.r_ctx.draw_extent.width) / f32(gfx.r_ctx.draw_extent.height)

	projection_matrix := gfx.matrix4_infinite_perspective_z0_f32(
		linalg.to_radians(player != nil ? player.camera_fov_deg : 0),
		aspect_ratio,
		near,
	)
	projection_matrix[1][1] *= -1.0

	return projection_matrix
}

player_get_projection_matrix_clipped :: proc(player: ^Player, near, far: f32) -> Mat4x4 {
	aspect_ratio := f32(gfx.r_ctx.draw_extent.width) / f32(gfx.r_ctx.draw_extent.height)

	projection_matrix := gfx.matrix4_perspective_z0_f32(
		linalg.to_radians(player != nil ? player.camera_fov_deg : 0),
		aspect_ratio,
		near,
		far,
	)
	projection_matrix[1][1] *= -1.0

	return projection_matrix
}

world_space_to_clip_space :: proc(view_projection: Mat4x4, vec: Vec3) -> ([2]f32, bool) {
	vec_p := view_projection * [4]f32{vec.x, vec.y, vec.z, 1.0}

	// reject points behind the camera
	if vec_p.w <= 0.0 {
		return [2]f32{}, false
	}

	clip_vec := vec_p.xyz / vec_p.w

	// NDC -> screen (no manual rejection of [-1,1] bounds)
	screen := (clip_vec.xy * 0.5 + 0.5) * [2]f32{f32(gfx.r_ctx.draw_extent.width), f32(gfx.r_ctx.draw_extent.height)}

	return screen, true
}
