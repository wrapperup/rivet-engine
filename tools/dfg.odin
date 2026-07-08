package tools

import "core:flags"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:sys/windows"
import "core:time"

import vk "vendor:vulkan"

import "../src/gfx"
import ktx "deps:odin-libktx"
import vma "deps:odin-vma"

import impl "../src"

DfgCommand :: struct {
	output: cstring `args:"pos=0,required" usage:"Output file."`,
	size:   u32 `usage:"Size of the output texture"`,
}

main :: proc() {
	when ODIN_OS == .Windows {
		// Use UTF-8 for console output (fixes emojis/unicode/utf-8 shenanigans)
		windows.SetConsoleOutputCP(.UTF8)
	}
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	command: DfgCommand
	error := flags.parse(&command, os.args[1:])
	switch v in error {
	case flags.Help_Request:
		fmt.println("Usage:")
		fmt.println("  dfg <input> [FLAGS...]")
		fmt.println("")
		fmt.println("Available flags:")
		fmt.println("")
		fmt.println("  -size=256       Size of the generated DFG texture. [ktx]")
		fmt.println("")
	case flags.Parse_Error:
		fmt.println(v.message)
	case flags.Open_File_Error:
		fmt.println("Could not open", v.filename)
	case flags.Validation_Error:
		fmt.println(v.message)
	}

	start_time := time.now()

	size: u32 = 256
	if command.size > 0 do size = command.size
	calculate_dfg_to_file(fmt.ctprintf("%s%s", command.output, ".ktx2"), size, size)

	fmt.println("Done in", time.since(start_time))

	free_all()
}

calculate_dfg_to_file :: proc(filename: cstring, width, height: u32) {
	assert(width > 0)
	assert(height > 0)

	gfx.init()

	fmt.println("Generating DFG image...")
	pass := impl.create_dfg_generate_pipeline(width, height)
	if cmd, ok := gfx.immediate_submit(); ok {
		gfx.transition_image(cmd, &pass.image, .GENERAL)
		impl.run_dfg_generate_pass(&pass, cmd)

		region := vk.BufferImageCopy {
			imageOffset = {0, 0, 0},
			imageExtent = {width, height, 1},
			bufferOffset = 0,
			bufferRowLength = width,
			bufferImageHeight = height,
			imageSubresource = {mipLevel = 0, layerCount = 1, aspectMask = {.COLOR}, baseArrayLayer = 0},
		}

		// Copy image to staging buffer
		vk.CmdCopyImageToBuffer(cmd, pass.image.image, .GENERAL, pass.dfg_image_mapped_buffer.buffer, 1, &region)
	}

	extent := vk.Extent3D{pass.width, pass.height, 1}

	fmt.println("Writing DFG image to", filename)

	gfx.write_buffer_to_ktx_file(filename, &pass.dfg_image_mapped_buffer, extent, .R16G16_SFLOAT, size_of(f32))

	gfx.shutdown()
}
