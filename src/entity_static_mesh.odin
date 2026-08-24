package game

import b3 "vendor:box3d"

import "gfx"

@(entity)
StaticMesh :: struct {
	using entity: ^Entity,
	mesh:         GPUMeshBuffers,
	material:     MaterialId,
	scale:        Vec3,
	body:         b3.BodyId,
	mesh_data:    ^b3.MeshData,
}

init_static_mesh :: proc(
	static_mesh: ^StaticMesh,
	path: string,
	material: MaterialId,
	gpu_arena: ^gfx.ResourceArena,
	translation: Vec3 = {0, 0, 0},
	rotation: Quat = Quat(1),
	scale: Vec3 = {1, 1, 1},
) {
	mesh, ok := load_mesh_from_file(path, context.temp_allocator)
	assert(ok)

	gpu_mesh := upload_mesh_to_gpu(mesh)
	defer_destroy_gpu_mesh(gpu_arena, gpu_mesh)

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
	_ = b3.CreateMeshShape(static_mesh.body, shape_def, static_mesh.mesh_data, transmute(b3.Vec3)scale)

	static_mesh.translation = translation
	static_mesh.rotation = rotation
	static_mesh.scale = scale
	static_mesh.mesh = gpu_mesh
	static_mesh.material = material
}

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
