package game

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:os"

import b3 "vendor:box3d"

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

Asset_Id :: struct($T: typeid) {
	path: string,
}

Asset_Base :: struct {
	source_path: string,
	status:      Asset_Load_Result,
	// meta:        Asset_Meta,
	ref_count:   int,
}

Asset_Loaders :: struct {
	load:    #type proc(path: string, allocator: mem.Allocator) -> bool,
	destroy: #type proc(asset: rawptr, allocator: mem.Allocator),
	// TODO: unload...
}

Asset_Store_Raw :: struct {
	assets:  runtime.Raw_Map,
	loaders: Asset_Loaders,
	inspect: Asset_Inspect_Proc,
}

Asset_Store :: struct($T: typeid) where intrinsics.type_is_subtype_of(T, Asset_Base) {
	assets:  map[string]T,
	loaders: Asset_Loaders,
	inspect: Asset_Inspect_Proc,
}

Asset_Debug_Entry :: struct {
	path:       string,
	asset_type: typeid,
	status:     Asset_Load_Result,
}

Asset_Inspect_Proc :: #type proc(assets: ^runtime.Raw_Map, entries: ^[dynamic]Asset_Debug_Entry)

inspect_asset_store :: proc(assets: ^runtime.Raw_Map, entries: ^[dynamic]Asset_Debug_Entry, $T: typeid) {
	store := cast(^map[string]T)assets
	for path, asset in store^ {
		append(entries, Asset_Debug_Entry{path, T, asset.status})
	}
}

Asset_Load_Result :: enum {
	Ready,
	// Async,
	NotAvailable,
}

register_asset_type :: proc($T: typeid, loaders: Asset_Loaders) {
	assert(T not_in game.asset_system.stores, "Registered asset type more than once.")

	store := Asset_Store_Raw {
		loaders = loaders,
		inspect = proc(assets: ^runtime.Raw_Map, entries: ^[dynamic]Asset_Debug_Entry) {
			inspect_asset_store(assets, entries, T)
		},
	}

	game.asset_system.stores[T] = store
}

get_asset_store :: proc($T: typeid) -> ^Asset_Store(T) {
	assert(T in game.asset_system.stores, "Asset store not registered for this type.")

	return cast(^Asset_Store(T))&game.asset_system.stores[T]
}

load_asset :: proc(
	id: Asset_Id($T),
	allocator := context.allocator,
	method := Asset_Load_Kind.Block,
) -> (
	asset: ^T,
) where intrinsics.type_is_subtype_of(T, Asset_Base) {
	if found_asset := get_asset(id); found_asset != nil {
		return found_asset
	}

	asset_sys := &game.asset_system
	allocator := asset_sys.allocator

	store := get_asset_store(T)
	if store == nil {
		return
	}

	if method == .Block {
		if !store.loaders.load(id.path, allocator) {
			return
		}

		asset = get_asset(id)
	}

	// should never happen
	assert(asset != nil)

	return
}

release_asset :: proc(id: Asset_Id($T)) -> (destroyed: bool) {
	asset := get_asset(id)

	if asset.ref_count > 0 {
		asset.ref_count -= 1

		if asset.ref_count == 0 {
			_destroy_asset(id)
			return true
		}
	}

	return false
}

_destroy_asset :: proc(id: Asset_Id($T)) {
	store := get_asset_store(T)
	asset := get_asset(id)
	store.loaders.destroy(asset, context.allocator)
}

add_asset :: proc(path: string, asset: $T) -> Asset_Id(T) where intrinsics.type_is_subtype_of(T, Asset_Base) {
	store := get_asset_store(T)
	store.assets[path] = asset

	return {path}
}

get_asset :: proc(id: Asset_Id($T)) -> ^T {
	if store := get_asset_store(T); store != nil {
		return &store.assets[id.path]
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
	if !game.asset_system.initialized do return
	virtual.arena_destroy(&game.asset_system.arena)
	game.asset_system = {}
}

register_assets :: proc() {
	register_asset_type(Image_Asset, {load = load_image_asset, destroy = destroy_image_asset})
	register_asset_type(Material_Asset, {load = load_material_asset, destroy = destroy_material_asset})
	register_asset_type(Static_Mesh_Asset, {load = load_static_mesh_asset, destroy = destroy_static_mesh_asset})
}

// asset types

Image_Asset :: struct {
	using base: Asset_Base,
	image_id:   gfx.ImageId,
}

load_image_asset :: proc(path: string, allocator: mem.Allocator) -> bool {
	// bytes, err := os.read_entire_file(path, context.temp_allocator)
	//    defer delete(bytes)
	// if err != nil {
	// 	return false
	// }

	image := gfx.load_image_from_file(path)
	add_asset(path, Image_Asset{image_id = image})

	return true
}

destroy_image_asset :: proc(raw: rawptr, allocator: mem.Allocator) {
	asset := cast(^Image_Asset)raw
	gfx.destroy_image(asset.image_id)
}

Material_JSON :: struct {
	base_color:             string,
	normal_map:             string,
	proughness_metallic_ao: string,
}

Material_Asset :: struct {
	using base:             Asset_Base,
	material_id:            MaterialId,
	base_color:             Asset_Id(Image_Asset),
	normal_map:             Asset_Id(Image_Asset),
	proughness_metallic_ao: Asset_Id(Image_Asset),
}

load_material_asset :: proc(path: string, allocator := context.allocator) -> bool {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	assert(read_err == nil, "Failed to read font json")
	defer delete(bytes)

	parsed: Material_JSON
	parse_err := json.unmarshal(bytes, &parsed, spec = .Bitsquid, allocator = context.allocator)

	base_color_id := Asset_Id(Image_Asset){parsed.base_color}
	normal_map_id := Asset_Id(Image_Asset){parsed.normal_map}
	proughness_metallic_ao_id := Asset_Id(Image_Asset){parsed.proughness_metallic_ao}

	base_color_asset := load_asset(base_color_id, allocator)
	normal_map_asset := load_asset(normal_map_id, allocator)
	proughness_metallic_ao_asset := load_asset(proughness_metallic_ao_id, allocator)

	material_id := add_material(
		{
			base_color_id = base_color_asset.image_id,
			normal_map_id = normal_map_asset.image_id,
			ao_roughness_metallic_id = proughness_metallic_ao_asset.image_id,
		},
	)

	add_asset(
		path,
		Material_Asset {
			material_id = material_id,
			base_color = base_color_id,
			normal_map = normal_map_id,
			proughness_metallic_ao = proughness_metallic_ao_id,
		},
	)

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
	using base:     Asset_Base,
	gpu_buffers:    GPUMeshBuffers,
	body:           b3.BodyId,
	phys_mesh_data: ^b3.MeshData,
}

load_static_mesh_asset :: proc(path: string, allocator := context.allocator) -> bool {
	mesh, ok := load_mesh_from_file(path, context.temp_allocator)
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

	add_asset(path, Static_Mesh_Asset{gpu_buffers = gpu_mesh, phys_mesh_data = phys_mesh_data})

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
