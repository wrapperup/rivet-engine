package game

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"

import "gfx"

MAX_UI_COMMANDS :: 256
UI_REFERENCE_SIZE :: Vec2{1920, 1080}

@(shader_shared)
UI_Mode :: enum u32 {
	Color,
	Image,
	Glyph,
}

@(shader_shared)
UI_Command :: struct #max_field_align(16) {
	mode:          u32, // TODO: support enums. this is UI_Mode.
	pos:           Vec2,
	angle:         f32,
	size:          Vec2,
	uv_min:        Vec2,
	uv_max:        Vec2,
	image:         gfx.ImageId `Image2D`,
	color:         Vec4,
	radius:        Vec4, // clockwise from top-left corner
	unit_range:    Vec2,
	outline_color: Vec4,
	outline_width: f32, // framebuffer pixels
}

@(shader_shared)
UI_Push :: struct #max_field_align(16) {
	commands:      gfx.Slice(UI_Command),
	viewport_size: Vec2,
	sampler:       gfx.SamplerId `Sampler`,
}

UIRenderPass :: struct {
	pipeline:        ^gfx.GraphicsPipeline,
	sampler_id:      gfx.SamplerId,
	commands:        [dynamic]UI_Command,
	num_commands:    int,
	command_buffers: [gfx.FRAME_OVERLAP]gfx.Buffer(UI_Command),
	font:            Font,
}

Glyph :: struct {
	advance:        f32,
	has_bounds:     bool,
	offset, size:   Vec2, // em units, relative to the baseline, Y down
	uv_min, uv_max: Vec2,
}

Font :: struct {
	image:               gfx.ImageId,
	glyphs:              map[rune]Glyph,
	kerning:             map[[2]rune]f32,
	unit_range:          Vec2,
	line_height:         f32, // em units
	ascender, descender: f32,
}

Text_Alignment :: enum {
	Left,
	Center,
	Right,
}

load_font :: proc(image_path: cstring, json_path: string, allocator := context.allocator) -> (font: Font) {
	Bounds :: struct {
		left, top, right, bottom: f32,
	}

	Atlas_JSON :: struct {
		atlas:   struct {
			distance_range: f32 `json:"distanceRange"`,
			width, height:  u32,
		},
		metrics: struct {
			line_height:         f32 `json:"lineHeight"`,
			ascender, descender: f32,
		},
		glyphs:  []struct {
			unicode:      u32,
			advance:      f32,
			plane_bounds: Bounds `json:"planeBounds"`,
			atlas_bounds: Bounds `json:"atlasBounds"`,
		},
		kerning: []struct {
			unicode1, unicode2: u32,
			advance:            f32,
		},
	}

	bytes, read_err := os.read_entire_file(json_path, context.allocator)
	assert(read_err == nil, "Failed to read font json")
	defer delete(bytes)

	parsed: Atlas_JSON
	parse_err := json.unmarshal(bytes, &parsed, allocator = context.allocator)
	defer delete(parsed.glyphs)
	defer delete(parsed.kerning)

	assert(parse_err == nil, "Failed to parse font json")

	assert(parsed.atlas.width > 0 && parsed.atlas.height > 0 && parsed.atlas.distance_range > 0, "Invalid font atlas dimensions or range.")
	assert(len(parsed.glyphs) > 0 && parsed.metrics.line_height > 0, "Font has no glyphs or an invalid line height.")

	image := gfx.load_image_from_file(image_path)

	assert(
		image.format == .R8G8B8A8_UNORM || image.format == .B8G8R8A8_UNORM || image.format == .BC7_UNORM_BLOCK,
		"MTSDF atlas must use linear RGBA8, BGRA8, or BC7. Export with a non-sRGB format.",
	)
	assert(
		image.extent.width == parsed.atlas.width && image.extent.height == parsed.atlas.height,
		"Font atlas dimensions do not match its JSON.",
	)

	font.image = gfx.add_image(image)
	font.line_height = parsed.metrics.line_height
	font.ascender = parsed.metrics.ascender
	font.descender = parsed.metrics.descender
	atlas_size := Vec2{f32(parsed.atlas.width), f32(parsed.atlas.height)}
	font.unit_range = parsed.atlas.distance_range / atlas_size

	font.glyphs = make(map[rune]Glyph, len(parsed.glyphs), allocator)
	for g in parsed.glyphs {
		plane, atlas := g.plane_bounds, g.atlas_bounds
		font.glyphs[rune(g.unicode)] = {
			advance    = g.advance,
			has_bounds = atlas.right > atlas.left && atlas.bottom > atlas.top,
			offset     = {plane.left, plane.top},
			size       = {plane.right - plane.left, plane.bottom - plane.top},
			uv_min     = Vec2{atlas.left, atlas.top} / atlas_size,
			uv_max     = Vec2{atlas.right, atlas.bottom} / atlas_size,
		}
	}

	font.kerning = make(map[[2]rune]f32, len(parsed.kerning), allocator)
	for pair in parsed.kerning {
		font.kerning[{rune(pair.unicode1), rune(pair.unicode2)}] = pair.advance
	}

	return
}

init_ui_rp :: proc() {
	ui_rp := &game.render_state.ui_rp

	ui_rp.pipeline = add_graphics_shader("shaders/ui.slang", proc(module: gfx.ShaderModule) -> gfx.GraphicsPipeline {
		return gfx.create_graphics_pipeline(
			name = "UI_Pipeline",
			shader = module,
			input_topology = .TRIANGLE_STRIP,
			polygon_mode = .FILL,
			cull_mode = {},
			front_face = .CLOCKWISE,
			color_format = gfx.r_ctx.draw_image.format,
			multisampling_samples = ._1,
			push_constants = UI_Push,
			blend_mode = .Alpha,
		)
	})

	// TODO: improve api ergonomics, there's no need for us to manage vk images/samplers.
	sampler := gfx.create_sampler(.LINEAR, .REPEAT)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, sampler)
	sampler_id := gfx.add_sampler(sampler)
	ui_rp.sampler_id = sampler_id

	ui_rp.font = load_font(
		"assets/fonts/msdf/f_nunito_regular_mtsdf.ktx2",
		"assets/fonts/msdf/f_nunito_regular_mtsdf.json",
		virtual.arena_allocator(&game.asset_system.arena),
	)

	for i in 0 ..< gfx.FRAME_OVERLAP {
		buffer := gfx.create_buffer(UI_Command, MAX_UI_COMMANDS, .Storage, "UI_Command_Buffer")
		ui_rp.command_buffers[i] = buffer
		gfx.defer_destroy(&gfx.r_ctx.global_arena, buffer)
	}

	reserve(&game.render_state.geometry_rp.model_matrices, 16_000)
}

ui_rect :: proc(
	pos: Vec2,
	size: Vec2,
	color: Vec4 = 1,
	radius: Vec4 = 0,
	anchor: Vec2 = 0.5,
	pivot: Vec2 = 0.5,
	image: gfx.ImageId = 0,
	uv_min: Vec2 = 0,
	uv_max: Vec2 = 1,
) {
	ui_command(pos, size, color, radius, anchor, pivot, image != 0 ? UI_Mode.Image : UI_Mode.Color, image, uv_min, uv_max)
}

measure_glyph :: proc(codepoint: rune, size: f32 = 32, font: ^Font = nil) -> Vec2 {
	assert(size >= 0, "Glyph size must be nonnegative.")

	font := font
	if font == nil {
		font = &game.render_state.ui_rp.font
	}

	glyph, found := font.glyphs[codepoint]
	assert(found, "UI font does not contain the requested codepoint.")
	return {glyph.advance * size, font.line_height * size}
}

measure_text :: proc(text: string, size: f32 = 32, font: ^Font = nil) -> Vec2 {
	return ui_text_impl(text, draw = false, size = size, font = font)
}

ui_glyph :: proc(
	codepoint: rune,
	pos: Vec2,
	size: f32 = 32,
	color: Vec4 = 1,
	anchor: Vec2 = 0.5,
	font: ^Font = nil,
	outline_width: f32 = 0,
	outline_color: Vec4 = {0, 0, 0, 1},
	pixel_snap: bool = false,
) -> f32 {
	assert(size >= 0 && outline_width >= 0, "Glyph size and outline width must be nonnegative.")

	font := font
	if font == nil {
		font = &game.render_state.ui_rp.font
	}

	glyph, found := font.glyphs[codepoint]
	assert(found, "UI font does not contain the requested codepoint.")

	advance := glyph.advance * size

	if size == 0 || !glyph.has_bounds {
		return advance
	}

	ui_command(
		pos = pos + glyph.offset * size,
		size = glyph.size * size,
		color = color,
		anchor = anchor,
		pivot = 0,
		mode = .Glyph,
		image = font.image,
		uv_min = glyph.uv_min,
		uv_max = glyph.uv_max,
		unit_range = font.unit_range,
		outline_color = outline_color,
		outline_width = outline_width,
		pixel_snap_x = pixel_snap,
	)

	return advance
}

ui_text :: proc(
	text: string,
	pos: Vec2,
	size: f32 = 32,
	color: Vec4 = 1,
	anchor: Vec2 = 0.5,
	font: ^Font = nil,
	outline_width: f32 = 0,
	outline_color: Vec4 = {0, 0, 0, 1},
	align: Text_Alignment = .Left,
	pixel_snap: bool = false,
) -> f32 {
	pos := pos
	switch align {
	case .Left:
	case .Center:
		pos.x -= measure_text(text, size, font).x * 0.5
	case .Right:
		pos.x -= measure_text(text, size, font).x
	}

	return ui_text_impl(text, true, pos, size, color, anchor, font, outline_width, outline_color, pixel_snap).x
}

ui_text_impl :: proc(
	text: string,
	draw: bool,
	pos: Vec2 = 0,
	size: f32 = 32,
	color: Vec4 = 1,
	anchor: Vec2 = 0.5,
	font: ^Font = nil,
	outline_width: f32 = 0,
	outline_color: Vec4 = {0, 0, 0, 1},
	pixel_snap: bool = false,
) -> Vec2 {
	assert(size >= 0 && outline_width >= 0, "Text size and outline width must be nonnegative.")

	font := font
	if font == nil {
		font = &game.render_state.ui_rp.font
	}

	width: f32
	passes := draw && outline_width > 0 ? 2 : 1
	for pass in 0 ..< passes {
		outline_pass := passes == 2 && pass == 0
		draw_color := outline_pass ? outline_color : color
		draw_outline_width := outline_pass ? outline_width : 0
		width = 0
		previous: rune
		has_previous := false

		for codepoint in text {
			if has_previous {
				width += font.kerning[{previous, codepoint}] * size
			}

			if draw {
				width += ui_glyph(
					codepoint,
					pos + Vec2{width, 0},
					size,
					draw_color,
					anchor,
					font,
					draw_outline_width,
					outline_color,
					pixel_snap,
				)
			} else {
				width += measure_glyph(codepoint, size, font).x
			}

			previous = codepoint
			has_previous = true
		}
	}

	return {width, font.line_height * size}
}

ui_command :: proc(
	pos: Vec2,
	size: Vec2,
	color: Vec4 = 1,
	radius: Vec4 = 0,
	anchor: Vec2 = 0.5,
	pivot: Vec2 = 0.5,
	mode: UI_Mode = .Color,
	image: gfx.ImageId = 0,
	uv_min: Vec2 = 0,
	uv_max: Vec2 = 1,
	unit_range: Vec2 = 0,
	outline_color: Vec4 = 0,
	outline_width: f32 = 0,
	pixel_snap_x: bool = false,
) {
	draw_extent := Vec2(transmute([2]u32)game.renderer.draw_extent)

	scale := draw_extent / UI_REFERENCE_SIZE
	min_scale := slice.min(scale[:])

	pos := pos * min_scale
	size := size * min_scale
	radius := radius * min_scale
	outline_width := outline_width * min_scale

	anchor_pos := draw_extent * anchor
	pivot_offset := size * pivot

	pos = pos + anchor_pos - pivot_offset
	if pixel_snap_x {
		pos.x = math.round(pos.x)
	}

	ui_command_absolute(pos, size, color, radius, mode, image, uv_min, uv_max, unit_range, outline_color, outline_width)
}

ui_command_absolute :: proc(
	pos: Vec2,
	size: Vec2,
	color: Vec4 = 1,
	radius: Vec4 = 0,
	mode: UI_Mode = .Color,
	image: gfx.ImageId = 0,
	uv_min: Vec2 = 0,
	uv_max: Vec2 = 1,
	unit_range: Vec2 = 0,
	outline_color: Vec4 = 0,
	outline_width: f32 = 0,
) {
	radius := radius

	half_size := size / 2
	max_radius := slice.min(half_size[:])

	for &r in radius {
		r = min(r, max_radius)
	}

	command := UI_Command {
		mode          = u32(mode),
		pos           = pos,
		size          = size,
		color         = color,
		radius        = radius,
		uv_min        = uv_min,
		uv_max        = uv_max,
		image         = image,
		unit_range    = unit_range,
		outline_color = outline_color,
		outline_width = outline_width,
	}

	append(&game.render_state.ui_rp.commands, command)
}

ui_prepare :: proc() {
	ui_rp := &game.render_state.ui_rp

	assert(len(ui_rp.commands) <= MAX_UI_COMMANDS, "Submitted too many UI commands.")

	if len(ui_rp.commands) > 0 {
		gfx.staging_write_buffer_slice(&ui_rp.command_buffers[gfx.current_frame_index()], ui_rp.commands[:])
	}

	ui_rp.num_commands = len(ui_rp.commands)
	clear(&ui_rp.commands)
}

record_ui_pass :: proc(cmd: gfx.CommandBuffer) {
	ui_rp := &game.render_state.ui_rp

	gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .COLOR_ATTACHMENT_OPTIMAL)

	{
		gfx.cmd_begin_label(cmd, "UI")
		gfx.cmd_begin_rendering(
			cmd,
			area = gfx.r_ctx.draw_extent,
			color_attachment = &{view = gfx.r_ctx.resolve_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		)

		gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)

		gfx.cmd_bind_pipeline(cmd, ui_rp.pipeline)

		commands := gfx.slice(ui_rp.command_buffers[gfx.current_frame_index()])
		gfx.cmd_push_constants(
			cmd,
			UI_Push {
				commands = commands,
				viewport_size = auto_cast (transmute([2]u32)game.renderer.draw_extent),
				sampler = ui_rp.sampler_id,
			},
		)

		gfx.cmd_draw(cmd, 4, u32(game.render_state.ui_rp.num_commands))

		gfx.cmd_end_rendering(cmd)
		gfx.cmd_end_label(cmd)
	}
}
