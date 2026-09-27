package game

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import virtual "core:mem/virtual"

// TODO: refcount?

AssetSystem :: struct {
	arena:       virtual.Arena,
	allocator:   mem.Allocator,
	initialized: bool,
	stores:      map[typeid]Asset_Store_Raw,
}

Asset_Load_Kind :: enum {
	Block,
	Async,
}

Asset_Type :: enum {
	Unknown,
	Text,
	Sound,
	Texture,
	Mesh,
	SkinnedMesh,
	Font,
}

// TODO:
// Asset_Meta :: struct {}

Asset_Id :: struct($T: typeid) {
	index: u32,
	gen:   u32,
}

Asset_Base :: struct {
	source_path: string,
	gen:         u32,
	status:      Asset_Load_Result,
	// meta:        Asset_Meta,
}

Asset_Loaders :: struct {
	load: #type proc(path: string, allocator: mem.Allocator) -> bool,
	// TODO: unload...
}

Asset_Store_Raw :: struct {
	assets:  runtime.Raw_Map,
	loaders: Asset_Loaders,
}

Asset_Store :: struct($T: typeid) where intrinsics.type_is_subtype_of(T, Asset_Base) {
	assets:  map[string]T,
	loaders: Asset_Loaders,
}

Asset_Load_Result :: enum {
	Ready,
	Async,
	NotAvailable,
}

register_asset_type :: proc($T: typeid, loaders: Asset_Loaders) {
	assert(T not_in game.asset_system.stores, "Registered asset type more than once.")

	store := Asset_Store_Raw {
		loaders = loaders,
	}
}

get_asset_store :: proc($T: typeid) -> ^Asset_Store(T) {
	assert(T in game.asset_system.stores, "Registered asset type more than once.")

	return cast(^Asset_Store(T)) &game.asset_system.stores[T]
}

// load_asset :: proc(
// 	$T: typeid,
// 	path: string,
// 	method := Asset_Load_Kind.Block,
// 	allocator := context.allocator,
// ) -> (
// 	id: Asset_Id(T),
// 	asset: ^T,
// ) where intrinsics.type_is_subtype_of(T, Asset_Base) {
// 	if found_asset := get_asset(path); found_asset != nil {
// 		return found_asset
// 	}
//
// 	asset_sys := &game.asset_system
// 	allocator := asset_sys.allocator
//
// 	store := get_asset_store(T)
// 	if !store {
// 		return
// 	}
//
// 	if method == .Block {
// 		if !store.loaders.load(path) {
// 			return
// 		}
//
// 		asset = get_asset(path)
// 	} else if method == .Async {
// 		// TODO: tasks
// 		// knit.task()
//         unimplemented()
// 	}
//
// 	// should never happen
// 	assert(asset != nil)
//
// 	return
// }

get_asset :: proc(id: Asset_Id($T)) -> ^T {
	asset_sys := &game.asset_system

	if store_raw, found := asset_sys.stores[T]; found {
		store := cast(^Asset_Store(T))&store_raw

		if id.index < len(store.assets) {
			asset := &store.assets[id.index]

			if asset.gen == id.gen {
				return asset
			}
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
	if !game.asset_system.initialized do return
	virtual.arena_destroy(&game.asset_system.arena)
	game.asset_system = {}
}
