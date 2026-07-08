package game

import vk "vendor:vulkan"

import "gfx"

DfgGeneratePassPC :: struct {
	sample_count: u32,
	multiscatter: b32,
	dfg_image:    gfx.ImageId,
}

DfgGeneratePass :: struct {
	pipeline:                gfx.ComputePipeline,

	// Resources
	image:                   gfx.GPUImage, // backing image (tool needs it for layout transitions/readback)
	dfg_image:               gfx.ImageId,
	dfg_image_mapped_buffer: gfx.GPUBuffer(f32),
	width, height:           u32,
}

create_dfg_generate_pipeline :: proc(width, height: u32) -> DfgGeneratePass {
	pass := DfgGeneratePass {
		width  = width,
		height = height,
	}

    // Load shader
    dfg_shader, f_ok := gfx.load_shader_module("shaders/out/dfg.spv", context.temp_allocator)
    assert(f_ok, "Failed to load shaders.")

    pass.pipeline = gfx.create_compute_pipeline("DFG", dfg_shader, DfgGeneratePassPC)
    gfx.defer_destroy(&gfx.r_ctx.global_arena, pass.pipeline)

    gfx.destroy_shader_module(dfg_shader)

	pass.image = gfx.create_image(.R16G16_SFLOAT, {width, height, 1}, {.STORAGE, .TRANSFER_SRC})
	pass.dfg_image = gfx.add_image(pass.image)

	// R16G16_SFLOAT = size_of(f32) * 1 (2 components mapped to bytes of float)
	pass.dfg_image_mapped_buffer = gfx.create_buffer(f32, width * height, .Readback)

	return pass
}

run_dfg_generate_pass :: proc(pass: ^DfgGeneratePass, cmd: vk.CommandBuffer) {
	gfx.cmd_bind_pipeline(cmd, pass.pipeline)

	gfx.cmd_push_constants(cmd, DfgGeneratePassPC {
		sample_count = 4096,
		multiscatter = false,
        dfg_image = pass.dfg_image
    })

	gfx.cmd_dispatch(cmd, pass.width / 16, pass.height / 16)
}
