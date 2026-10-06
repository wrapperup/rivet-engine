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

EnvPrefilterCommand :: struct {
	input:   cstring `args:"pos=0,required" usage:"Input file."`,
	output:  cstring `args:"pos=1,required" usage:"Output file."`,
	size:    u32 `usage:"Size (in px) of the output texture"`,
	samples: u32 `usage:"Samples to use in prefiltering"`,
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

	command: EnvPrefilterCommand
	error := flags.parse(&command, os.args[1:])
	switch v in error {
	case flags.Help_Request:
		fmt.println("Usage:")
		fmt.println("  dfg <input> [FLAGS...]")
		fmt.println("")
		fmt.println("Available flags:")
		fmt.println("")
		fmt.println("  -size=256       Size of the generated prefiltered cubemap faces. [ktx]")
		fmt.println("  -samples=4096   Number of samples to use in prefiltering.")
		fmt.println("")
	case flags.Parse_Error:
		fmt.println(v.message)
	case flags.Open_File_Error:
		fmt.println("Could not open", v.filename)
	case flags.Validation_Error:
		fmt.println(v.message)
	}

	start_time := time.now()

	if command.size == 0 {
		command.size = 256
	}

	if command.samples == 0 {
		command.samples = 4096
	}

	process_env_to_file(
		fmt.ctprint(command.input),
		fmt.ctprintf("%s%s", command.output, ".ktx2"),
		command.size,
		command.size,
		command.samples,
	)

	fmt.println("Done in", time.since(start_time))

	free_all()
}

process_env_to_file :: proc(in_filename: cstring, out_filename: cstring, out_width, out_height: u32, samples: u32) {
	gfx.init({enable_validation_layers = true, enable_logs = true})

	fmt.println("Generating Cubemap image...")
	pass := impl.create_prefiltered_cubemap_pipeline(in_filename, out_width, out_height)
	assert(pass.width > 0)
	assert(pass.height > 0)
	if cmd, ok := gfx.immediate_submit(); ok {
		gfx.transition_image(cmd, pass.prefilter_image.image, .UNDEFINED, .GENERAL)
		impl.run_prefilter_cubemap_pass(&pass, cmd, samples)

		buffer_offset: u32
		for level in 0 ..< impl.MAX_ROUGHNESS_LEVELS {
			w := pass.width >> level
			h := pass.height >> level

			region := vk.BufferImageCopy {
				imageOffset = {0, 0, 0},
				imageExtent = {w, h, 1},
				bufferOffset = vk.DeviceSize(buffer_offset),
				bufferRowLength = w,
				bufferImageHeight = h,
				imageSubresource = {mipLevel = level, baseArrayLayer = 0, layerCount = 6, aspectMask = {.COLOR}},
			}

			buffer_offset += w * h * size_of(f32) * 4 * 6 // R32G32B32A32_SFLOAT

			// Copy image to staging buffer
			vk.CmdCopyImageToBuffer(cmd, pass.prefilter_image.image, .GENERAL, pass.prefilter_image_mapped_buffer.buffer, 1, &region)
		}
	}

	extent := vk.Extent3D{pass.width, pass.height, 1}

	fmt.println("Writing Cubemap image to", out_filename)

	gfx.write_buffer_to_ktx_file(
		out_filename,
		&pass.prefilter_image_mapped_buffer,
		extent,
		.R32G32B32A32_SFLOAT,
		size_of(f32) * 4,
		.D2,
		impl.MAX_ROUGHNESS_LEVELS,
		1,
		6,
		false,
	)

	gfx.shutdown()
}
