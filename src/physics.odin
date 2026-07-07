package game

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/linalg"

import b3 "vendor:box3d"

PHYS_CATEGORY_ALL :: max(u64)

phys_query_filter :: proc "contextless" () -> b3.QueryFilter {
	return {categoryBits = PHYS_CATEGORY_ALL, maskBits = PHYS_CATEGORY_ALL}
}

// A per-object surface material. Matches the single tuple PhysX used everywhere (0.9/0.5/0.1).
phys_default_material :: proc "contextless" () -> b3.SurfaceMaterial {
	return {friction = 0.5, restitution = 0.1}
}

physics_init :: proc() {
	def := b3.DefaultWorldDef()
	def.gravity = {0, -9.81 * 2, 0} // matches the old PhysX scene gravity
	def.workerCount = 1 // single-threaded; no task callbacks needed
	game.phys.world = b3.CreateWorld(def)
	assert(b3.World_IsValid(game.phys.world))
}

physics_step :: proc(dt: f32) {
	// 4 sub-steps is the Box3D-recommended default.
	b3.World_Step(game.phys.world, dt, 4)
}

physics_shutdown :: proc() {
	if b3.World_IsValid(game.phys.world) {
		b3.DestroyWorld(game.phys.world)
		game.phys.world = b3.nullWorldId
	}
}

// ---------------------------------------------------------------------------
// Character mover (replaces PxController)
// ---------------------------------------------------------------------------
PHYS_MAX_PLANES :: 32
PHYS_GROUND_SNAP :: 0.4
PHYS_LAND_EPS :: 0.05
PHYS_STEP_HEIGHT :: 4.0

PHYS_MOVER_ITERATIONS :: 4

Mover_Ctx :: struct {
	planes: [PHYS_MAX_PLANES]b3.CollisionPlane,
	count:  int,
}

phys_add_plane :: proc "contextless" (m: ^Mover_Ctx, cp: b3.CollisionPlane) {
	for i in 0 ..< m.count {
		e := m.planes[i].plane
		if linalg.dot(e.normal, cp.plane.normal) > 0.995 && abs(e.offset - cp.plane.offset) < 0.05 {
			return
		}
	}
	if m.count >= PHYS_MAX_PLANES do return
	m.planes[m.count] = cp
	m.count += 1
}

phys_walkable_min_y :: proc "contextless" () -> f32 {
	return math.cos(slope_limit_deg * math.RAD_PER_DEG)
}

phys_clip_walls :: proc(v: Vec3, ctx: ^Mover_Ctx) -> Vec3 {
	min_y := phys_walkable_min_y()
	walls: [PHYS_MAX_PLANES]b3.CollisionPlane
	n := 0
	for i in 0 ..< ctx.count {
		if ctx.planes[i].plane.normal.y < min_y {
			walls[n] = ctx.planes[i]
			n += 1
		}
	}
	if n == 0 do return v
	return b3.ClipVector(v, &walls[0], c.int(n))
}

phys_collect_planes :: proc "c" (shape: b3.ShapeId, prs: [^]b3.PlaneResult, count: c.int, ctx: rawptr) -> bool {
	m := cast(^Mover_Ctx)ctx
	for i in 0 ..< int(count) {
		phys_add_plane(m, b3.CollisionPlane{plane = prs[i].plane, pushLimit = max(f32), clipVelocity = true})
	}
	return true
}

phys_collide_and_solve :: proc(mover: ^b3.Capsule, origin: b3.Pos, filter: b3.QueryFilter, all: ^Mover_Ctx) -> Mover_Ctx {
	ctx: Mover_Ctx
	b3.World_CollideMover(game.phys.world, origin, mover^, filter, phys_collect_planes, &ctx)
	if ctx.count > 0 {
		res := b3.SolvePlanes({0, 0, 0}, &ctx.planes[0], c.int(ctx.count))
		mover.center1 += res.delta
		mover.center2 += res.delta
		for i in 0 ..< ctx.count {
			phys_add_plane(all, ctx.planes[i])
		}
	}
	return ctx
}

phys_slide :: proc(mover: ^b3.Capsule, origin: b3.Pos, filter: b3.QueryFilter, displacement: Vec3, all: ^Mover_Ctx) {
	delta := displacement
	for _ in 0 ..< PHYS_MOVER_ITERATIONS {
		if linalg.length(delta) < 1e-6 do break

		frac := b3.World_CastMover(game.phys.world, origin, mover^, delta, filter, nil, nil)
		safe := delta * frac
		mover.center1 += safe
		mover.center2 += safe

		ctx := phys_collide_and_solve(mover, origin, filter, all)

		if frac >= 1 do break // consumed the whole displacement

		// Slide the leftover along walls only — never along walkable floor/edge contacts.
		delta = phys_clip_walls(delta * (1 - frac), &ctx)
	}
}

phys_ground_probe :: proc(mover: b3.Capsule, max_snap: f32) -> (grounded: bool, normal: Vec3) {
	min_y := phys_walkable_min_y()
	base := transmute(Vec3)mover.center1

	// Keeps us grounded.
	if r := b3.World_CastRayClosest(game.phys.world, transmute(b3.Pos)base, {0, -(capsule_radius + max_snap + 0.05), 0}, phys_query_filter());
	   r.hit && r.normal.y >= min_y {
		return true, r.normal
	}

	START_LIFT :: f32(0.05)
	start := base + {0, START_LIFT, 0}
	point, sweep_n, hit := query_sweep_sphere(start, start + {0, -(START_LIFT + max_snap), 0}, capsule_radius)
	if !hit {
        return false, VEC3_UP
    }

	if sweep_n.y >= min_y do return true, sweep_n

	to_surface := linalg.normalize0(Vec3{point.x - base.x, 0, point.z - base.z})
	from := point + to_surface * 0.05 + Vec3{0, 0.05, 0}
	res := b3.World_CastRayClosest(game.phys.world, transmute(b3.Pos)from, {0, -(max_snap + 0.1), 0}, phys_query_filter())
	if !res.hit || res.normal.y < min_y do return false, VEC3_UP
	return true, res.normal
}

// Unreal-style discrete step-up
phys_try_step_up :: proc(
	mover: ^b3.Capsule,
	origin: b3.Pos,
	filter: b3.QueryFilter,
	forward: Vec3,
	floor_base_y: f32,
	all: ^Mover_Ctx,
) -> bool {
	saved := mover^

	// 1. Sweep up by the step height (a ceiling right above caps how far we can rise).
	up := f32(PHYS_STEP_HEIGHT)
	up_frac := b3.World_CastMover(game.phys.world, origin, mover^, {0, up, 0}, filter, nil, nil)
	if up_frac <= 0.01 do return false // no headroom -> can't step, leave the wall slide as-is
	up *= up_frac
	mover.center1 += {0, up, 0}
	mover.center2 += {0, up, 0}

	fwd_pre := transmute(Vec3)mover.center1
	tmp: Mover_Ctx
	phys_slide(mover, origin, filter, forward, &tmp)
	advanced := linalg.length((transmute(Vec3)mover.center1 - fwd_pre) * {1, 0, 1})
	if advanced < linalg.length(forward) * 0.5 {
		mover^ = saved
		return false
	}

	center_now := (transmute(Vec3)mover.center1 + transmute(Vec3)mover.center2) * 0.5
	down := up + PHYS_GROUND_SNAP
	land_pt, _, land_hit := query_sweep_capsule(center_now, center_now + {0, -down, 0}, capsule_radius, capsule_half_height)
	if !land_hit {
		mover^ = saved // nothing to land on -> would drop into a hole, reject the step
		return false
	}

	if land_pt.y - floor_base_y > PHYS_STEP_HEIGHT + 0.02 {
		mover^ = saved
		return false
	}

	down_frac := b3.World_CastMover(game.phys.world, origin, mover^, {0, -down, 0}, filter, nil, nil)
	mover.center1 += {0, -down * down_frac, 0}
	mover.center2 += {0, -down * down_frac, 0}
	land_grounded, _ := phys_ground_probe(mover^, PHYS_GROUND_SNAP)
	if !land_grounded {
		mover^ = saved
		return false
	}

	for i in 0 ..< tmp.count do phys_add_plane(all, tmp.planes[i])
	return true
}

physics_mover_move :: proc(
	center: Vec3,
	displacement: Vec3,
	velocity: Vec3,
	snap_to_ground: bool,
	dt: f32,
) -> (
	new_center: Vec3,
	new_velocity: Vec3,
	grounded: bool,
	ground_normal: Vec3,
) {
	origin := b3.Pos{0, 0, 0}
	filter := phys_query_filter()
	ground_normal = VEC3_UP

	mover := b3.Capsule {
		center1 = center - {0, capsule_half_height, 0},
		center2 = center + {0, capsule_half_height, 0},
		radius  = capsule_radius,
	}

	all: Mover_Ctx

	if snap_to_ground {
		floor_base_y := mover.center1.y - capsule_radius // capsule bottom = the floor we're standing on
		horiz := Vec3{displacement.x, 0, displacement.z}
		requested := linalg.length(horiz)

		pre := transmute(Vec3)mover.center1
		phys_slide(&mover, origin, filter, horiz, &all)
		moved := linalg.length((transmute(Vec3)mover.center1 - pre) * {1, 0, 1})

		blocked := requested > 1e-6 && moved < requested * 0.99
		stepped := false
		if blocked {
			remaining := horiz * (1 - moved / requested)
			stepped = phys_try_step_up(&mover, origin, filter, remaining, floor_base_y, &all)
		}

		down_frac := b3.World_CastMover(game.phys.world, origin, mover, {0, -PHYS_GROUND_SNAP, 0}, filter, nil, nil)
		snap_dist := PHYS_GROUND_SNAP * down_frac
		if down_frac < 1 && snap_dist > 0.02 {
			mover.center1 += {0, -snap_dist, 0}
			mover.center2 += {0, -snap_dist, 0}
		}
		grounded, ground_normal = phys_ground_probe(mover, PHYS_GROUND_SNAP)

		new_velocity = (blocked && !stepped) ? phys_clip_walls(velocity, &all) : velocity
	} else {
		phys_slide(&mover, origin, filter, displacement, &all)
		new_velocity = phys_clip_walls(velocity, &all)

		// Detect landing, but only while descending, so a rising jump isn't re-grounded by the ray.
		if velocity.y <= 0 {
			grounded, ground_normal = phys_ground_probe(mover, PHYS_LAND_EPS)
			if grounded {
				// Plant on the floor immediately.
				drop := capsule_radius + PHYS_GROUND_SNAP
				down_frac := b3.World_CastMover(game.phys.world, origin, mover, {0, -drop, 0}, filter, nil, nil)
				if down_frac > 0 && down_frac < 1 {
					mover.center1 += {0, -drop * down_frac, 0}
					mover.center2 += {0, -drop * down_frac, 0}
				}
			}
		}
	}

	new_center = (mover.center1 + mover.center2) * 0.5
	return new_center, new_velocity, grounded, ground_normal
}

query_raycast_single :: proc(origin: Vec3, unit_dir: Vec3, distance: f32, debug := false) -> (point: Vec3, normal: Vec3, hit: bool) {
	res := b3.World_CastRayClosest(game.phys.world, origin, unit_dir * distance, phys_query_filter())

	point = Vec3(res.point)
	normal = res.normal
	hit = res.hit

	if debug && hit {
		debug_draw_line(origin, point, dots = true)
		debug_draw_line(point, point + normal, dots = false)
	}

	return point, normal, hit
}

Cast_Ctx :: struct {
	hit:      bool,
	point:    Vec3,
	normal:   Vec3,
	fraction: f32,
}

phys_closest_cast :: proc "c" (
	shape: b3.ShapeId,
	point: b3.Pos,
	normal: b3.Vec3,
	fraction: f32,
	material_id: u64,
	tri: c.int,
	child: c.int,
	ctx: rawptr,
) -> f32 {
	cc := cast(^Cast_Ctx)ctx
	cc.hit = true
	cc.point = Vec3(point)
	cc.normal = normal
	cc.fraction = fraction
	return fraction
}

phys_sweep_proxy :: proc(start, end: Vec3, proxy: b3.ShapeProxy, debug: bool) -> (point: Vec3, normal: Vec3, hit: bool) {
	cc: Cast_Ctx
	_ = b3.World_CastShape(game.phys.world, start, proxy, end - start, phys_query_filter(), phys_closest_cast, &cc)

	if debug {
		color := cc.hit ? DEBUG_COLOR_GOOD : DEFAULT_DEBUG_COLOR
		debug_draw_line(start, end, color = color)
	}

	return cc.point, cc.normal, cc.hit
}

query_sweep_capsule :: proc(start, end: Vec3, radius, half_height: f32, debug := false) -> (point: Vec3, normal: Vec3, hit: bool) {
	pts := [2]b3.Vec3{{0, -half_height, 0}, {0, half_height, 0}}
	proxy := b3.ShapeProxy {
		points = &pts[0],
		count  = 2,
		radius = radius,
	}
	return phys_sweep_proxy(start, end, proxy, debug)
}

query_sweep_sphere :: proc(start, end: Vec3, radius: f32, debug := false) -> (point: Vec3, normal: Vec3, hit: bool) {
	pt := b3.Vec3{0, 0, 0}
	proxy := b3.ShapeProxy {
		points = &pt,
		count  = 1,
		radius = radius,
	}
	return phys_sweep_proxy(start, end, proxy, debug)
}

matrix_from_transform :: proc(transform: b3.WorldTransform) -> matrix[4, 4]f32 {
	translation := linalg.matrix4_translate_f32(Vec3(transform.p))
	rotation := linalg.matrix4_from_quaternion(transform.q)
	return translation * rotation
}
