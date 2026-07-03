package game

import "core:math/linalg/hlsl"

import px "deps:physx-odin"

import "gfx"

@(entity)
StaticMesh :: struct {
	using entity: ^Entity,
	mesh:         GPUMeshBuffers,
	material:     MaterialId,
	body:         ^px.RigidStatic,
	hidden:       bool,
}

// `path` is a mesh file relative to the working dir (e.g. "assets/meshes/static/sm_map_test.glb").
// translation/rotation place both the rendered mesh and its physics body. Defaults keep it at the
// origin with identity rotation — a zero-value quaternion would fail PhysX's pose.isSane() check.
init_static_mesh :: proc(
	static_mesh: ^StaticMesh,
	path: string,
	material: MaterialId,
	translation: Vec3 = {0, 0, 0},
	rotation: Quat = Quat(1),
) {
	mesh, ok := load_mesh_from_file(path)
	assert(ok)

	gpu_mesh := upload_mesh_to_gpu(mesh)
	defer_destroy_gpu_mesh(&gfx.r_ctx.global_arena, gpu_mesh)

	tolerances_scale := px.tolerances_scale_new(1, 10)
	params := px.cooking_params_new(tolerances_scale)

	points_data := make([]hlsl.float3, len(mesh.vertices))
	defer delete(points_data)

	for vertex, i in mesh.vertices {
		points_data[i] = vertex.position
	}

	mesh_desc := px.triangle_mesh_desc_new()

	mesh_desc.points.count = u32(len(mesh.vertices))
	mesh_desc.points.stride = size_of(hlsl.float3)
	mesh_desc.points.data = raw_data(points_data)

	mesh_desc.triangles.count = u32(len(mesh.indices)) / 3
	mesh_desc.triangles.stride = 3 * size_of(u32)
	mesh_desc.triangles.data = raw_data(mesh.indices)

	// valid := px.validate_triangle_mesh(params, mesh_desc)
	// assert(valid, "Mesh is not valid.")

	result: px.TriangleMeshCookingResult
	tri_mesh := px.create_triangle_mesh(params, mesh_desc, px.physics_get_physics_insertion_callback_mut(game.phys.physics), &result)
	assert(result == .Success)

	geometry := px.triangle_mesh_geometry_new(tri_mesh, px.mesh_scale_new_1(1), {})

	phys_material := px.physics_create_material_mut(game.phys.physics, 0.9, 0.5, 0.1)

	static_mesh.body = px.create_static(
		game.phys.physics,
		px.transform_new_5(transmute(px.Vec3)translation, transmute(px.Quat)rotation),
		&geometry,
		phys_material,
		px.transform_new_1({0, 0, 0}),
	)
	assert(static_mesh.body != nil)

	px.scene_add_actor_mut(game.phys.scene, static_mesh.body, nil)

	static_mesh.translation = translation
	static_mesh.rotation = rotation
	static_mesh.mesh = gpu_mesh
	static_mesh.material = material
}

// Release the PhysX body. Releasing an actor also removes it from its scene, so scene reload
// doesn't accumulate invisible colliders. NOTE: the GPU mesh is still deferred to gfx global_arena
// in init, so it survives reload (memory grows on repeated reloads) — route it through the scene
// arena when the asset_name refactor lands.
static_mesh_destroy :: proc(static_mesh: ^StaticMesh) {
	if static_mesh.body != nil {
		px.actor_release_mut(static_mesh.body)
		static_mesh.body = nil
	}
}
