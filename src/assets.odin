package game

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"

import ktx "deps:odin-libktx"
import b3 "vendor:box3d"
import vk "vendor:vulkan"

import "gfx"

AssetSystem :: struct {
	arena:       virtual.Arena,
	allocator:   mem.Allocator,
	initialized: bool,
	stores:      map[typeid]Asset_Store_Raw,
}

Asset_Load_Kind :: enum {
	Block,
	// Async,
}

// TODO:
// Asset_Meta :: struct {}

Handle :: struct($T: typeid) {
	path: string,
}

Asset :: struct {
	source_path: string,
	status:      Asset_Load_Result,
	// meta:        Asset_Meta,
	ref_count:   int,
}

Asset_Processor_Proc :: #type proc(in_bytes: []u8, allocator: mem.Allocator) -> (out_bytes: []u8)

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

load_asset :: proc(
	handle: Handle($T),
	allocator := context.allocator,
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
		return
	}

	if method == .Block {
		bytes, err := os.read_entire_file(handle.path, allocator)
		if err != nil {
			return
		}

		new_asset: T
		if !store.loaders.load(bytes, &new_asset, allocator) {
			return
		}

		store.assets[handle.path] = new_asset
		asset = &store.assets[handle.path]
	}

	// should never happen
	assert(asset != nil)

	asset.status = .Ready
	asset.ref_count = 1

	return
}

release_asset :: proc(handle: Handle($T)) -> (destroyed: bool) {
	asset := get_asset(handle)
	if asset == nil {
		return false
	}

	if asset.ref_count > 0 {
		asset.ref_count -= 1

		if asset.ref_count == 0 {
			_destroy_asset(handle)
			return true
		}
	}

	return false
}

_destroy_asset :: proc(handle: Handle($T)) {
	store := get_asset_store(T)
	asset := get_asset(handle)
	store.loaders.destroy(asset, context.allocator)
	delete_key(&store.assets, handle.path)
}

get_asset :: proc(handle: Handle($T)) -> ^T {
	if store := get_asset_store(T); store != nil {
		if asset, ok := &store.assets[handle.path]; ok {
			return asset
		}
	}

	return nil
}

init_asset_system :: proc() -> bool {
	if virtual.arena_init_growing(&game.asset_system.arena) != nil {
		return false
	}

	game.asset_system.allocator = virtual.arena_allocator(&game.asset_system.arena)
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

	virtual.arena_destroy(&game.asset_system.arena)
	game.asset_system = {}
}

register_assets :: proc() {
	register_asset_type(Image_Asset, {load = load_image_asset, destroy = destroy_image_asset})
	register_asset_type(Material_Asset, {load = load_material_asset, destroy = destroy_material_asset})
	register_asset_type(Static_Mesh_Asset, {load = load_static_mesh_asset, destroy = destroy_static_mesh_asset})
	register_asset_type(Shader_Asset, {load = load_shader_asset, destroy = destroy_shader_asset})
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

	if cmd, ok := gfx.immediate_submit(); ok {
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

	base_color_id := Handle(Image_Asset){parsed.base_color}
	normal_map_id := Handle(Image_Asset){parsed.normal_map}
	proughness_metallic_ao_id := Handle(Image_Asset){parsed.proughness_metallic_ao}

	// Copy IDs before another insertion can relocate values in the image map.
	base_color_image := load_asset(base_color_id, allocator).image_id
	normal_map_image := load_asset(normal_map_id, allocator).image_id
	proughness_metallic_ao_image := load_asset(proughness_metallic_ao_id, allocator).image_id

	material_id := add_material(
		{base_color_id = base_color_image, normal_map_id = normal_map_image, ao_roughness_metallic_id = proughness_metallic_ao_image},
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
