package game

import b3 "vendor:box3d"

import "gfx"

@(entity)
StaticMesh :: struct {
	using entity: ^Entity,
	mesh:         GPUMeshBuffers,
	material:     MaterialId,
	body:         b3.BodyId,
	// Box3D keeps a reference to this baked mesh for the shape's lifetime, so we own it and must
	// free it after the body is destroyed.
	mesh_data:    ^b3.MeshData,
	hidden:       bool,
}

// `path` is a mesh file relative to the working dir (e.g. "assets/meshes/static/sm_map_test.glb").
// translation/rotation place both the rendered mesh and its physics body. Defaults keep it at the
// origin with identity rotation.
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

	// Bake the triangle soup into a Box3D collision mesh (this is the "cook" step).
	points := make([]b3.Vec3, len(mesh.vertices))
	defer delete(points)
	for vertex, i in mesh.vertices {
		points[i] = transmute(b3.Vec3)vertex.position
	}

	indices := make([]i32, len(mesh.indices))
	defer delete(indices)
	for index, i in mesh.indices {
		indices[i] = i32(index)
	}

	mesh_def := b3.MeshDef {
		vertices      = raw_data(points),
		vertexCount   = i32(len(points)),
		indices       = raw_data(indices),
		triangleCount = i32(len(indices) / 3),
		identifyEdges = true, // smoother character collision across mesh edges
	}

	static_mesh.mesh_data = b3.CreateMesh(mesh_def, nil, 0)
	assert(static_mesh.mesh_data != nil)

	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = translation
	body_def.rotation = rotation
	body_def.userData = entity_id_to_rawptr(static_mesh.id)
	static_mesh.body = b3.CreateBody(game.phys.world, body_def)

	shape_def := b3.DefaultShapeDef()
	shape_def.baseMaterial = phys_default_material()
	_ = b3.CreateMeshShape(static_mesh.body, shape_def, static_mesh.mesh_data, {1, 1, 1})

	static_mesh.translation = translation
	static_mesh.rotation = rotation
	static_mesh.mesh = gpu_mesh
	static_mesh.material = material
}

// Destroying the body also destroys its shapes and removes it from the world, so scene reload
// doesn't accumulate invisible colliders. The baked mesh is freed after the body that referenced
// it. NOTE: the GPU mesh is still deferred to gfx global_arena in init, so it survives reload
// (memory grows on repeated reloads) — route it through the scene arena when the asset_name
// refactor lands.
static_mesh_destroy :: proc(static_mesh: ^StaticMesh) {
	if b3.IS_NON_NULL(static_mesh.body) {
		b3.DestroyBody(static_mesh.body)
		static_mesh.body = b3.nullBodyId
	}
	if static_mesh.mesh_data != nil {
		b3.DestroyMesh(static_mesh.mesh_data)
		static_mesh.mesh_data = nil
	}
}
