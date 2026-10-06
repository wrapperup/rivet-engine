package game

import "core:math"
import "core:math/linalg"

import im "deps:odin-imgui"

DEFAULT_DEBUG_COLOR :: im.Vec4{1, 0, 0, 1}
DEBUG_COLOR_GOOD :: im.Vec4{0, 1, 0, 1}

debug_draw_line :: proc(pos0_ws, pos1_ws: Vec3, thickness: f32 = 1.0, color := DEFAULT_DEBUG_COLOR, dots: bool = false) {
	// TODO: cache this
	view_projection := get_current_projection_view_matrix()

	pos0_cs, ok := world_space_to_clip_space(view_projection, pos0_ws)
	pos1_cs, ok1 := world_space_to_clip_space(view_projection, pos1_ws)

	bl := im.GetBackgroundDrawList()
	col_u32 := im.GetColorU32ImVec4(color)

	if ok && ok1 {
		_debug_draw_line_impl(bl, pos0_cs, pos1_cs, thickness, col_u32)
	}

	if dots {
		pad: [2]f32 = 5

		if ok do _debug_draw_dot_impl(bl, pos0_cs, pad, col_u32)
		if ok1 do _debug_draw_dot_impl(bl, pos1_cs, pad, col_u32)
	}
}

_debug_draw_line_impl :: proc(dl: ^im.DrawList, pos0_cs, pos1_cs: Vec2, thickness: f32 = 1.0, color: u32) {
	im.DrawList_AddLine(dl, pos0_cs, pos1_cs, color, thickness)
}

debug_draw_dot :: proc(pos_ws: Vec3, half_size: f32 = 5.0, color := DEFAULT_DEBUG_COLOR) {
	// TODO: cache this
	bl := im.GetBackgroundDrawList()

	view_projection := get_current_projection_view_matrix()
	col_u32 := im.GetColorU32ImVec4(color)
	pos_cs, ok := world_space_to_clip_space(view_projection, pos_ws)

	if ok do _debug_draw_dot_impl(bl, pos_cs, half_size, col_u32)
}

_debug_draw_dot_impl :: proc(dl: ^im.DrawList, pos_cs: Vec2, half_size: Vec2, color: u32) {
	im.DrawList_AddRectFilled(dl, pos_cs - half_size.x, pos_cs + half_size.y, color)
}

debug_draw_capsule :: proc(
	center: Vec3,
	rotation: Quat,
	half_height: f32,
	radius: f32,
	segments: int = 16,
	lat_steps: int = 4,
	thickness: f32 = 1.0,
	color := DEFAULT_DEBUG_COLOR,
) {
	view_projection := get_current_projection_view_matrix()
	bl := im.GetBackgroundDrawList()
	col_u32 := im.GetColorU32ImVec4(color)

	// Local capsule axis is +Y
	local_axis := Vec3{0, 1, 0}
	axis := linalg.normalize(rotate_vec3(rotation, local_axis))

	// Compute the cylindrical section endpoints
	pos0 := center - axis * half_height
	pos1 := center + axis * half_height

	// === same wireframe code you already had ===

	tmp := Vec3{0, 1, 0}
	if math.abs(linalg.dot(axis, tmp)) > 0.9 do tmp = Vec3{1, 0, 0}

	u := linalg.normalize(linalg.cross(axis, tmp))
	v := linalg.normalize(linalg.cross(u, axis))

	// Cylinder longitudes
	for i in 0 ..< segments {
		theta := (math.TAU * f32(i)) / f32(segments)
		dir := u * math.cos(theta) + v * math.sin(theta)
		draw_line3(pos0 + dir * radius, pos1 + dir * radius, view_projection, bl, col_u32, thickness)
	}

	// End rings
	for i in 0 ..< segments {
		t0 := (math.TAU * f32(i)) / f32(segments)
		t1 := (math.TAU * f32(i + 1)) / f32(segments)
		d0 := u * math.cos(t0) + v * math.sin(t0)
		d1 := u * math.cos(t1) + v * math.sin(t1)

		draw_line3(pos0 + d0 * radius, pos0 + d1 * radius, view_projection, bl, col_u32, thickness)
		draw_line3(pos1 + d0 * radius, pos1 + d1 * radius, view_projection, bl, col_u32, thickness)
	}

	// Hemisphere latitude rings + stitching
	if lat_steps > 0 {
		step := (0.5 * math.PI) / f32(lat_steps + 1)

		// draw rings
		for j in 1 ..< (lat_steps + 1) {
			phi := f32(j) * step
			c := math.cos(phi)
			s := math.sin(phi)

			draw_ring(pos0 - axis * (radius * c), radius * s, u, v, segments, view_projection, bl, col_u32, thickness)
			draw_ring(pos1 + axis * (radius * c), radius * s, u, v, segments, view_projection, bl, col_u32, thickness)
		}

		// stitch adjacent latitude rings within each hemisphere
		for j in 1 ..< (lat_steps) {
			phi_a := f32(j) * step
			phi_b := f32(j + 1) * step

			// pos0 side
			c0a := pos0 - axis * (radius * math.cos(phi_a)); r0a := radius * math.sin(phi_a)
			c0b := pos0 - axis * (radius * math.cos(phi_b)); r0b := radius * math.sin(phi_b)
			for i in 0 ..< segments {
				theta := (math.TAU * f32(i)) / f32(segments)
				dir := u * math.cos(theta) + v * math.sin(theta)
				draw_line3(c0a + dir * r0a, c0b + dir * r0b, view_projection, bl, col_u32, thickness)
			}

			// pos1 side
			c1a := pos1 + axis * (radius * math.cos(phi_a)); r1a := radius * math.sin(phi_a)
			c1b := pos1 + axis * (radius * math.cos(phi_b)); r1b := radius * math.sin(phi_b)
			for i in 0 ..< segments {
				theta := (math.TAU * f32(i)) / f32(segments)
				dir := u * math.cos(theta) + v * math.sin(theta)
				draw_line3(c1a + dir * r1a, c1b + dir * r1b, view_projection, bl, col_u32, thickness)
			}
		}

		// stitch last latitude ring to cylinder rim
		phi_last := f32(lat_steps) * step
		c0_last := pos0 - axis * (radius * math.cos(phi_last)); r0_last := radius * math.sin(phi_last)
		c1_last := pos1 + axis * (radius * math.cos(phi_last)); r1_last := radius * math.sin(phi_last)
		for i in 0 ..< segments {
			theta := (math.TAU * f32(i)) / f32(segments)
			dir := u * math.cos(theta) + v * math.sin(theta)
			draw_line3(c0_last + dir * r0_last, pos0 + dir * radius, view_projection, bl, col_u32, thickness)
			draw_line3(c1_last + dir * r1_last, pos1 + dir * radius, view_projection, bl, col_u32, thickness)
		}
	}

	// --- Add meridian arcs over each dome to "cap" the poles ---
	meridians := segments // tweak to taste (2, 4, or 6 are nice)
	meridian_steps := max(lat_steps + 1, 6) // at least a few segments even if lat_steps == 0

	// pos0 hemisphere (toward -axis)
	draw_meridian_hemisphere(pos0, axis, -1.0, u, v, radius, meridians, meridian_steps, view_projection, bl, col_u32, thickness)

	// pos1 hemisphere (toward +axis)
	draw_meridian_hemisphere(pos1, axis, +1.0, u, v, radius, meridians, meridian_steps, view_projection, bl, col_u32, thickness)
}

// Wireframe sphere using your existing draw_line3 and draw_ring helpers.
debug_draw_sphere :: proc(
	center: Vec3,
	radius: f32,
	segments: int = 24, // azimuth resolution
	stacks: int = 8, // number of latitude rings (excluding the two poles)
	meridians: int = 8, // number of pole-to-pole arcs
	thickness: f32 = 1.0,
	color := im.Vec4{1, 1, 0, 1},
) {
	view_projection := get_current_projection_view_matrix()
	bl := im.GetBackgroundDrawList()
	col_u32 := im.GetColorU32ImVec4(color)

	axis := linalg.normalize(Vec3{0, 1, 0})
	tmp := Vec3{0, 0, 1}
	if math.abs(linalg.dot(axis, tmp)) > 0.9 do tmp = Vec3{1, 0, 0}
	u := linalg.normalize(linalg.cross(axis, tmp))
	v := linalg.normalize(linalg.cross(u, axis))

	for j in 1 ..< (stacks) {
		phi := (-0.5 * math.PI) + (math.PI * f32(j) / f32(stacks))
		ring_center := center + axis * (radius * math.sin(phi))
		ring_radius := radius * math.cos(phi)
		if ring_radius > 0.0 {
			draw_ring(ring_center, ring_radius, u, v, segments, view_projection, bl, col_u32, thickness)
		}
	}

	draw_ring(center, radius, u, v, segments, view_projection, bl, col_u32, thickness)

	meridian_steps := math.max(stacks * 2, 16) // smoothness of each arc
	for k in 0 ..< meridians {
		theta := (math.TAU * f32(k)) / f32(meridians)
		dir := u * math.cos(theta) + v * math.sin(theta)

		// March φ from -π/2 to +π/2 and connect successive points
		prev_phi := -0.5 * f32(math.PI)
		prev_pt := center + axis * (radius * math.sin_f32(prev_phi)) + dir * (radius * math.cos_f32(prev_phi))
		for s in 1 ..< (meridian_steps + 1) {
			phi := (-0.5 * math.PI) + (math.PI * f32(s) / f32(meridian_steps))
			pt := center + axis * (radius * math.sin(phi)) + dir * (radius * math.cos(phi))
			draw_line3(prev_pt, pt, view_projection, bl, col_u32, thickness)
			prev_phi = phi
			prev_pt = pt
		}
	}
}

// --- helpers ---

draw_line3 :: proc(a, b: Vec3, view_projection: Mat4x4, bl: ^im.DrawList, col_u32: u32, thickness: f32) {
	a_cs, ok0 := world_space_to_clip_space(view_projection, a)
	b_cs, ok1 := world_space_to_clip_space(view_projection, b)
	if ok0 && ok1 {
		_debug_draw_line_impl(bl, a_cs, b_cs, thickness, col_u32)
	}
}

draw_ring :: proc(
	center: Vec3,
	radius: f32,
	u, v: Vec3,
	segments: int,
	view_projection: Mat4x4,
	bl: ^im.DrawList,
	col_u32: u32,
	thickness: f32,
) {
	for i in 0 ..< segments {
		t0 := (math.TAU * f32(i)) / f32(segments)
		t1 := (math.TAU * f32(i + 1)) / f32(segments)
		p0 := center + (u * math.cos(t0) + v * math.sin(t0)) * radius
		p1 := center + (u * math.cos(t1) + v * math.sin(t1)) * radius
		draw_line3(p0, p1, view_projection, bl, col_u32, thickness)
	}
}

rotate_vec3 :: proc(q: Quat, v: Vec3) -> Vec3 {
	qv := Vec3{q.x, q.y, q.z}
	uv := linalg.cross(qv, v)
	uuv := linalg.cross(qv, uv)
	uv *= (2.0 * q.w)
	uuv *= 2.0
	return v + uv + uuv
}

draw_meridian_hemisphere :: proc(
	base_center: Vec3, // pos0 for the -axis hemisphere, pos1 for the +axis hemisphere
	axis: Vec3, // unit axis
	axis_sign: f32, // -1 for pos0 side, +1 for pos1 side
	u, v: Vec3, // orthonormal frame around axis
	radius: f32,
	meridians: int, // how many azimuths (e.g., 4)
	meridian_steps: int, // how many steps from pole->rim per meridian (>= 2)
	view_projection: Mat4x4,
	bl: ^im.DrawList,
	col_u32: u32,
	thickness: f32,
) {
	if meridians < 1 do return
	if meridian_steps < 2 do return

	step_phi := (0.5 * math.PI) / f32(meridian_steps)

	for k in 0 ..< meridians {
		theta := (math.TAU * f32(k)) / f32(meridians)
		dir := u * math.cos(theta) + v * math.sin(theta)

		prev_phi := f32(0.0)
		prev_center := base_center + axis * (axis_sign * radius * math.cos(prev_phi))
		prev_point := prev_center + dir * (radius * math.sin(prev_phi)) // = pole

		for s in 1 ..< (meridian_steps + 1) {
			phi := f32(s) * step_phi
			center := base_center + axis * (axis_sign * radius * math.cos(phi))
			point := center + dir * (radius * math.sin(phi))

			// connect prev -> current
			draw_line3(prev_point, point, view_projection, bl, col_u32, thickness)

			prev_phi = phi
			prev_center = center
			prev_point = point
		}
	}
}
