package game

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import ktx "deps:odin-libktx"
import b3 "vendor:box3d"
import vk "vendor:vulkan"

import slang "deps:odin-slang/slang"

import "gfx"

REQUIRE_COOKED_ASSETS :: #config(REQUIRE_COOKED_ASSETS, false)
COOKED_ASSET_DIR :: "build/cooked"
BASE_ASSET_DIR :: "assets"

AssetSystem :: struct {
	allocator:   mem.Allocator,
	initialized: bool,
	stores:      map[typeid]Asset_Store_Raw,
}

Asset_Load_Kind :: enum {
	Block,
	// Async,
}

Handle :: struct($T: typeid) {
	path: string,
}

Asset :: struct {
	source_path: string,
	status:      Asset_Load_Result,
	ref_count:   int,
}

Asset_Processor_Proc :: #type proc(path: string, allocator: mem.Allocator) -> (out_bytes: []u8, ok: bool)

Asset_Loaders :: struct {
	load:       #type proc(bytes: []u8, out: rawptr, allocator: mem.Allocator) -> bool,
	destroy:    #type proc(asset: rawptr, allocator: mem.Allocator),
	processors: map[string]Asset_Processor_Proc,
}

Asset_Store_Raw :: struct {
	assets:  runtime.Raw_Map,
	loaders: Asset_Loaders,
	destroy: proc(store: ^Asset_Store_Raw, allocator: mem.Allocator),
}

Asset_Store :: struct($T: typeid) where intrinsics.type_is_subtype_of(T, Asset) {
	assets:  map[string]T,
	loaders: Asset_Loaders,
}

Asset_Debug_Entry :: struct {
	path:       string,
	asset_type: typeid,
	status:     Asset_Load_Result,
	ref_count:  int,
}

Asset_Load_Result :: enum {
	NotAvailable,
	Ready,
	// Async,
}

register_asset_type :: proc($T: typeid, loaders: Asset_Loaders) {
	assert(T not_in game.asset_system.stores, "Registered asset type more than once.")

	store := Asset_Store_Raw {
		loaders = loaders,
		destroy = proc(self: ^Asset_Store_Raw, allocator: mem.Allocator) {
			store := cast(^Asset_Store(T))self

			for path, &asset in store.assets {
				store.loaders.destroy(&asset, allocator)
			}
		},
	}

	game.asset_system.stores[T] = store
}

register_asset_processor :: proc($T: typeid, filetype: string, processor: Asset_Processor_Proc) -> bool {
	store := get_asset_store(T)
	if filetype in store.loaders.processors {
		return false
	}

	store.loaders.processors[filetype] = processor
	return true
}

get_asset_store :: proc($T: typeid) -> ^Asset_Store(T) {
	fmt.assertf(T in game.asset_system.stores, "Asset store not registered for this type: %s", typeid_of(T))

	return cast(^Asset_Store(T))&game.asset_system.stores[T]
}

load_asset_path :: proc(
	$T: typeid,
	path: string,
	method := Asset_Load_Kind.Block,
) -> (
	asset: ^T,
) where intrinsics.type_is_subtype_of(T, Asset) {
	return load_asset_handle(Handle(T){path})
}

load_asset_handle :: proc(
	handle: Handle($T),
	method := Asset_Load_Kind.Block,
) -> (
	asset: ^T,
) where intrinsics.type_is_subtype_of(T, Asset) {
	if found_asset := get_asset(handle); found_asset != nil {
		found_asset.ref_count += 1
		return found_asset
	}

	asset_sys := &game.asset_system
	allocator := asset_sys.allocator

	store := get_asset_store(T)
	if store == nil {
		log.warn("Failed to load asset:", handle)
		return
	}

	if method == .Block {
		asset_path := resolve_asset_path(handle, context.temp_allocator)
		asset_ext := filepath.ext(handle.path)

		bytes: []u8
		when REQUIRE_COOKED_ASSETS {
			cooked_asset_path := resolve_cooked_asset_path(handle, context.temp_allocator)

			err: os.Error
			bytes, err = os.read_entire_file(cooked_asset_path, allocator)
			if err != nil {
				log.warn("Failed to read asset:", handle)
				return
			}
		} else {
			cooked_asset_path := resolve_cooked_asset_path(handle, context.temp_allocator)

			if os.exists(cooked_asset_path) {
                err: os.Error
                bytes, err = os.read_entire_file(cooked_asset_path, allocator)
                if err != nil {
                    log.warn("Failed to read asset:", handle)
                    return
                }
			} else {
				if processor, found := store.loaders.processors[asset_ext]; found {
					ok: bool
					if bytes, ok = processor(asset_path, allocator); !ok {
						log.warn("Failed to read and process asset:", handle, "with file ext:", asset_ext)
						return
					}
				} else {
					err: os.Error
					bytes, err = os.read_entire_file(asset_path, allocator)
					if err != nil {
						log.warn("Failed to read asset:", handle)
						return
					}
				}

				cooked_asset_dir := filepath.dir(cooked_asset_path)
				if err := os.make_directory_all(cooked_asset_dir); err != nil {
					log.warn("Failed to create cooked asset directory:", COOKED_ASSET_DIR)
				}

				write_err := os.write_entire_file(cooked_asset_path, bytes)
				if write_err != nil {
					log.warn("Failed to write to cooked asset directory:", cooked_asset_path)
				}
			}
		}

		new_asset: T
		if !store.loaders.load(bytes, &new_asset, allocator) {
			log.warn("Failed to load asset:", handle)
			return
		}

		log.debug("Loaded asset:", handle)

		store.assets[handle.path] = new_asset
		asset = &store.assets[handle.path]
	}

	// should never happen
	assert(asset != nil)

	asset.status = .Ready
	asset.ref_count = 1

	return
}

load_asset :: proc {
	load_asset_path,
	load_asset_handle,
}

release_asset :: proc(handle: Handle($T)) -> (destroyed: bool) {
	asset := get_asset(handle)
	if asset == nil {
		return false
	}

	if asset.ref_count > 0 {
		asset.ref_count -= 1

		if asset.ref_count == 0 {
			_destroy_asset(handle, game.asset_system.allocator)
			return true
		}
	}

	return false
}

_destroy_asset :: proc(handle: Handle($T), allocator: mem.Allocator) {
	store := get_asset_store(T)
	asset := get_asset(handle)
	store.loaders.destroy(asset, allocator)
	delete_key(&store.assets, handle.path)
}

get_asset_path :: proc($T: typeid, path: string) -> ^T {
	return get_asset_handle(Handle(T){path})
}

get_asset_handle :: proc(handle: Handle($T)) -> ^T {
	if store := get_asset_store(T); store != nil {
		if asset, ok := &store.assets[handle.path]; ok {
			return asset
		}
	}

	return nil
}

get_asset :: proc {
	get_asset_path,
	get_asset_handle,
}

resolve_asset_path :: proc(handle: Handle($T), allocator := context.allocator) -> string {
	resolved, err := filepath.join({BASE_ASSET_DIR, handle.path}, allocator)
	return resolved
}

resolve_cooked_asset_path :: proc(handle: Handle($T), allocator := context.allocator) -> string {
	resolved, err := filepath.join({COOKED_ASSET_DIR, handle.path}, allocator)
	return resolved
}

init_asset_system :: proc(allocator := context.allocator) -> bool {
	game.asset_system.allocator = allocator
	game.asset_system.initialized = true

	return true
}

shutdown_asset_system :: proc() {
	if !game.asset_system.initialized {
		return
	}

	for _, &store in game.asset_system.stores {
		store.destroy(&store, context.allocator)
	}

	game.asset_system = {}
}

register_assets :: proc() {
	register_asset_type(Image_Asset, {load = load_image_asset, destroy = destroy_image_asset})
	register_asset_type(Material_Asset, {load = load_material_asset, destroy = destroy_material_asset})
	register_asset_type(Static_Mesh_Asset, {load = load_static_mesh_asset, destroy = destroy_static_mesh_asset})
	register_asset_type(Shader_Asset, {load = load_shader_asset, destroy = destroy_shader_asset})
	register_asset_type(Heightfield_Asset, {load = load_heightfield_asset, destroy = destroy_heightfield_asset})

	register_asset_processor(Shader_Asset, ".slang", process_shader_asset_slang)
}

// asset types

Image_Asset :: struct {
	using base: Asset,
	image_id:   gfx.ImageId,
}

load_image_asset :: proc(bytes: []u8, out: rawptr, allocator: mem.Allocator) -> bool {
	asset := cast(^Image_Asset)out

	asset^ = {
		image_id = load_image_from_ktx_memory(bytes),
	}

	return true
}

destroy_image_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Image_Asset)raw
	gfx.destroy_image(asset.image_id)
}

load_image_from_ktx_file :: proc(
	filename: string,
	image_type: vk.ImageType = .D2,
	debug_name: cstring = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> gfx.ImageId {
	bytes, read_err := os.read_entire_file(filename, allocator)
	assert(read_err == nil, "Failed to read file")
	defer delete(bytes)

	return load_image_from_ktx_memory(bytes, image_type, debug_name, loc)
}

load_image_from_ktx_memory :: proc(
	mem: []u8,
	image_type: vk.ImageType = .D2,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> gfx.ImageId {
	ktx_texture: ^ktx.Texture2
	ktx_result := ktx.Texture2_CreateFromMemory(raw_data(mem), len(mem), {.TEXTURE_CREATE_LOAD_IMAGE_DATA}, &ktx_texture)

	assert(ktx_result == .SUCCESS, "Failed to load image.")

	return load_image_from_ktx_texture(ktx_texture, loc = loc)
}

load_image_from_ktx_texture :: proc(ktx_texture: ^ktx.Texture2, debug_name: cstring = nil, loc := #caller_location) -> gfx.ImageId {
	num_dims := ktx_texture.numDimensions // Dimensions
	num_faces := ktx_texture.numFaces // Faces (cubemap)
	num_levels := ktx_texture.numLevels // Mip levels
	num_layers := ktx_texture.numLayers // Array levels

	image_type: vk.ImageType
	switch num_dims {
	case 1:
		image_type = .D1
	case 2:
		image_type = .D2
	case 3:
		image_type = .D3
	}

	is_array := ktx_texture.isArray
	is_cubemap := ktx_texture.isCubemap

	// Don't support cubemap arrays... if that's even a thing.
	assert(!(is_cubemap && is_array))

	// Assign cubemap faces instead.
	if is_cubemap do num_layers = num_faces

	size := ktx.Texture_GetDataSize(ktx_texture)
	data := ktx.Texture_GetData(ktx_texture)
	format := ktx.Texture_GetVkFormat(ktx_texture)

	extent := vk.Extent3D{ktx_texture.baseWidth, ktx_texture.baseHeight, ktx_texture.baseDepth}

	image := gfx.create_image(
		format,
		extent,
		{.SAMPLED, .TRANSFER_DST},
		image_type = image_type,
		mip_levels = num_levels,
		array_layers = num_layers,
		flags = is_cubemap ? {.CUBE_COMPATIBLE} : {},
		debug_name = debug_name,
		loc = loc,
	)

	// Next, upload image data to vk Image
	staging := gfx.create_buffer(u8, vk.DeviceSize(size), .Staging)
	mapped_data := staging.info.pMappedData

	mem.copy(mapped_data, data, int(size))

	copy_regions: [dynamic]vk.BufferImageCopy

	for i in 0 ..< num_layers {
		for level in 0 ..< num_levels {
			offset: uint
			if is_cubemap {
				ret := ktx.Texture_GetImageOffset(ktx_texture, level, 0, i, &offset)
				assert(ret == .SUCCESS)
			} else {
				ret := ktx.Texture_GetImageOffset(ktx_texture, level, i, 0, &offset)
				assert(ret == .SUCCESS)
			}

			copy_region := vk.BufferImageCopy{}
			copy_region.imageSubresource.aspectMask = {.COLOR}
			copy_region.imageSubresource.mipLevel = level
			copy_region.imageSubresource.baseArrayLayer = i
			copy_region.imageSubresource.layerCount = 1
			copy_region.imageExtent.width = max(ktx_texture.baseWidth >> level, 1)
			copy_region.imageExtent.height = max(ktx_texture.baseHeight >> level, 1)
			copy_region.imageExtent.depth = max(ktx_texture.baseDepth >> level, 1)
			copy_region.bufferOffset = vk.DeviceSize(offset)

			append(&copy_regions, copy_region)
		}
	}

	{
		cmd := gfx.immediate_submit()

		gfx.transition_image(cmd, image, .TRANSFER_DST_OPTIMAL)
		gfx.cmd_copy_buffer_to_image(cmd, staging, image, copy_regions[:])
		gfx.transition_image(cmd, image, .SHADER_READ_ONLY_OPTIMAL)
	}

	gfx.destroy_buffer(&staging)

	return image
}

write_buffer_to_ktx_file :: proc(
	filename: cstring,
	buffer: ^gfx.Buffer($T),
	extent: vk.Extent3D,
	format: vk.Format,
	format_size: u32,
	image_type: vk.ImageType = .D2,
	levels: u32 = 1,
	layers: u32 = 1,
	faces: u32 = 1,
	is_array: bool = false,
) {
	info := buffer.info
	max_size := info.size
	data := cast([^]u8)info.pMappedData

	assert(info.pMappedData != nil)

	ktx_texture: ^ktx.Texture2
	createInfo := ktx.TextureCreateInfo {
		vkFormat        = format,
		baseWidth       = extent.width,
		baseHeight      = extent.height,
		baseDepth       = extent.depth,
		numDimensions   = u32(image_type) + 1,
		numLevels       = levels,
		numLayers       = layers,
		numFaces        = faces,
		isArray         = is_array,
		generateMipmaps = false,
	}

	ktx.Texture2_Create(&createInfo, .TEXTURE_CREATE_ALLOC_STORAGE, &ktx_texture)

	offset: u32
	for level in 0 ..< levels {
		for face in 0 ..< faces {
			w := extent.width >> level
			h := extent.width >> level

			size := w * h * format_size

			assert(u32(offset) + size <= u32(max_size))

			res := ktx.Texture_SetImageFromMemory(ktx_texture, level, 0, face, data[offset:], uint(size))
			assert(res == .SUCCESS)

			offset += size
		}
	}

	res := ktx.Texture_WriteToNamedFile(ktx_texture, filename)
	assert(res == .SUCCESS)

	ktx.Texture_Destroy(ktx_texture)
}

Material_JSON :: struct {
	flags:                  []GPUMaterial_Flag,
	world_space_uv_scale:   f32,
	base_color:             string,
	normal_map:             string,
	proughness_metallic_ao: string,
}

Material_Asset :: struct {
	using base:             Asset,
	material_id:            MaterialId,
	base_color:             Handle(Image_Asset),
	normal_map:             Handle(Image_Asset),
	proughness_metallic_ao: Handle(Image_Asset),
}

load_material_asset :: proc(bytes: []u8, out: rawptr, allocator := context.allocator) -> bool {
	asset := cast(^Material_Asset)out

	parsed: Material_JSON
	parse_err := json.unmarshal(bytes, &parsed, spec = .Bitsquid, allocator = context.allocator)
	if parse_err != nil {
		return false
	}

	flags := slice.enum_slice_to_bitset(parsed.flags, GPUMaterial_Flags)

	base_color_id := Handle(Image_Asset){parsed.base_color}
	normal_map_id := Handle(Image_Asset){parsed.normal_map}
	proughness_metallic_ao_id := Handle(Image_Asset){parsed.proughness_metallic_ao}

	// Copy IDs before another insertion can relocate values in the image map.
	base_color_image := load_asset(base_color_id).image_id
	normal_map_image := load_asset(normal_map_id).image_id
	proughness_metallic_ao_image := load_asset(proughness_metallic_ao_id).image_id

	material_id := add_material(
		{
			flags = flags,
			world_space_uv_scale = parsed.world_space_uv_scale,
			base_color_id = base_color_image,
			normal_map_id = normal_map_image,
			ao_roughness_metallic_id = proughness_metallic_ao_image,
		},
	)

	asset^ = {
		material_id            = material_id,
		base_color             = base_color_id,
		normal_map             = normal_map_id,
		proughness_metallic_ao = proughness_metallic_ao_id,
	}

	return true
}

destroy_material_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Material_Asset)raw

	delete(asset.base_color.path)
	delete(asset.normal_map.path)
	delete(asset.proughness_metallic_ao.path)
	remove_material(asset.material_id)
}

Static_Mesh_Asset :: struct {
	using base:     Asset,
	gpu_buffers:    GPUMeshBuffers,
	body:           b3.BodyId,
	phys_mesh_data: ^b3.MeshData,
}

load_static_mesh_asset :: proc(bytes: []u8, out: rawptr, allocator: mem.Allocator) -> bool {
	asset := cast(^Static_Mesh_Asset)out

	mesh, ok := load_mesh_from_bytes(bytes, allocator)
	assert(ok)

	gpu_mesh := upload_mesh_to_gpu(mesh)

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

	phys_mesh_data := b3.CreateMesh(mesh_def, nil, 0)
	assert(phys_mesh_data != nil)

	asset^ = {
		gpu_buffers    = gpu_mesh,
		phys_mesh_data = phys_mesh_data,
	}

	return true
}

destroy_static_mesh_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Static_Mesh_Asset)raw

	gfx.destroy_buffer(&asset.gpu_buffers.vertex_buffer)
	gfx.destroy_buffer(&asset.gpu_buffers.index_buffer)
	gfx.destroy_accel(&asset.gpu_buffers.blas)

	if asset.phys_mesh_data != nil {
		b3.DestroyMesh(asset.phys_mesh_data)
		asset.phys_mesh_data = nil
	}
}

Shader_Asset :: struct {
	using base:  Asset,
	spirv_bytes: []u8,
}

load_shader_asset :: proc(bytes: []u8, out: rawptr, allocator: mem.Allocator) -> bool {
	asset := cast(^Shader_Asset)out
	asset^ = {
		spirv_bytes = bytes,
	}

	return true
}

destroy_shader_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Shader_Asset)raw
	delete(asset.spirv_bytes)
}

process_shader_asset_slang :: proc(path: string, allocator: mem.Allocator) -> (out_bytes: []u8, ok: bool) {
	diagnostics: ^slang.IBlob
	r: slang.Result

	session := init_slang_session()
	defer safe_release(session)

	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	module: ^slang.IModule = session->loadModule(path_c, &diagnostics)
	diagnostics_check(diagnostics)
	if module == nil {
		log.error("Shader", path, "doesn't exist.")
		return
	}

	components: [dynamic]^slang.IComponentType
	defer delete(components)

	append(&components, module)

	linked_program: ^slang.IComponentType
	r = session->createCompositeComponentType(&components[0], len(components), &linked_program, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	target_code: ^slang.IBlob
	r = linked_program->getTargetCode(0, &target_code, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	code_size := target_code->getBufferSize()
	source_code := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	assert(code_size % 4 == 0)

	out_bytes = slice.clone(source_code)
	ok = true

	return
}

Heightfield_Data :: struct {
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

Heightfield_Asset :: struct {
	using base:       Asset,
	gpu_buffers:      GPUMeshBuffers,
	phys_heightfield: ^b3.HeightFieldData,
}

parse_heightfield_data :: proc(data: []u8, allocator := context.allocator) -> (source: Heightfield_Data, ok: bool) {
	if len(data) < HEIGHTFIELD_HEADER_SIZE || data[0] != 'H' || data[1] != 'F' || data[2] != 'L' || data[3] != 'D' {
		log.error("Invalid heightfield header")
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
		log.error("Truncated heightfield header")
		return
	}
	if version != HEIGHTFIELD_FILE_VERSION {
		log.error("Unsupported heightfield version:", version)
		return
	}
	if count_x_u32 < 2 || count_z_u32 < 2 || count_x_u32 > HEIGHTFIELD_MAX_AXIS || count_z_u32 > HEIGHTFIELD_MAX_AXIS {
		log.error("Invalid heightfield dimensions:", count_x_u32, count_z_u32)
		return
	}
	if spacing_x <= 0 ||
	   spacing_z <= 0 ||
	   !is_finite(spacing_x) ||
	   !is_finite(spacing_z) ||
	   !is_finite(origin_x) ||
	   !is_finite(origin_z) ||
	   !is_finite(min_height) ||
	   !is_finite(max_height) ||
	   min_height > max_height {
		log.error("Invalid heightfield bounds or spacing")
		return
	}

	height_count_u64 := u64(count_x_u32) * u64(count_z_u32)
	expected_size := u64(HEIGHTFIELD_HEADER_SIZE) + height_count_u64 * size_of(f32)
	if u64(len(data)) != expected_size {
		log.error("Heightfield payload size mismatch:")
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
		if !value_ok || !is_finite(value) {
			log.error("Invalid height sample in:")
			delete(source.heights, allocator)
			source = {}
			return
		}
		height = value
	}

	ok = true
	return
}

heightfield_mesh :: proc(source: ^Heightfield_Data, allocator := context.allocator) -> Mesh {
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
				uv_x     = f32(x) / f32(source.count_x - 1),
				normal   = normal,
				uv_y     = f32(z) / f32(source.count_z - 1),
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

load_heightfield_asset :: proc(data: []u8, out: rawptr, allocator: mem.Allocator) -> bool {
	asset := cast(^Heightfield_Asset)out

	source, ok := parse_heightfield_data(data, context.temp_allocator)
	mesh := heightfield_mesh(&source, context.temp_allocator)

	gpu_mesh := upload_mesh_to_gpu(mesh)

	heightfield_def := b3.HeightFieldDef {
		heights             = raw_data(source.heights),
		scale               = {source.spacing_x, 1, source.spacing_z},
		countX              = c.int(source.count_x),
		countZ              = c.int(source.count_z),
		globalMinimumHeight = source.min_height,
		globalMaximumHeight = source.max_height,
		clockwiseWinding    = false,
	}

	heightfield := b3.CreateHeightField(heightfield_def)
	if heightfield == nil {
		log.error("Box3D failed to create heightfield:", heightfield)
	}

	asset^ = {
		gpu_buffers      = gpu_mesh,
		phys_heightfield = heightfield,
	}

	return true
}

destroy_heightfield_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Heightfield_Asset)raw

	gfx.destroy_buffer(&asset.gpu_buffers.vertex_buffer)
	gfx.destroy_buffer(&asset.gpu_buffers.index_buffer)
	gfx.destroy_accel(&asset.gpu_buffers.blas)

	b3.DestroyHeightField(asset.phys_heightfield)
}
