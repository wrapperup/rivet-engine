package game

import "core:math"
VEC3_UP :: Vec3{0, 1, 0}

// f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32
Mat4x2 :: matrix[4, 2]f32

Mat3x4 :: matrix[3, 4]f32
Mat3x3 :: matrix[3, 3]f32
Mat3x2 :: matrix[3, 2]f32

Mat2x4 :: matrix[2, 4]f32
Mat2x3 :: matrix[2, 3]f32
Mat2x2 :: matrix[2, 2]f32

Quat :: quaternion128

Aabb :: struct {
	min: Vec3,
	max: Vec3,
}

aabb_center :: proc(box: Aabb) -> Vec3 {
	offset := (box.max - box.min) / 2.0
	return box.min + offset
}

debug_draw_aabb :: proc(box: Aabb) {
	offset := box.max - box.min

	debug_draw_dot(box.min)

	debug_draw_dot(box.min + {offset.x, 0, 0})
	debug_draw_dot(box.min + {0, offset.y, 0})
	debug_draw_dot(box.min + {0, 0, offset.z})

	debug_draw_dot(box.min + {offset.x, offset.y, 0})
	debug_draw_dot(box.min + {0, offset.y, offset.z})
	debug_draw_dot(box.min + {offset.x, 0, offset.z})

	debug_draw_dot(box.max)
}

is_finite :: proc "contextless" (value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}
