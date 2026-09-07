package game

import virtual "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

AssetSystem :: struct {
	arena:       virtual.Arena,
	initialized: bool,
	assets:      [Asset_Name]Asset,
}

Asset_Load_Kind :: enum {
    Block,
    Async
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

Asset :: struct {
	source_path: string,
	content:     []u8,
	// meta:        Asset_Meta,
	type:        Asset_Type,
}

// TODO: Replace this hack with meta files.
asset_type_from_base :: proc(base: string) -> Asset_Type {
	asset_type := Asset_Type.Unknown

	switch filepath.ext(base) {
	case ".wav":
		asset_type = .Sound
	case ".txt":
		asset_type = .Text
	case ".glb":
		if strings.starts_with(base, "sk") {
			asset_type = .SkinnedMesh
		} else {
			asset_type = .Mesh
		}
	case ".ktx2":
		asset_type = .Texture
	case ".ttf":
		asset_type = .Font
	}

	return asset_type
}

Asset_Load_Result :: enum {
    Ready,
    Async,
    NotAvailable,
}

// TODO: Implement async path.
load_asset :: proc(path: string, method := Asset_Load_Kind.Block) -> (asset: Asset, result: Asset_Load_Result) {
	base := filepath.base(path)
	asset_type := asset_type_from_base(base)
	allocator := virtual.arena_allocator(&game.asset_system.arena)

	fullpath, fullpath_err := os.get_absolute_path(path, allocator)
	if fullpath_err != nil {
		return {}, .NotAvailable
	}

	content: []u8
	if asset_type == .Text || asset_type == .Texture || asset_type == .Font {
		content_err: os.Error
		content, content_err = os.read_entire_file(path, allocator)
		if content_err != nil {
			return {}, .NotAvailable
		}
	}

	asset = {
		type        = asset_type,
		content     = content,
		source_path = fullpath,
	}

	result = .Ready

	return
}

init_asset_system :: proc() -> bool {
	if virtual.arena_init_growing(&game.asset_system.arena) != nil {
		return false
	}
	game.asset_system.initialized = true

	if load_generated_assets() != .Ready {
		shutdown_asset_system()
		return false
	}
	return true
}

shutdown_asset_system :: proc() {
	if !game.asset_system.initialized do return
	virtual.arena_destroy(&game.asset_system.arena)
	game.asset_system = {}
}

get_asset :: proc(name: Asset_Name) -> ^Asset {
	return &game.asset_system.assets[name]
}

asset_content :: proc(name: Asset_Name) -> []u8 {
	return game.asset_system.assets[name].content
}

asset_path :: proc(name: Asset_Name) -> string {
	return game.asset_system.assets[name].source_path
}
