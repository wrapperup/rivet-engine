package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:sys/windows"
import "core:time"

import glfw "vendor:glfw"

import "../src/gfx"

main :: proc() {
	glfw.Init()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

	window := glfw.CreateWindow(1920, 1080, "Triangle", nil, nil)

	gfx.init({window = window, enable_validation_layers = ODIN_DEBUG, enable_logs = ODIN_DEBUG})

	Vertex :: struct {
		pos:   [3]f32,
		color: [3]f32,
	}

	vertices: [3]Vertex = {
		{{-0.5, -0.5, 0.0}, {1.0, 0.0, 0.0}}, 
		{{-0.5, 0.5, 0.0}, {0.0, 1.0, 0.0}}, 
		{{0.5, 0.5, 0.0}, {0.0, 0.0, 1.0}}
	}
	indices: [3]u32 = {0, 1, 2}

    arena := &gfx.r_ctx.global_arena

	vertex_buffer := gfx.create_buffer([3]Vertex, len(vertices), .Storage)
    gfx.defer_destroy(arena, vertex_buffer)

	index_buffer := gfx.create_buffer([3]u32, len(indices), .Index)
    gfx.defer_destroy(arena, index_buffer)

	gfx.staging_write_buffer_slice(&vertex_buffer, vertices[:])
	gfx.staging_write_buffer_slice(&index_buffer, indices[:])

	shader, ok := gfx.load_shader_module("triangle.spv", context.temp_allocator)
	assert(ok)

    TrianglePushConstant :: struct {
        vertices: gfx.Ptr([3]Vertex)
    }

	triangle_pipeline := gfx.create_graphics_pipeline(
        name = "Triangle",
        shader = shader,
        input_topology = .TRIANGLE_LIST,
        polygon_mode = .FILL,
        front_face = .COUNTER_CLOCKWISE,
        color_format = gfx.r_ctx.draw_image.format,
        push_constants = TrianglePushConstant,
	)
    gfx.defer_destroy(arena, triangle_pipeline)

    gfx.destroy_shader_module(shader)

    assert(triangle_pipeline.pipeline != 0, "Failed to create pipeline")

	for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()

		cmd := gfx.begin_command_buffer()

		gfx.transition_image(cmd, &gfx.r_ctx.draw_image, .COLOR_ATTACHMENT_OPTIMAL)

        {
            gfx.cmd_begin_rendering(cmd,
                area = gfx.r_ctx.draw_extent,
                color_attachment = &{
                    view = gfx.r_ctx.draw_image.image_view,
                    layout = .COLOR_ATTACHMENT_OPTIMAL,
                },
            )

            gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)

            gfx.cmd_bind_pipeline(cmd, triangle_pipeline)

            gfx.cmd_bind_index_buffer(cmd, index_buffer.buffer)
            gfx.cmd_push_constants(cmd, TrianglePushConstant {
                vertices = vertex_buffer.ptr,
            })

            gfx.cmd_draw_indexed(cmd, len(indices))

            gfx.cmd_end_rendering(cmd)
        }

		gfx.transition_image(cmd, &gfx.r_ctx.draw_image, .TRANSFER_SRC_OPTIMAL)

		gfx.copy_image_to_swapchain(cmd, gfx.r_ctx.draw_image.image, gfx.r_ctx.draw_extent)

		gfx.submit(cmd)

		// Free temp allocations
		free_all(context.temp_allocator)
	}

    free_all(context.temp_allocator)

    gfx.shutdown()
}

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
