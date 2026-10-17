package game

import "core:os"
import vk "vendor:vulkan"

import "gfx"

@(shader_shared)
GPUDfgGeneratePassPC :: struct #max_field_align(16) {
	sample_count: u32,
	dfg_image:    gfx.Image_Id `RWImage2D<float2>`,
	multiscatter: bool,
}

DfgGeneratePass :: struct {
	pipeline:                gfx.Pipeline,

	// Resources
	dfg_image:               gfx.Image_Id,
	dfg_image_mapped_buffer: gfx.Buffer(f32),
	width, height:           u32,
}

create_dfg_generate_pipeline :: proc(width, height: u32) -> DfgGeneratePass {
    state := &game.render_state

	pass := DfgGeneratePass {
		width  = width,
		height = height,
	}

	// Load shader
    bytes, err := os.read_entire_file("shaders/out/dfg.spv", context.temp_allocator)
    assert(err == nil)

	dfg_shader, f_ok := gfx.load_shader_module_from_bytes(bytes)
	assert(f_ok, "Failed to load shaders.")

	pass.pipeline = gfx.create_compute_pipeline("DFG", dfg_shader, GPUDfgGeneratePassPC)
	gfx.defer_destroy(&state.global_arena, pass.pipeline)

	gfx.destroy_shader_module(dfg_shader)

	pass.dfg_image = gfx.create_image(.R16G16_SFLOAT, {width, height, 1}, {.STORAGE, .TRANSFER_SRC})

	// R16G16_SFLOAT = size_of(f32) * 1 (2 components mapped to bytes of float)
	pass.dfg_image_mapped_buffer = gfx.create_buffer(f32, width * height, .Host_Random)

	return pass
}

run_dfg_generate_pass :: proc(pass: ^DfgGeneratePass, cmd: gfx.Command_Buffer) {
	gfx.cmd_bind_pipeline(cmd, pass.pipeline)

	gfx.cmd_push_constants(cmd, GPUDfgGeneratePassPC{sample_count = 4096, multiscatter = false, dfg_image = pass.dfg_image})

	gfx.cmd_dispatch(cmd, pass.width / 16, pass.height / 16)
}
