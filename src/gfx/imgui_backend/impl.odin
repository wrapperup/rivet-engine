package gfx_imgui

import "core:slice"

import im "deps:odin-imgui"
import vk "vendor:vulkan"

import gfx "../"

PushConstants :: struct #max_field_align(16) {
	vertex_buffer: gfx.Ptr(im.DrawVert),
	scale:         [2]f32,
	translate:     [2]f32,
	texture:       gfx.ImageId,
	sampler:       gfx.SamplerId,
}

GfxImgui :: struct {
	pipeline:      gfx.GraphicsPipeline,
	vbuffers:      [gfx.FRAME_OVERLAP]gfx.Buffer(im.DrawVert),
	ibuffers:      [gfx.FRAME_OVERLAP]gfx.Buffer(im.DrawIdx),
	vbuffer_sizes: [gfx.FRAME_OVERLAP]int,
	ibuffer_sizes: [gfx.FRAME_OVERLAP]int,
	font_image:    gfx.Image,
	font_sheet:    gfx.ImageId,
	font_sampler:  gfx.SamplerId,
}

INDEX_TYPE :: vk.IndexType.UINT16 when size_of(im.DrawIdx) == 2 else vk.IndexType.UINT32
IMGUI_SPV := #load("imgui.spv")

gfx_imgui_backend_data :: proc() -> ^GfxImgui {
	if im.GetCurrentContext() == nil do return nil
	return cast(^GfxImgui)im.GetIO().BackendRendererUserData
}

gfx_imgui_init :: proc() {
	io := im.GetIO()
	assert(io.BackendRendererUserData == nil, "imgui renderer backend already initialized")

	this := new(GfxImgui)
	io.BackendRendererUserData = this
	io.BackendRendererName = "imgui_impl_gfx"
	io.BackendFlags += {.RendererHasVtxOffset}

	sampler := gfx.create_sampler(.LINEAR, .CLAMP_TO_EDGE, max_lod = 10.0, max_anisotropy = gfx.r_ctx.limits.maxSamplerAnisotropy)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, sampler)
	this.font_sampler = gfx.add_sampler(sampler)

	shader_module, sm_ok := gfx.load_shader_module_from_bytes(IMGUI_SPV)
	assert(sm_ok, "Failed to create imgui shader module from embedded SPIR-V.")
	defer gfx.destroy_shader_module(shader_module)

	this.pipeline = gfx.create_graphics_pipeline(
		name = "Imgui_Pipeline",
		shader = shader_module,
		input_topology = .TRIANGLE_LIST,
		polygon_mode = .FILL,
		cull_mode = {},
		front_face = .COUNTER_CLOCKWISE,
		blend_mode = .Alpha,
		color_format = gfx.r_ctx.swapchain.swapchain_image_format,
		push_constants = PushConstants,
	)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, this.pipeline)
}

// Build (or rebuild) the font atlas texture as RGBA8 so any ImTextureID can
// target a regular bindless image without special-casing the font path.
gfx_imgui_create_fonts_texture :: proc(this: ^GfxImgui) {
	io := im.GetIO()

	pixels: ^u8
	fw, fh: i32
	im.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &fw, &fh)
	atlas_bytes := int(fw) * int(fh) * 4

	this.font_image = gfx.create_image(.R8G8B8A8_UNORM, {u32(fw), u32(fh), 1}, {.SAMPLED, .TRANSFER_DST}, debug_name = "imgui_font_atlas")
    // TODO: Make an arena just for imgui?
	gfx.defer_destroy(&gfx.r_ctx.global_arena, this.font_image)

	{
		staging := gfx.create_buffer(u8, atlas_bytes, .Staging, name = "imgui_font_staging")
		defer gfx.destroy_buffer(&staging)

		gfx.write_buffer_slice(&staging, slice.from_ptr(pixels, atlas_bytes))

		if cmd, ok := gfx.immediate_submit(); ok {
			gfx.transition_image(cmd, &this.font_image, .TRANSFER_DST_OPTIMAL)

			region := vk.BufferImageCopy {
				imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
				imageExtent = {u32(fw), u32(fh), 1},
			}
			vk.CmdCopyBufferToImage(cmd, staging.buffer, this.font_image.image, .TRANSFER_DST_OPTIMAL, 1, &region)

			gfx.transition_image(cmd, &this.font_image, .SHADER_READ_ONLY_OPTIMAL)
		}
	}

	this.font_sheet = gfx.add_image(this.font_image)
	im.FontAtlas_SetTexID(io.Fonts, transmute(im.TextureID)uintptr(this.font_sheet))
}

gfx_imgui_new_frame :: proc() {
	this := gfx_imgui_backend_data()
	assert(this != nil, "Imgui renderer backend not initialized! Call gfx_imgui_init first.")

	io := im.GetIO()
	if !im.FontAtlas_IsBuilt(io.Fonts) {
		gfx_imgui_create_fonts_texture(this)
	}
}

gfx_imgui_destroy :: proc() {
	this := gfx_imgui_backend_data()
	if this == nil do return

	for &b in this.vbuffers {
		if b.buffer != 0 do gfx.destroy_buffer(&b)
	}
	for &b in this.ibuffers {
		if b.buffer != 0 do gfx.destroy_buffer(&b)
	}

	io := im.GetIO()
	io.BackendRendererName = nil
	io.BackendRendererUserData = nil
	io.BackendFlags -= {.RendererHasVtxOffset}
	free(this)
}

gfx_imgui_render :: proc(cmd: vk.CommandBuffer, target_view: vk.ImageView, target_extent: vk.Extent2D) {
	this := gfx_imgui_backend_data()
	assert(this != nil, "Imgui renderer backend not initialized! Call gfx_imgui_init first.")

	draw_data := im.GetDrawData()
	if draw_data == nil || !draw_data.Valid do return

	total_verts := int(draw_data.TotalVtxCount)
	total_indices := int(draw_data.TotalIdxCount)
	if total_verts == 0 || total_indices == 0 do return

	fb_w := i32(draw_data.DisplaySize.x * draw_data.FramebufferScale.x)
	fb_h := i32(draw_data.DisplaySize.y * draw_data.FramebufferScale.y)
	if fb_w <= 0 || fb_h <= 0 do return

	frame := gfx.current_frame_index()

	if this.vbuffer_sizes[frame] != total_verts {
		if this.vbuffer_sizes[frame] != 0 {
			gfx.defer_destroy_buffer(&gfx.current_frame().arena, this.vbuffers[frame])
		}
		this.vbuffers[frame] = gfx.create_buffer(im.DrawVert, total_verts, .Storage, name = "imgui_vbuf")
		this.vbuffer_sizes[frame] = total_verts
	}
	if this.ibuffer_sizes[frame] != total_indices {
		if this.ibuffer_sizes[frame] != 0 {
			gfx.defer_destroy_buffer(&gfx.current_frame().arena, this.ibuffers[frame])
		}
		this.ibuffers[frame] = gfx.create_buffer(im.DrawIdx, total_indices, .Index, name = "imgui_ibuf")
		this.ibuffer_sizes[frame] = total_indices
	}

	vertices := make([]im.DrawVert, total_verts, context.temp_allocator)
	indices := make([]im.DrawIdx, total_indices, context.temp_allocator)

	cmd_lists := slice.from_ptr(draw_data.CmdLists.Data, int(draw_data.CmdLists.Size))
	{
        vertices_off: int
        indices_off: int
		for list in cmd_lists {
			vert_buf_size := int(list.VtxBuffer.Size)
			idx_buf_size := int(list.IdxBuffer.Size)
			copy(vertices[vertices_off:][:vert_buf_size], slice.from_ptr(list.VtxBuffer.Data, vert_buf_size))
			copy(indices[indices_off:][:idx_buf_size], slice.from_ptr(list.IdxBuffer.Data, idx_buf_size))
			vertices_off += vert_buf_size
			indices_off += idx_buf_size
		}
	}

	gfx.staging_write_buffer_slice(&this.vbuffers[frame], vertices)
	gfx.staging_write_buffer_slice(&this.ibuffers[frame], indices)

	color_attachment := gfx.RenderingAttachmentInfo {
		view   = target_view,
		layout = .COLOR_ATTACHMENT_OPTIMAL,
	}
	gfx.cmd_begin_rendering(cmd, target_extent, &color_attachment, nil)
	defer gfx.cmd_end_rendering(cmd)

	viewport := vk.Viewport {
		width    = f32(target_extent.width),
		height   = f32(target_extent.height),
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	gfx.cmd_bind_pipeline(cmd, this.pipeline)
	gfx.cmd_bind_index_buffer(cmd, this.ibuffers[frame].buffer, 0, INDEX_TYPE)

	scale := [2]f32{2.0 / draw_data.DisplaySize.x, 2.0 / draw_data.DisplaySize.y}
	translate := [2]f32{-1.0 - draw_data.DisplayPos.x * scale.x, -1.0 - draw_data.DisplayPos.y * scale.y}

	clip_off := draw_data.DisplayPos
	clip_scale := draw_data.FramebufferScale

	global_vtx_offset: i32 = 0
	global_idx_offset: u32 = 0
	for list in cmd_lists {
		draw_cmds := slice.from_ptr(list.CmdBuffer.Data, int(list.CmdBuffer.Size))
		for &dc in draw_cmds {
			if dc.UserCallback != nil {
				dc.UserCallback(list, &dc)
				continue
			}
			if dc.ElemCount == 0 do continue

			clip_min := [2]f32{(dc.ClipRect.x - clip_off.x) * clip_scale.x, (dc.ClipRect.y - clip_off.y) * clip_scale.y}
			clip_max := [2]f32{(dc.ClipRect.z - clip_off.x) * clip_scale.x, (dc.ClipRect.w - clip_off.y) * clip_scale.y}
			clip_min.x = max(clip_min.x, 0)
			clip_min.y = max(clip_min.y, 0)
			clip_max.x = min(clip_max.x, f32(fb_w))
			clip_max.y = min(clip_max.y, f32(fb_h))
			if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y do continue

			scissor := vk.Rect2D {
				offset = {i32(clip_min.x), i32(clip_min.y)},
				extent = {u32(clip_max.x - clip_min.x), u32(clip_max.y - clip_min.y)},
			}
			vk.CmdSetScissor(cmd, 0, 1, &scissor)

			base_vertex := vk.DeviceAddress(global_vtx_offset + i32(dc.VtxOffset))
			vbuf := this.vbuffers[frame].ptr
			vbuf.address += base_vertex * size_of(im.DrawVert)

			gfx.cmd_push_constants(
				cmd,
				PushConstants {
					vertex_buffer = vbuf,
					scale = scale,
					translate = translate,
					texture = gfx.ImageId(uintptr(dc.TextureId)),
					sampler = this.font_sampler,
				},
			)

			gfx.cmd_draw_indexed(
				cmd,
				index_count = dc.ElemCount,
				instance_count = 1,
				first_index = dc.IdxOffset + global_idx_offset,
				vertex_offset = 0,
			)
		}
		global_idx_offset += u32(list.IdxBuffer.Size)
		global_vtx_offset += list.VtxBuffer.Size
	}
}
