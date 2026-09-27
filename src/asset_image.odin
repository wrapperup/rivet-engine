package game

import "core:mem"
import "core:os"
import "gfx"

Image_Asset :: struct {
	using base: Asset_Base,
	image_id:   gfx.ImageId,
}

load_image_asset :: proc(path: string, allocator: mem.Allocator) -> bool {
	bytes, err := os.read_entire_file(path, allocator)
	if err != nil {
		return false
	}

    gfx.load_image_from_file(path)

	// add_asset(Image_Asset{
	//        image_id = gfx.load_image_from_file
	//    })

	return true
}
