package game

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/linalg"

import b3 "vendor:box3d"

// Box3D uses 64-bit category/mask filtering. The game barely filters today, so queries and
// the character mover collide against everything by default. Tag a shape's category here if
// you need to exclude it from a query later.
PHYS_CATEGORY_ALL :: max(u64)

phys_query_filter :: proc "contextless" () -> b3.QueryFilter {
	return {categoryBits = PHYS_CATEGORY_ALL, maskBits = PHYS_CATEGORY_ALL}
}

// A per-object surface material. Matches the single tuple PhysX used everywhere (0.9/0.5/0.1).
phys_default_material :: proc "contextless" () -> b3.SurfaceMaterial {
	return {friction = 0.5, restitution = 0.1}
}

// ---------------------------------------------------------------------------
// World lifecycle + step
// ---------------------------------------------------------------------------

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

// Distinct contact planes kept per mover move. CollideMover reports one plane per overlapping
// triangle, so a flat floor alone emits dozens of (near) coplanar planes. We merge those on the
// way in (see phys_add_plane), so this only needs to hold *distinct* surfaces — 32 is plenty.
PHYS_MAX_PLANES :: 32

// Ground-snap distance. After the horizontal move we probe straight down this far and, if we hit,
// snap the capsule to the surface. This keeps the player glued to ramps and small steps when
// walking downhill without biasing the horizontal cast. Doubles as the max downward step height.
PHYS_GROUND_SNAP :: 0.4

// Max height of a step/ledge the player can climb. The capsule is moved this far up before its
// horizontal slide, so anything up to this tall is cleared and stepped onto. PhysX used 1.0; keep
// it modest so you can't wall-climb in chunks.
PHYS_STEP_HEIGHT :: 0.5

PHYS_MOVER_ITERATIONS :: 4

@(private = "file")
Mover_Ctx :: struct {
	planes: [PHYS_MAX_PLANES]b3.CollisionPlane,
	count:  int,
}

// Add a plane, merging it with an existing near-coplanar one. This is the important bit for solving
// accuracy: without it a triangle-mesh floor floods the buffer with identical "up" planes and
// crowds out genuinely different surfaces (walls, the real ground under dense geometry), which is
// what let the player sink through near complex meshes. Merging keeps each distinct surface once.
@(private = "file")
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

// A contact is walkable ground (rather than a wall or too-steep slope) when its normal is within
// the slope limit of straight up. Kept in sync with the player's slope_limit_deg.
@(private = "file")
phys_walkable_min_y :: proc "contextless" () -> f32 {
	return math.cos(slope_limit_deg * math.RAD_PER_DEG)
}

// Clip `v` only against wall / non-walkable planes, leaving walkable floor and edge contacts alone.
// This is the "walkable floor" rule: standable ground is treated as flat underfoot, so only genuine
// walls and steep slopes redirect movement. Without it, the ~45deg blended normal at a floor's
// convex edge would slide the player off it.
@(private = "file")
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

@(private = "file")
phys_collect_planes :: proc "c" (shape: b3.ShapeId, prs: [^]b3.PlaneResult, count: c.int, ctx: rawptr) -> bool {
	m := cast(^Mover_Ctx)ctx
	for i in 0 ..< int(count) {
		phys_add_plane(m, b3.CollisionPlane{plane = prs[i].plane, pushLimit = max(f32), clipVelocity = true})
	}
	return true
}

@(private = "file")
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

// The core collide-and-slide loop: advance `mover` by `displacement`, stopping at each hit and
// sliding the remainder along the contact planes. Accumulates (merged) planes into `all`.
//
// A single CastMover scales the *whole* displacement by one fraction, so any immediate contact
// would kill horizontal motion too. Casting the safe portion, then sliding the leftover, avoids
// that. The caller passes a purely horizontal displacement when grounded, so the vertical
// ground-stick (handled by the snap in physics_mover_move) can never block horizontal movement.
@(private = "file")
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

// Probe the geometry straight below the capsule with a downward ray to get the true surface normal
// — the actual floor/step-top normal ("up"), not the capsule-radial contact normal the mover
// reports at a convex edge (which points back into the capsule and reads as a ~45deg slope). This
// is what lets step and floor edges register as flat, standable ground instead of steep slopes.
@(private = "file")
phys_ground_ray :: proc(mover: b3.Capsule) -> (grounded: bool, normal: Vec3) {
	dist := capsule_radius + PHYS_GROUND_SNAP + 0.05
	res := b3.World_CastRayClosest(game.phys.world, transmute(b3.Pos)mover.center1, {0, -dist, 0}, phys_query_filter())
	if !res.hit do return false, VEC3_UP
	if res.normal.y < phys_walkable_min_y() do return false, res.normal // too steep to stand on
	return true, res.normal
}

// Moves a capsule (centered at `center`) by `displacement`, resolving collisions and stepping up
// small ledges. Returns the new center, the velocity after clipping against walls, and whether it
// ended on standable ground plus that ground's true normal (from a downward geometry probe, not the
// capsule contact normals). `snap_to_ground` means the player was grounded and isn't jumping.
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
	origin := b3.Pos{0, 0, 0} // world-absolute positions; fine at this game's scale
	filter := phys_query_filter()
	ground_normal = VEC3_UP

	mover := b3.Capsule {
		center1 = center - {0, capsule_half_height, 0},
		center2 = center + {0, capsule_half_height, 0},
		radius  = capsule_radius,
	}

	// Planes gathered during the horizontal slide (walls we hit), used to clip velocity.
	all: Mover_Ctx

	if snap_to_ground {
		// Grounded movement: "move raised, then drop onto the floor". We lift the capsule by a step
		// height, slide horizontally, then drop back down onto whatever floor is beneath us.
		//
		// Moving raised is the whole trick: the capsule bottom is above anything up to a step tall,
		// so step nosings, ledge edges and low bumps never touch it — they can't inject the
		// capsule-radial ~45deg contact normals that were sliding us off step edges. Only real walls
		// (taller than a step) block. The drop then plants us on the floor, which climbs up-steps,
		// follows down-steps and ramps for free, and keeps horizontal speed constant on slopes.
		lift := f32(PHYS_STEP_HEIGHT)
		up_frac := b3.World_CastMover(game.phys.world, origin, mover, {0, lift, 0}, filter, nil, nil)
		lift *= up_frac // a low ceiling caps how far we can rise
		mover.center1 += {0, lift, 0}
		mover.center2 += {0, lift, 0}

		// Horizontal slide at the raised height. Walls block; floor/steps below don't touch us.
		phys_slide(&mover, origin, filter, {displacement.x, 0, displacement.z}, &all)

		// Drop back to the floor — up to the lift plus a snap distance (the max down-step height).
		drop := lift + PHYS_GROUND_SNAP
		down_frac := b3.World_CastMover(game.phys.world, origin, mover, {0, -drop, 0}, filter, nil, nil)
		if down_frac < 1 {
			// Found floor within reach: plant on it.
			mover.center1 += {0, -drop * down_frac, 0}
			mover.center2 += {0, -drop * down_frac, 0}
			grounded, ground_normal = phys_ground_ray(mover)
		} else {
			// No floor within a step down — we walked off a ledge. Undo the lift and fall next frame.
			mover.center1 += {0, -lift, 0}
			mover.center2 += {0, -lift, 0}
			grounded = false
		}
		new_velocity = phys_clip_walls(velocity, &all)
	} else {
		phys_slide(&mover, origin, filter, displacement, &all)
		new_velocity = phys_clip_walls(velocity, &all)
		// Detect landing, but only while descending, so a rising jump isn't re-grounded by the ray.
		if velocity.y <= 0 {
			grounded, ground_normal = phys_ground_ray(mover)
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

// ---------------------------------------------------------------------------
// Queries (no live callers today; kept as usable Box3D-native helpers)
// ---------------------------------------------------------------------------

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

@(private = "file")
Cast_Ctx :: struct {
	hit:      bool,
	point:    Vec3,
	normal:   Vec3,
	fraction: f32,
}

@(private = "file")
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
	return fraction // clip the cast to this hit so we keep the closest
}

@(private = "file")
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

// Kept from the old file — some callers build matrices from physics transforms.
matrix_from_transform :: proc(transform: b3.WorldTransform) -> matrix[4, 4]f32 {
	translation := linalg.matrix4_translate_f32(Vec3(transform.p))
	rotation := linalg.matrix4_from_quaternion(transform.q)
	return translation * rotation
}
