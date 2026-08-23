package game

import "core:c"
import "core:encoding/endian"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"

import b3 "vendor:box3d"

import "gfx"

HEIGHTFIELD_FILE_VERSION :: 1
HEIGHTFIELD_HEADER_SIZE :: 40
HEIGHTFIELD_MAX_AXIS :: 8193

HeightfieldSource :: struct {
	count_x:    int,
	count_z:    int,
	spacing_x:  f32,
	spacing_z:  f32,
	origin_x:   f32,
	origin_z:   f32,
	min_height: f32,
	max_height: f32,
	heights:    []f32,
}

@(entity)
Terrain :: struct {
	using entity: ^Entity,
	mesh:         GPUMeshBuffers,
	material:     MaterialId,
	body:         b3.BodyId,
	heightfield:  ^b3.HeightFieldData,
}

heightfield_finite :: proc "contextless" (value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

load_heightfield_source :: proc(path: string, allocator := context.allocator) -> (source: HeightfieldSource, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.error("Could not read heightfield:", path)
		return
	}
	defer delete(data, context.temp_allocator)

	if len(data) < HEIGHTFIELD_HEADER_SIZE || data[0] != 'H' || data[1] != 'F' || data[2] != 'L' || data[3] != 'D' {
		log.error("Invalid heightfield header:", path)
		return
	}

	version, version_ok := endian.get_u32(data[4:], .Little)
	count_x_u32, count_x_ok := endian.get_u32(data[8:], .Little)
	count_z_u32, count_z_ok := endian.get_u32(data[12:], .Little)
	spacing_x, spacing_x_ok := endian.get_f32(data[16:], .Little)
	spacing_z, spacing_z_ok := endian.get_f32(data[20:], .Little)
	origin_x, origin_x_ok := endian.get_f32(data[24:], .Little)
	origin_z, origin_z_ok := endian.get_f32(data[28:], .Little)
	min_height, min_ok := endian.get_f32(data[32:], .Little)
	max_height, max_ok := endian.get_f32(data[36:], .Little)
	if !version_ok || !count_x_ok || !count_z_ok || !spacing_x_ok || !spacing_z_ok || !origin_x_ok || !origin_z_ok || !min_ok || !max_ok {
		log.error("Truncated heightfield header:", path)
		return
	}
	if version != HEIGHTFIELD_FILE_VERSION {
		log.error("Unsupported heightfield version:", version, "in", path)
		return
	}
	if count_x_u32 < 2 || count_z_u32 < 2 || count_x_u32 > HEIGHTFIELD_MAX_AXIS || count_z_u32 > HEIGHTFIELD_MAX_AXIS {
		log.error("Invalid heightfield dimensions:", count_x_u32, count_z_u32, "in", path)
		return
	}
	if spacing_x <= 0 ||
	   spacing_z <= 0 ||
	   !heightfield_finite(spacing_x) ||
	   !heightfield_finite(spacing_z) ||
	   !heightfield_finite(origin_x) ||
	   !heightfield_finite(origin_z) ||
	   !heightfield_finite(min_height) ||
	   !heightfield_finite(max_height) ||
	   min_height > max_height {
		log.error("Invalid heightfield bounds or spacing:", path)
		return
	}

	height_count_u64 := u64(count_x_u32) * u64(count_z_u32)
	expected_size := u64(HEIGHTFIELD_HEADER_SIZE) + height_count_u64 * size_of(f32)
	if u64(len(data)) != expected_size {
		log.error("Heightfield payload size mismatch:", path)
		return
	}

	source = {
		count_x    = int(count_x_u32),
		count_z    = int(count_z_u32),
		spacing_x  = spacing_x,
		spacing_z  = spacing_z,
		origin_x   = origin_x,
		origin_z   = origin_z,
		min_height = min_height,
		max_height = max_height,
		heights    = make([]f32, int(height_count_u64), allocator),
	}
	for &height, index in source.heights {
		value, value_ok := endian.get_f32(data[HEIGHTFIELD_HEADER_SIZE + index * size_of(f32):], .Little)
		if !value_ok || !heightfield_finite(value) {
			log.error("Invalid height sample in:", path)
			delete(source.heights, allocator)
			source = {}
			return
		}
		height = value
	}

	ok = true
	return
}

heightfield_mesh :: proc(source: ^HeightfieldSource, uv_scale: f32, allocator := context.allocator) -> Mesh {
	mesh: Mesh
	mesh.vertices = make([]Vertex, source.count_x * source.count_z, allocator)
	mesh.indices = make([]u32, (source.count_x - 1) * (source.count_z - 1) * 6, allocator)

	for z in 0 ..< source.count_z {
		for x in 0 ..< source.count_x {
			index := z * source.count_x + x
			left := max(x - 1, 0)
			right := min(x + 1, source.count_x - 1)
			back := max(z - 1, 0)
			front := min(z + 1, source.count_z - 1)

			tangent_x := Vec3 {
				f32(right - left) * source.spacing_x,
				source.heights[z * source.count_x + right] - source.heights[z * source.count_x + left],
				0,
			}
			tangent_z := Vec3 {
				0,
				source.heights[front * source.count_x + x] - source.heights[back * source.count_x + x],
				f32(front - back) * source.spacing_z,
			}
			tangent_x = linalg.normalize0(tangent_x)
			normal := linalg.normalize0(linalg.cross(tangent_z, tangent_x))

			mesh.vertices[index] = {
				position = {f32(x) * source.spacing_x, source.heights[index], f32(z) * source.spacing_z},
				uv_x     = f32(x) / f32(source.count_x - 1) * uv_scale,
				normal   = normal,
				uv_y     = f32(z) / f32(source.count_z - 1) * uv_scale,
				color    = 1,
				tangent  = {tangent_x.x, tangent_x.y, tangent_x.z, 1},
			}
		}
	}

	write_index := 0
	for z in 0 ..< source.count_z - 1 {
		for x in 0 ..< source.count_x - 1 {
			i00 := u32(z * source.count_x + x)
			i01 := i00 + 1
			i10 := i00 + u32(source.count_x)
			i11 := i10 + 1
			// Match Box3D's fixed heightfield diagonal and counter-clockwise top winding.
			mesh.indices[write_index + 0] = i00
			mesh.indices[write_index + 1] = i10
			mesh.indices[write_index + 2] = i01
			mesh.indices[write_index + 3] = i11
			mesh.indices[write_index + 4] = i01
			mesh.indices[write_index + 5] = i10
			write_index += 6
		}
	}
	return mesh
}

init_terrain :: proc(
	terrain: ^Terrain,
	path: string,
	material: MaterialId,
	uv_scale: f32,
	gpu_arena: ^gfx.ResourceArena,
	translation: Vec3 = {0, 0, 0},
	rotation: Quat = Quat(1),
) -> bool {
	source := load_heightfield_source(path, context.temp_allocator) or_return
	defer delete(source.heights, context.temp_allocator)

	mesh := heightfield_mesh(&source, uv_scale, context.temp_allocator)
	defer delete(mesh.vertices, context.temp_allocator)
	defer delete(mesh.indices, context.temp_allocator)
	terrain.mesh = upload_mesh_to_gpu(mesh)
	defer_destroy_gpu_mesh(gpu_arena, terrain.mesh)

	heightfield_def := b3.HeightFieldDef {
		heights             = raw_data(source.heights),
		scale               = {source.spacing_x, 1, source.spacing_z},
		countX              = c.int(source.count_x),
		countZ              = c.int(source.count_z),
		globalMinimumHeight = source.min_height,
		globalMaximumHeight = source.max_height,
		clockwiseWinding    = false,
	}
	terrain.heightfield = b3.CreateHeightField(heightfield_def)
	if terrain.heightfield == nil {
		log.error("Box3D failed to create heightfield:", path)
		return false
	}

	// Box3D heightfields begin at local X/Z zero. The sidecar retains the centered Blender grid's
	// local corner, so shift the entity/body while leaving the height samples densely packed.
	terrain.translation = translation + Vec3{source.origin_x, 0, source.origin_z}
	terrain.rotation = rotation
	terrain.material = material

	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = terrain.translation
	body_def.rotation = rotation
	body_def.userData = entity_id_to_rawptr(terrain.id)
	terrain.body = b3.CreateBody(game.phys.world, body_def)

	shape_def := b3.DefaultShapeDef()
	shape_def.baseMaterial = phys_default_material()
	_ = b3.CreateHeightFieldShape(terrain.body, shape_def, terrain.heightfield)
	return true
}

terrain_destroy :: proc(terrain: ^Terrain) {
	if b3.IS_NON_NULL(terrain.body) {
		b3.DestroyBody(terrain.body)
		terrain.body = b3.nullBodyId
	}
	if terrain.heightfield != nil {
		b3.DestroyHeightField(terrain.heightfield)
		terrain.heightfield = nil
	}
}
