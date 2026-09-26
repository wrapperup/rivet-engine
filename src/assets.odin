package game

import "core:mem"
import virtual "core:mem/virtual"
import "core:os"

AssetSystem :: struct {
	arena:       virtual.Arena,
	allocator:   mem.Allocator,
	initialized: bool,
	// assets:      map[string]Asset,
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

Asset_Base :: struct {
	source_path: string,
	content:     []u8,
	// meta:        Asset_Meta,
	type:        Asset_Type,
}

Asset_Store :: struct($T: typeid) {
    assets: [dynamic]T,
}

Asset_Load_Result :: enum {
	Ready,
	Async,
	NotAvailable,
}

// TODO: Implement async path.
// load_asset :: proc(path: string, method := Asset_Load_Kind.Block) -> (asset: ^Asset, result: Asset_Load_Result) {
// 	asset_sys := &game.asset_system
//
// 	if found_asset := get_asset(path); found_asset != nil {
// 		return found_asset, .Ready
// 	}
//
// 	allocator := asset_sys.allocator
//
// 	fullpath, fullpath_err := os.get_absolute_path(path, allocator)
// 	if fullpath_err != nil {
// 		return {}, .NotAvailable
// 	}
//
// 	content, content_err := os.read_entire_file(path, allocator)
// 	if content_err != nil {
// 		return {}, .NotAvailable
// 	}
//
// 	new_asset := Asset {
// 		content     = content,
// 		source_path = fullpath,
// 	}
//
//     asset = get_asset(path)
// 	result = .Ready
//
//     // should never happen
//     assert(asset != nil)
//
// 	return
// }
//
// get_asset :: proc(path: string) -> ^Asset {
// 	asset_sys := &game.asset_system
//
// 	if _, found := asset_sys.assets[path]; found {
//         return &asset_sys.assets[path]
// 	}
//
// 	return nil
// }

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

// TODO: Revisit this.
//
// asset_content :: proc(name: Asset_Name) -> []u8 {
// 	return game.asset_system.assets[name].content
// }
//
// asset_path :: proc(name: Asset_Name) -> string {
// 	return game.asset_system.assets[name].source_path
// }
