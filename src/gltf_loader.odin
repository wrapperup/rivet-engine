package game

import "core:fmt"
import "base:intrinsics"

import "deps:gltf2"
import vk "vendor:vulkan"

import mikk "deps:odin-mikktspace"

import "gfx"

create_mesh_buffers :: proc(mesh: Mesh, loc := #caller_location) -> GPUMeshBuffers {
	index_count := u32(len(mesh.indices))
	vertex_count := u32(len(mesh.vertices))

	assert(index_count > 0)
	assert(vertex_count > 0)

	new_surface: GPUMeshBuffers
	new_surface.index_count = index_count
	new_surface.vertex_count = vertex_count

	new_surface.vertex_buffer = gfx.create_buffer(
        Vertex,
		vertex_count,
		loc = loc,
	)
	new_surface.index_buffer = gfx.create_buffer(u32, index_count, .Index, loc = loc)

	return new_surface
}

staging_write_mesh_buffers :: proc(buffers: ^GPUMeshBuffers, mesh: Mesh, loc := #caller_location) {
	vertex_buffer_size := vk.DeviceSize(size_of(Vertex) * len(mesh.vertices))
	index_buffer_size := vk.DeviceSize(size_of(u32) * len(mesh.indices))

	assert(buffers.index_count == u32(len(mesh.indices)))
	assert(buffers.vertex_count == u32(len(mesh.vertices)))

	staging := gfx.create_buffer(u8, vertex_buffer_size + index_buffer_size, .Staging, loc = loc)

	gfx.write_buffer_slice(&staging, mesh.vertices)
	gfx.write_buffer_slice(&staging, mesh.indices, vertex_buffer_size)

	if cmd, ok := gfx.immediate_submit(); ok {
		vertex_copy := vk.BufferCopy {
			dstOffset = 0,
			srcOffset = 0,
			size      = vertex_buffer_size,
		}

		index_copy := vk.BufferCopy {
			dstOffset = 0,
			srcOffset = vertex_buffer_size,
			size      = index_buffer_size,
		}

		vk.CmdCopyBuffer(cmd, staging.buffer, buffers.vertex_buffer.buffer, 1, &vertex_copy)
		vk.CmdCopyBuffer(cmd, staging.buffer, buffers.index_buffer.buffer, 1, &index_copy)
	}

	gfx.destroy_buffer(&staging)
}

// Allocates two slices if successful. Make sure to free them when you're done.
parse_gltf_mesh_into_mesh :: proc(data: ^gltf2.Data, mesh_idx: int) -> (mesh: Mesh, ok: bool) {
	gltf_mesh := &data.meshes[mesh_idx]
	primitive := &gltf_mesh.primitives[0]

	if (mesh_idx < len(data.skins)) {
		skin := &data.skins[mesh_idx]
		assert(skin != nil)
	}

    indices_idx := primitive.indices.?
	pos_idx, pos_ok := primitive.attributes["POSITION"]
    assert(pos_ok)
	norm_idx, norm_ok := primitive.attributes["NORMAL"]
	color_idx, color_ok := primitive.attributes["COLOR_0"]
	uv_idx, uv_ok := primitive.attributes["TEXCOORD_0"]
	//lightmap_uv_idx, lightmap_uv_ok := primitive.attributes["texcoord"]
	tangent_idx, tangent_ok := primitive.attributes["TANGENT"]

	{
        indices_buf := gltf2.buffer_slice(data, indices_idx).([]u16)
		mesh.indices = make([]u32, len(indices_buf))

        for index, i in indices_buf {
            mesh.indices[i] = cast(u32)index
        }
	}

	{
        positions := read_accessor(data, pos_idx, [3]f32) or_return
        defer delete(positions)

		mesh.vertices = make([]Vertex, len(positions))

		for val, i in positions {
			mesh.vertices[i].position = val
		}
	}

	if norm_ok {
        normals := read_accessor(data, norm_idx, [3]f32) or_return
        defer delete(normals)

		for val, i in normals {
			mesh.vertices[i].normal = val
		}
	}

	if color_ok {
        colors := read_accessor(data, color_idx, [3]f32) or_return
        defer delete(colors)

		for val, i in colors {
			mesh.vertices[i].color.xyz = val
            mesh.vertices[i].color.a = 1
		}
	} else {
		// Default the color to 1
		for &vertex in mesh.vertices {
			vertex.color = 1
		}
	}

	if uv_ok {
        uvs := read_accessor(data, uv_idx, [2]f32) or_return
        defer delete(uvs)

		for val, i in uvs {
			mesh.vertices[i].uv_x  = val.x
            mesh.vertices[i].uv_y = val.y
		}
	}

    // assert(tangent_ok)

	if false {
        tangents := read_accessor(data, tangent_idx, [4]f32) or_return
        defer delete(tangents)

		for val, i in tangents {
            mesh.vertices[i].tangent = val
		}
	} else if uv_ok && norm_ok {
		// Generate tangents if we have normals + uv and no tangents are included.
		get_vertex_index :: proc(pContext: ^mikk.Context, iFace: int, iVert: int) -> int {
			gltf_mesh := cast(^Mesh)pContext.user_data

			indices_index := iVert + (iFace * get_num_vertices_of_face(pContext, iFace))
			index := gltf_mesh.indices[indices_index]

			return int(index)
		}

		get_num_faces :: proc(pContext: ^mikk.Context) -> int {
			gltf_mesh := cast(^Mesh)pContext.user_data
			return len(gltf_mesh.indices) / 3
		}

		get_num_vertices_of_face :: proc(pContext: ^mikk.Context, iFace: int) -> int {
			return 3
		}

		get_position :: proc(pContext: ^mikk.Context, iFace: int, iVert: int) -> Vec3 {
			gltf_mesh := cast(^Mesh)pContext.user_data
			return gltf_mesh.vertices[get_vertex_index(pContext, iFace, iVert)].position
		}

		get_normal :: proc(pContext: ^mikk.Context, iFace: int, iVert: int) -> Vec3 {
			gltf_mesh := cast(^Mesh)pContext.user_data
			return gltf_mesh.vertices[get_vertex_index(pContext, iFace, iVert)].normal
		}

		get_tex_coord :: proc(pContext: ^mikk.Context, iFace: int, iVert: int) -> [2]f32 {
			gltf_mesh := cast(^Mesh)pContext.user_data
			vertex := &gltf_mesh.vertices[get_vertex_index(pContext, iFace, iVert)]
			return {vertex.uv_x, vertex.uv_y}
		}

		set_t_space_basic :: proc(pContext: ^mikk.Context, fvTangent: Vec3, fSign: f32, iFace: int, iVert: int) {
			gltf_mesh := cast(^Mesh)pContext.user_data
			tangent := &gltf_mesh.vertices[get_vertex_index(pContext, iFace, iVert)].tangent

			// Not sure why I need to flip these? Seems to be fine though.
			tangent.xyz = fvTangent
			tangent.w = fSign
		}

		interface := mikk.Interface {
			get_num_faces            = get_num_faces,
			get_num_vertices_of_face = get_num_vertices_of_face,
			get_position             = get_position,
			get_normal               = get_normal,
			get_tex_coord            = get_tex_coord,
			set_t_space_basic        = set_t_space_basic,
		}

		ctx := mikk.Context {
			interface = &interface,
			user_data = &mesh,
		}

		tangent_ok = mikk.generate_tangents(&ctx)
	}

	assert(tangent_ok)

	ok = true

	return mesh, ok
}

// Reads a whole accessor into a freshly-allocated []T, casting each element from whatever
// the glTF stored (any component type / component count) into T via try_cast_accessor_type.
// Normalized integer accessors are decoded to floats. Mirrors buffer_slice's pointer math
// but doesn't care that Blender emits VEC4 u16 for one mesh and VEC3 f32 for another.
read_accessor :: proc(data: ^gltf2.Data, accessor_index: gltf2.Integer, $T: typeid, allocator := context.allocator) -> ([]T, bool) {
	accessor    := data.accessors[accessor_index]
	buffer_view := data.buffer_views[accessor.buffer_view.?]
	bytes       := data.buffers[buffer_view.buffer].uri.([]byte)

	start  := int(accessor.byte_offset + buffer_view.byte_offset)
	stride := component_size(accessor.component_type) * accessor_component_count(accessor.type)

	out := make([]T, accessor.count, allocator)
	for i in 0 ..< int(accessor.count) {
		value_ptr := rawptr(uintptr(rawptr(&bytes[start])) + uintptr(i * stride))
		value, ok := try_cast_accessor_type(T, value_ptr, accessor.component_type, accessor.type, accessor.normalized)
		if !ok {
			delete(out, allocator)
			return nil, false
		}
		out[i] = value
	}

	return out, true
}

component_size :: proc(ct: gltf2.Component_Type) -> int {
	switch ct {
	case .Byte, .Unsigned_Byte:   return 1
	case .Short, .Unsigned_Short: return 2
	case .Unsigned_Int, .Float:   return 4
	}
	return 0
}

accessor_component_count :: proc(t: gltf2.Accessor_Type) -> int {
	switch t {
	case .Scalar:  return 1
	case .Vector2: return 2
	case .Vector3: return 3
	case .Vector4: return 4
	case .Matrix2: return 4
	case .Matrix3: return 9
	case .Matrix4: return 16
	}
	return 0
}

try_cast_accessor_type :: proc($T: typeid, value_ptr: rawptr, component_type: gltf2.Component_Type, type: gltf2.Accessor_Type, normalized := false) -> (T, bool) {
	when intrinsics.type_is_array(T) {
		value, ok := try_cast_vec_type(T, value_ptr, component_type, type, normalized)
		return value, ok
	} else when intrinsics.type_is_integer(T) {
		value, ok := try_cast_numeric_type(T, value_ptr, component_type, normalized)
		return value, ok
	} else when intrinsics.type_is_float(T) {
		value, ok := try_cast_numeric_type(T, value_ptr, component_type, normalized)
		return value, ok
	} else {
		// Unreachable.
		v: T = ---
		return v, false
	}
}

try_cast_numeric_type :: proc($T: typeid, value_ptr: rawptr, component_type: gltf2.Component_Type, normalized := false) -> (T, bool)
	where intrinsics.type_is_float(T) || intrinsics.type_is_integer(T) {

	when intrinsics.type_is_integer(T) {
		when intrinsics.type_is_unsigned(T) {
			value, ok := try_cast_uint_type(T, value_ptr, component_type)
			return value, ok
		} else {
			value, ok := try_cast_int_type(T, value_ptr, component_type)
			return value, ok
		}
	} else when intrinsics.type_is_float(T) {
		value, ok := try_cast_float_type(T, value_ptr, component_type, normalized)
		return value, ok
	}
}

try_cast_int_type :: proc($T: typeid, value_ptr: rawptr, component_type: gltf2.Component_Type) -> (T, bool)
	where intrinsics.type_is_integer(T) && !intrinsics.type_is_unsigned(T) {

	value: T = ---

	#partial switch component_type {
	case .Byte:  value = T((cast(^i8)  value_ptr)^)
	case .Short: value = T((cast(^i16) value_ptr)^)

	case: return 0, false
	}

	return value, true
}

try_cast_uint_type :: proc($T: typeid, value_ptr: rawptr, component_type: gltf2.Component_Type) -> (T, bool)
	where intrinsics.type_is_integer(T) && intrinsics.type_is_unsigned(T) {

	value: T = ---

	#partial switch component_type {
	case .Unsigned_Byte:  value = T((cast(^u8)  value_ptr)^)
	case .Unsigned_Short: value = T((cast(^u16) value_ptr)^)
	case .Unsigned_Int:   value = T((cast(^u32) value_ptr)^)

	case: return 0, false
	}

	return value, true
}

// Diverges from the equivalent Jai proc, which only accepted .FLOAT: glTF stores normalized
// integer colors, so we also decode integer components (scaled to [0,1]/[-1,1] when
// `normalized`). Without this, demo_ball's u16 colors come out as 61537.0 instead of 0.94.
try_cast_float_type :: proc($T: typeid, value_ptr: rawptr, component_type: gltf2.Component_Type, normalized := false) -> (T, bool)
	where intrinsics.type_is_float(T) {

	value: T = ---

	#partial switch component_type {
	case .Float:          value = T((cast(^f32) value_ptr)^)
	case .Unsigned_Byte:  value = normalized ? T(f32((cast(^u8)  value_ptr)^) / 255.0)           : T((cast(^u8)  value_ptr)^)
	case .Byte:           value = normalized ? T(max(f32((cast(^i8)  value_ptr)^) / 127.0,   -1)) : T((cast(^i8)  value_ptr)^)
	case .Unsigned_Short: value = normalized ? T(f32((cast(^u16) value_ptr)^) / 65535.0)         : T((cast(^u16) value_ptr)^)
	case .Short:          value = normalized ? T(max(f32((cast(^i16) value_ptr)^) / 32767.0, -1)) : T((cast(^i16) value_ptr)^)
	case .Unsigned_Int:   value = T((cast(^u32) value_ptr)^)

	case: return 0, false
	}

	return value, true
}

try_cast_vec_type :: proc($T: typeid/[$N]$E, value_ptr: rawptr, component_type: gltf2.Component_Type, type: gltf2.Accessor_Type, normalized := false) -> (T, bool) {
	value: T = ---

	// We narrow but never widen: a target with fewer components than the source drops the
	// extras (glTF VEC4 color -> [3]f32). Reading past what the buffer holds is the one case
	// we refuse. Composes the scalar casters per component instead of a bulk array_cast so
	// normalization threads through the same path.
	if accessor_component_count(type) < N {
		return value, false
	}

	comp_size := component_size(component_type)

	for i in 0 ..< N {
		comp_ptr := rawptr(uintptr(value_ptr) + uintptr(i * comp_size))
		v, ok := try_cast_numeric_type(E, comp_ptr, component_type, normalized)
		if !ok {
			return value, false
		}
		value[i] = v
	}

	return value, true
}

Mesh :: struct {
	indices:  []u32,
	// TODO: Maybe store this as AOS instead
	vertices: []Vertex,
}

SkeletalMesh :: struct {
	using mesh: Mesh,
	attrs:      []SkeletonVertexAttribute,
}


load_mesh_from_file :: proc(path: string, loc := #caller_location) -> (Mesh, bool) {
    data, error := gltf2.load_from_file(path)
    assert(error == nil, "Couldn't load mesh.", loc = loc)

    // if there are no errors we want to free memory when we are done with processing gltf/glb file.
    defer gltf2.unload(data)

    mesh, ok := parse_gltf_mesh_into_mesh(data, 0)

    return mesh, ok
}

load_gpu_mesh_from_file :: proc(path: string, loc := #caller_location) -> (gpu_mesh: GPUMeshBuffers, ok: bool) {
    mesh := load_mesh_from_file(path, loc = loc) or_return
	return upload_mesh_to_gpu(mesh, loc = loc), true
}

defer_destroy_gpu_mesh :: proc(arena: ^gfx.ResourceArena, gpu_mesh: GPUMeshBuffers) {
	gfx.defer_destroy_buffer(arena, gpu_mesh.vertex_buffer)
	gfx.defer_destroy_buffer(arena, gpu_mesh.index_buffer)
	gfx.defer_destroy_accel(arena, gpu_mesh.blas)
}

upload_mesh_to_gpu :: proc(mesh: Mesh, loc := #caller_location) -> GPUMeshBuffers {
    assert(len(mesh.indices) > 0, "Mesh has no indices!")
    assert(len(mesh.vertices) > 0, "Mesh has no vertices!")

	buffers := create_mesh_buffers(mesh, loc = loc)
	staging_write_mesh_buffers(&buffers, mesh)
	buffers.index_count = u32(len(mesh.indices))

	// Build the mesh's BLAS once, now that vertices/indices are on the GPU.
	buffers.blas = gfx.build_blas(
		buffers.vertex_buffer.ptr.address,
		buffers.vertex_count,
		size_of(Vertex),
		buffers.index_buffer.ptr.address,
		buffers.index_count,
	)

	return buffers
}

// Allocates two slices if successful. Make sure to free them when you're done.
parse_gltf_mesh_into_skel_mesh :: proc(
	data: ^gltf2.Data,
	mesh_idx: int,
) -> (
	skel_mesh: SkeletalMesh,
	skeleton: Skeleton,
	skel_anim: SkeletalAnimation,
	ok: bool,
) {
	skel_mesh.mesh = parse_gltf_mesh_into_mesh(data, mesh_idx) or_return

	gltf_mesh := &data.meshes[mesh_idx]
	primitive := &gltf_mesh.primitives[0]

	assert(mesh_idx < len(data.skins))

	skin := &data.skins[mesh_idx]
	assert(skin != nil)

	// Required for skeletal mesh.
	joints_idx := primitive.attributes["JOINTS_0"] or_return
	weights_idx := primitive.attributes["WEIGHTS_0"] or_return

    joints_buf := gltf2.buffer_slice(data, joints_idx).([][4]u8)
    weights_buf := gltf2.buffer_slice(data, weights_idx).([][4]f32)

	skel_mesh.attrs = make([]SkeletonVertexAttribute, len(joints_buf))

	{
		for &attr, i in skel_mesh.attrs {
			attr.joints = joints_buf[i]
			attr.weights = weights_buf[i]
		}
	}

	{
		reserve(&skeleton.inverse_bind_matrices, len(skin.joints))
		reserve(&skeleton.bind_matrices_ls, len(skin.joints))
		reserve(&skeleton.joint_tree, len(skin.joints))

		skeleton.joint_count = len(skin.joints)

		inverse_bind_matrices_buf := gltf2.buffer_slice(data, skin.inverse_bind_matrices.?).([]JointMatrix)

		for val in inverse_bind_matrices_buf {
			append(&skeleton.inverse_bind_matrices, val)
		}

        joint_remap: map[u32]u32

		for joint_i, i in skin.joints {
            joint_remap[joint_i] = u32(i)
        }

		for &joint_i in skin.joints {
			node := data.nodes[joint_i]

			// Calc the local-space transform of the joint.
			// TODO: We're just gonna assume that the skeleton is at the origin, so the world-space transform IS the local-space transform.
			local_matrix := node.mat
			append(&skeleton.bind_matrices_ls, local_matrix)

            children: [dynamic]JointId

            for child_idx in node.children {
                append(&children, joint_remap[child_idx])
            }

			append(&skeleton.joint_tree, children)
		}

		// TODO: TESTING: Grab first animation TESTING
		animation := data.animations[0]

		joint_anims: map[u32]JointTrack

		for &channel in animation.channels {
			joint_index := channel.target.node.?

            joint_anim, ok_j := &joint_anims[joint_index]
            if !ok_j {
                // TODO: this is kinda ass ngl
                joint_anims[joint_index] = JointTrack{}
                joint_anim = &joint_anims[joint_index]
            }

            sampler := animation.samplers[channel.sampler]

            #partial switch channel.target.path {
            case .Translation:
                translation_buf := gltf2.buffer_slice(data, sampler.output).([]Vec3)
                for val in translation_buf {
                    append(&joint_anim.keyframes_translation, val)
                }
            case .Rotation:
                rotation_buf := gltf2.buffer_slice(data, sampler.output).([]Vec4)
                for val in rotation_buf {
                    q := quaternion(w = val.w, x = val.x, y = val.y, z = val.z)
                    append(&joint_anim.keyframes_rotation, q)
                }
            case .Scale:
                scale_buf := gltf2.buffer_slice(data, sampler.output).([]Vec3)
                for val in scale_buf {
                    append(&joint_anim.keyframes_scale, val)
                }
            case:
                panic("Unsupported animation channel type.")
            }
		}

		resize(&skel_anim.joint_animations, len(joint_anims))
		for k, v in joint_anims {
			skel_anim.joint_animations[k] = v
		}

		skel_anim.keyframe_count = u32(len(skel_anim.joint_animations[0].keyframes_translation))
		skel_anim.fps = 30.0
	}

	ok = true

	return
}

load_skel_mesh_from_file :: proc(path: string, loc := #caller_location) -> (skeleton: Skeleton, anim: SkeletalAnimation, ok: bool) {
    data, error := gltf2.load_from_file(path)
    assert(error == nil, "Couldn't load skeletal mesh.", loc = loc)

    // if there are no errors we want to free memory when we are done with processing gltf/glb file.
    defer gltf2.unload(data)

	skel_mesh, skel, an := parse_gltf_mesh_into_skel_mesh(data, 0) or_return
	skeleton = skel
	anim = an

	skeleton.buffers = create_skel_mesh_buffers(skel_mesh, loc = loc)
	staging_write_skel_mesh_buffers(&skeleton.buffers, skel_mesh, loc = loc)

	ok = true

	return
}

defer_destroy_gpu_skel_mesh :: proc(arena: ^gfx.ResourceArena, gpu_mesh: GPUSkelMeshBuffers) {
	defer_destroy_gpu_mesh(arena, gpu_mesh)
	gfx.defer_destroy_buffer(arena, gpu_mesh.skel_vert_attrs_buffer)
}

// Creates the buffers, but doesn't fill them.
create_skel_mesh_buffers :: proc(skel_mesh: SkeletalMesh, loc := #caller_location) -> GPUSkelMeshBuffers {
	assert(len(skel_mesh.attrs) > 0)
	assert(len(skel_mesh.vertices) == len(skel_mesh.attrs))

	new_surface: GPUSkelMeshBuffers
	new_surface.mesh_buffers = create_mesh_buffers(skel_mesh, loc = loc)
	new_surface.attrs_count = u32(len(skel_mesh.attrs))

	new_surface.skel_vert_attrs_buffer = gfx.create_buffer(
		SkeletonVertexAttribute,
        len(skel_mesh.attrs),
		loc = loc,
	)

	return new_surface
}

staging_write_skel_mesh_buffers :: proc(buffers: ^GPUSkelMeshBuffers, skel_mesh: SkeletalMesh, loc := #caller_location) {
	assert(len(skel_mesh.attrs) > 0)
	assert(len(skel_mesh.vertices) == len(skel_mesh.attrs))

	staging_write_mesh_buffers(buffers, skel_mesh)
	gfx.staging_write_buffer_slice(&buffers.skel_vert_attrs_buffer, skel_mesh.attrs)
}
