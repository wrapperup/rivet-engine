package gfx

import "core:math"
import "core:math/linalg"

@(require_results)
matrix4_perspective_z0_f32 :: proc "contextless" (fovy, aspect, near, far: f32) -> (m: linalg.Matrix4f32) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = 1 / (tan_half_fovy)
	m[3, 2] = +1

	m[2, 2] = far / (far - near)
	m[2, 3] = -(far * near) / (far - near)

	m[2] = -m[2]

	return
}

@(require_results)
matrix_ortho3d_z0_f32 :: proc "contextless" (left, right, bottom, top, near, far: f32) -> (m: linalg.Matrix4f32) #no_bounds_check {
	m[0, 0] = +2 / (right - left)
	m[1, 1] = +2 / (top - bottom)
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[3, 3] = 1

	m[2, 2] = +1 / (far - near)
	m[2, 3] = -near / (far - near)

	m[2] = -m[2]

	return
}

@(require_results)
// Right-handed infinite reversed-Z: depth = near / -view_z.
// The near plane maps to 1 and infinity to 0, preserving distant float precision.
matrix4_infinite_perspective_reversed_z0_f32 :: proc "contextless" (fovy, aspect, near: f32) -> (m: linalg.Matrix4f32) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = 1 / (tan_half_fovy)
	m[3, 2] = +1

	m[2, 3] = near

	m[2] = -m[2]

	return
}
