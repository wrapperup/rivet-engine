package gfx

import vk "vendor:vulkan"

cmd_bind_graphics_pipeline :: #force_inline proc(cmd: CommandBuffer, pipeline: GraphicsPipeline) {
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, pipeline.layout, 0, 1, &r_ctx.bindless_system.descriptor_set, 0, nil)
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)

	r_ctx.current_pipeline = pipeline.common
}

cmd_bind_graphics_pipeline_ptr :: #force_inline proc(cmd: CommandBuffer, pipeline: ^GraphicsPipeline) {
	cmd_bind_graphics_pipeline(cmd, pipeline^)
}

cmd_bind_compute_pipeline :: #force_inline proc(cmd: CommandBuffer, pipeline: ComputePipeline) {
	vk.CmdBindDescriptorSets(cmd, .COMPUTE, pipeline.layout, 0, 1, &r_ctx.bindless_system.descriptor_set, 0, nil)
	vk.CmdBindPipeline(cmd, .COMPUTE, pipeline.pipeline)

	r_ctx.current_pipeline = pipeline.common
}

cmd_bind_compute_pipeline_ptr :: #force_inline proc(cmd: CommandBuffer, pipeline: ^ComputePipeline) {
	cmd_bind_compute_pipeline(cmd, pipeline^)
}

cmd_bind_pipeline :: proc {
	cmd_bind_graphics_pipeline,
	cmd_bind_graphics_pipeline_ptr,
	cmd_bind_compute_pipeline,
	cmd_bind_compute_pipeline_ptr,
}


cmd_push_constants :: #force_inline proc(cmd: CommandBuffer, push_constants: $T, offset: u32 = 0) {
	push_constants := push_constants
	vk.CmdPushConstants(cmd, r_ctx.current_pipeline.layout, r_ctx.current_pipeline.stage_flags, 0, size_of(T), &push_constants)
}

cmd_bind_index_buffer :: #force_inline proc(
	cmd: CommandBuffer,
	buffer: vk.Buffer,
	offset: vk.DeviceSize = 0,
	index_type: vk.IndexType = .UINT32,
) {
	vk.CmdBindIndexBuffer(cmd, buffer, offset, index_type)
}

cmd_draw :: #force_inline proc(
	cmd: CommandBuffer,
	vertex_count: u32,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDraw(cmd, vertex_count, instance_count, first_vertex, first_instance)
}

cmd_draw_indexed :: #force_inline proc(
	cmd: CommandBuffer,
	index_count: u32,
	instance_count: u32 = 1,
	first_index: u32 = 0,
	vertex_offset: i32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, first_instance)
}

RenderingAttachmentInfo :: struct {
	view:        vk.ImageView,
	clear_value: ^vk.ClearValue,
	layout:      vk.ImageLayout,
}

// TODO: this is stupid. there's no need for pointers at all for the clear value.
cmd_begin_rendering :: proc(
	cmd: CommandBuffer,
	area: vk.Extent2D,
	color_attachment: ^RenderingAttachmentInfo = nil,
	depth_attachment: ^RenderingAttachmentInfo = nil,
) {
	vk_color_attachment: vk.RenderingAttachmentInfo
	a_ok := false
	vk_depth_attachment: vk.RenderingAttachmentInfo
	b_ok := false

	if color_attachment != nil {
		vk_color_attachment = init_attachment_info(color_attachment.view, color_attachment.clear_value, color_attachment.layout)
		a_ok = true
	}

	if depth_attachment != nil {
		vk_depth_attachment = init_attachment_info(depth_attachment.view, depth_attachment.clear_value, depth_attachment.layout)
		b_ok = true
	}

	render_info := init_rendering_info(area, a_ok ? &vk_color_attachment : nil, b_ok ? &vk_depth_attachment : nil)
	vk.CmdBeginRendering(cmd, &render_info)
}

cmd_end_rendering :: #force_inline proc(cmd: CommandBuffer) {
	vk.CmdEndRendering(cmd)
}

cmd_dispatch :: #force_inline proc(cmd: CommandBuffer, group_count_x: u32 = 1, group_count_y: u32 = 1, group_count_z: u32 = 1) {
	vk.CmdDispatch(cmd, group_count_x, group_count_y, group_count_z)
}

cmd_begin_label :: proc(cmd: CommandBuffer, label: cstring, color: [4]f32 = 1) {
	vk_label := vk.DebugUtilsLabelEXT {
		sType      = .DEBUG_UTILS_LABEL_EXT,
		pLabelName = label,
		color      = color,
	}

	vk.CmdBeginDebugUtilsLabelEXT(cmd, &vk_label)
}

cmd_end_label :: #force_inline proc(cmd: CommandBuffer) {
    vk.CmdEndDebugUtilsLabelEXT(cmd)
}
