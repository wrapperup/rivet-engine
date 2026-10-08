package gfx

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"

import vk "vendor:vulkan"

DEFAULT_VERTEX_ENTRY: cstring : "vertex_main"
DEFAULT_FRAGMENT_ENTRY: cstring : "fragment_main"
DEFAULT_COMPUTE_ENTRY: cstring : "compute_main"

_create_pipeline_layout :: proc(
	debug_name: cstring,
	descriptor_set_layout: ^vk.DescriptorSetLayout,
	push_constants_size: u32,
	stage_flags: vk.ShaderStageFlags = {.VERTEX, .FRAGMENT},
	loc := #caller_location,
) -> (
	pipeline_layout: vk.PipelineLayout,
) {
	buffer_range := vk.PushConstantRange {
		offset     = 0,
		size       = push_constants_size,
		stageFlags = stage_flags,
	}

	pipeline_layout_info := init_pipeline_layout_create_info()
	if push_constants_size > 0 {
		pipeline_layout_info.pPushConstantRanges = &buffer_range
		pipeline_layout_info.pushConstantRangeCount = 1
	}
	pipeline_layout_info.pSetLayouts = descriptor_set_layout
	pipeline_layout_info.setLayoutCount = descriptor_set_layout != nil ? 1 : 0

	vk_check(vk.CreatePipelineLayout(r_ctx.device, &pipeline_layout_info, nil, &pipeline_layout))

	when ODIN_DEBUG {
		if debug_name == nil {
			debug_set_object_name(pipeline_layout, fmt.ctprint(loc))
		} else {
			debug_set_object_name(pipeline_layout, debug_name)
		}
	}

	return
}

Pipeline :: struct {
	layout:      vk.PipelineLayout,
	pipeline:    vk.Pipeline,
	stage_flags: vk.ShaderStageFlags,
	bind_point:  vk.PipelineBindPoint,
}

PipelineBlendMode :: enum {
	None,
	Additive,
	Alpha,
}

Topology :: enum u8 {
	Triangle_List,
	Triangle_Strip,
	Line_List,
}

Depth_State :: struct {
	format:        vk.Format,
	compare_op:    vk.CompareOp,
	write_enabled: b32,
}

Graphics_Pipeline_Desc :: struct {
	topology:       Topology,
	polygon_mode:   vk.PolygonMode,
	front_face:     vk.FrontFace,
	cull_mode:      vk.CullModeFlags,
	depth:          Depth_State,
	depth_clamp:    bool,
	blend_mode:     PipelineBlendMode,
	color_format:   vk.Format,
	msaa:           bool,
	depth_only:     bool,
	vertex_entry:   cstring,
	fragment_entry: cstring,
}

Compute_Pipeline_Desc :: struct {
	entry: cstring,
}

Pipeline_Desc :: union {
	Graphics_Pipeline_Desc,
	Compute_Pipeline_Desc,
}

create_graphics_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	$push_constants: typeid,
	desc: Graphics_Pipeline_Desc = {},
	loc := #caller_location,
) -> Pipeline {
	return create_pipeline_from_desc(name, shader, desc, size_of(push_constants), loc)
}

create_compute_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	$push_constants: typeid,
	entry: cstring = nil,
	loc := #caller_location,
) -> Pipeline {
	return create_pipeline_from_desc(name, shader, Compute_Pipeline_Desc{entry = entry}, size_of(push_constants), loc)
}

create_pipeline_from_desc :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
	switch d in desc {
	case Graphics_Pipeline_Desc:
		return _create_graphics_pipeline(name, shader, d, push_constants_size, loc)
	case Compute_Pipeline_Desc:
		return _create_compute_pipeline(name, shader, d, push_constants_size, loc)
	}
	panic("Empty pipeline desc", loc)
}

destroy_pipeline :: proc(pipeline: Pipeline) {
	if pipeline.pipeline != 0 {
		vk.DestroyPipeline(r_ctx.device, pipeline.pipeline, nil)
	}
	if pipeline.layout != 0 {
		vk.DestroyPipelineLayout(r_ctx.device, pipeline.layout, nil)
	}
}

_create_graphics_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Graphics_Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
	stage_flags := vk.ShaderStageFlags{.VERTEX, .FRAGMENT}
	pipeline_layout := _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants_size, stage_flags, loc = loc)

	pipeline_builder := pb_init()
	defer pb_delete(pipeline_builder)

	vertex_entry := desc.vertex_entry != nil ? desc.vertex_entry : DEFAULT_VERTEX_ENTRY
	fragment_entry := desc.fragment_entry != nil ? desc.fragment_entry : DEFAULT_FRAGMENT_ENTRY
	if desc.depth_only {
		fragment_entry = nil
	}

	topology: vk.PrimitiveTopology
	switch desc.topology {
	case .Triangle_List:
		topology = .TRIANGLE_LIST
	case .Triangle_Strip:
		topology = .TRIANGLE_STRIP
	case .Line_List:
		topology = .LINE_LIST
	}

	pipeline_builder.pipeline_layout = pipeline_layout
	pb_set_shaders(&pipeline_builder, shader, vertex_entry, fragment_entry)
	pb_set_input_topology(&pipeline_builder, topology)
	pb_set_polygon_mode(&pipeline_builder, desc.polygon_mode)
	pb_set_cull_mode(&pipeline_builder, desc.cull_mode, desc.front_face)
	if desc.depth_clamp {
		pb_enable_depth_clamp(&pipeline_builder)
	}
	pb_set_multisampling(&pipeline_builder, desc.msaa ? msaa_samples() : ._1)

	switch desc.blend_mode {
	case .None:
		pb_disable_blending(&pipeline_builder)
	case .Additive:
		pb_enable_blending_additive(&pipeline_builder)
	case .Alpha:
		pb_enable_blending_alphablend(&pipeline_builder)
	}

	if desc.depth.format == .UNDEFINED {
		pb_disable_depthtest(&pipeline_builder)
	} else {
		pb_enable_depthtest(&pipeline_builder, desc.depth.write_enabled, desc.depth.compare_op)
	}
	pb_set_depth_format(&pipeline_builder, desc.depth.format)

	if desc.color_format == .UNDEFINED {
		pb_disable_color_attachment(&pipeline_builder)
	} else {
		pb_set_color_attachment_format(&pipeline_builder, desc.color_format)
	}

	pipeline := pb_build_pipeline(&pipeline_builder)
	debug_set_object_name(pipeline, name)

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = stage_flags, bind_point = .GRAPHICS}
}

_create_compute_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	desc: Compute_Pipeline_Desc,
	push_constants_size: u32,
	loc := #caller_location,
) -> Pipeline {
	pipeline_layout := _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants_size, {.COMPUTE}, loc = loc)

	stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = shader,
		pName  = desc.entry != nil ? desc.entry : DEFAULT_COMPUTE_ENTRY,
	}

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = pipeline_layout,
		stage  = stage_info,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(r_ctx.device, 0, 1, &compute_pipeline_create_info, nil, &pipeline), loc)

	debug_set_object_name(pipeline, name)

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = {.COMPUTE}, bind_point = .COMPUTE}
}

// ====================================================================

load_shader_module :: proc(file_name: string, allocator: runtime.Allocator) -> (vk.ShaderModule, bool) {
	buffer, err := os.read_entire_file(file_name, allocator)

	if err != nil {
		return 0, false
	}

	defer delete(buffer, allocator)

	return load_shader_module_from_bytes(buffer)
}

load_shader_module_from_bytes :: proc(bytes: []u8) -> (vk.ShaderModule, bool) {
	// Byte length needs to be a multiple of 4
	if len(bytes) % 4 != 0 {
		return 0, false
	}

	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytes), // codeSize needs to be in bytes
		pCode    = raw_data(slice.reinterpret([]u32, bytes)), // code needs to be in 32bit words
	}

	module: vk.ShaderModule
	if vk.CreateShaderModule(r_ctx.device, &info, nil, &module) != .SUCCESS {
		return 0, false
	}

	return module, true
}

destroy_shader_module :: proc(module: vk.ShaderModule) {
	vk.DestroyShaderModule(r_ctx.device, module, nil)
}

// ====================================================================

PipelineBuilder :: struct {
	shader_stages:           [dynamic]vk.PipelineShaderStageCreateInfo,
	input_assembly:          vk.PipelineInputAssemblyStateCreateInfo,
	rasterizer:              vk.PipelineRasterizationStateCreateInfo,
	color_blend_attachment:  vk.PipelineColorBlendAttachmentState,
	multisampling:           vk.PipelineMultisampleStateCreateInfo,
	pipeline_layout:         vk.PipelineLayout,
	depth_stencil:           vk.PipelineDepthStencilStateCreateInfo,
	render_info:             vk.PipelineRenderingCreateInfo,
	color_attachment_format: vk.Format,
}

// This allocates, be sure to call pb_delete.
pb_init :: proc() -> PipelineBuilder {
	pb: PipelineBuilder
	pb_clear(&pb)
	return pb
}

pb_clear :: proc(builder: ^PipelineBuilder) {
	builder.input_assembly = {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	}
	builder.rasterizer = {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	}
	builder.color_blend_attachment = {}
	builder.multisampling = {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	}
	builder.pipeline_layout = {}
	builder.depth_stencil = {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}
	builder.render_info = {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
	}
	builder.color_attachment_format = {}

	clear(&builder.shader_stages)
}

pb_set_shaders :: proc(
	builder: ^PipelineBuilder,
	shader: vk.ShaderModule,
	vertex_entry: cstring = DEFAULT_VERTEX_ENTRY,
	fragment_entry: cstring = DEFAULT_FRAGMENT_ENTRY,
) {
	clear(&builder.shader_stages)
	if vertex_entry != nil {
		info := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = shader,
			pName  = vertex_entry,
		}
		append(&builder.shader_stages, info)
	}

	if fragment_entry != nil {
		info := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = shader,
			pName  = fragment_entry,
		}
		append(&builder.shader_stages, info)
	}
}

pb_set_input_topology :: proc(builder: ^PipelineBuilder, topology: vk.PrimitiveTopology) {
	builder.input_assembly.topology = topology
	builder.input_assembly.primitiveRestartEnable = false
}

pb_set_polygon_mode :: proc(builder: ^PipelineBuilder, mode: vk.PolygonMode) {
	builder.rasterizer.polygonMode = mode
	builder.rasterizer.lineWidth = 1.
}

pb_set_cull_mode :: proc(builder: ^PipelineBuilder, cull_mode: vk.CullModeFlags, front_face: vk.FrontFace) {
	builder.rasterizer.cullMode = cull_mode
	builder.rasterizer.frontFace = front_face
}

pb_enable_depth_clamp :: proc(builder: ^PipelineBuilder) {
	builder.rasterizer.depthClampEnable = true
}

pb_set_multisampling_none :: proc(builder: ^PipelineBuilder) {
	builder.multisampling.sampleShadingEnable = false

	builder.multisampling.rasterizationSamples = {._1}
	builder.multisampling.minSampleShading = 1.0
	builder.multisampling.pSampleMask = nil

	builder.multisampling.alphaToCoverageEnable = false
	builder.multisampling.alphaToOneEnable = false
}

pb_set_multisampling :: proc(builder: ^PipelineBuilder, samples: vk.SampleCountFlag) {
	builder.multisampling.sampleShadingEnable = false

	builder.multisampling.rasterizationSamples = {samples}
	builder.multisampling.minSampleShading = 1.0
	builder.multisampling.pSampleMask = nil

	builder.multisampling.alphaToCoverageEnable = samples != ._1
	builder.multisampling.alphaToOneEnable = false
}

pb_disable_blending :: proc(builder: ^PipelineBuilder) {
	builder.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	builder.color_blend_attachment.blendEnable = false
}

pb_enable_blending_additive :: proc(builder: ^PipelineBuilder) {
	builder.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	builder.color_blend_attachment.blendEnable = true
	builder.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	builder.color_blend_attachment.dstColorBlendFactor = .ONE
	builder.color_blend_attachment.colorBlendOp = .ADD
	builder.color_blend_attachment.srcAlphaBlendFactor = .ONE
	builder.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	builder.color_blend_attachment.alphaBlendOp = .ADD
}

pb_enable_blending_alphablend :: proc(builder: ^PipelineBuilder) {
	builder.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	builder.color_blend_attachment.blendEnable = true
	builder.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	builder.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	builder.color_blend_attachment.colorBlendOp = .ADD
	builder.color_blend_attachment.srcAlphaBlendFactor = .ONE
	builder.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	builder.color_blend_attachment.alphaBlendOp = .ADD
}


pb_set_color_attachment_format :: proc(builder: ^PipelineBuilder, format: vk.Format) {
	builder.color_attachment_format = format

	builder.render_info.colorAttachmentCount = 1
	builder.render_info.pColorAttachmentFormats = &builder.color_attachment_format
}

pb_disable_color_attachment :: proc(builder: ^PipelineBuilder) {
	builder.color_attachment_format = .UNDEFINED

	builder.render_info.colorAttachmentCount = 0
	builder.render_info.pColorAttachmentFormats = nil
}

pb_set_depth_format :: proc(builder: ^PipelineBuilder, format: vk.Format) {
	builder.render_info.depthAttachmentFormat = format
}

pb_disable_depthtest :: proc(builder: ^PipelineBuilder) {
	builder.depth_stencil.depthTestEnable = false
	builder.depth_stencil.depthWriteEnable = false
	builder.depth_stencil.depthCompareOp = .NEVER
	builder.depth_stencil.depthBoundsTestEnable = false
	builder.depth_stencil.stencilTestEnable = false
	builder.depth_stencil.front = {}
	builder.depth_stencil.back = {}
	builder.depth_stencil.minDepthBounds = 0.0
	builder.depth_stencil.maxDepthBounds = 1.0
}

pb_enable_depthtest :: proc(builder: ^PipelineBuilder, depth_write_enable: b32, op: vk.CompareOp) {
	builder.depth_stencil.depthTestEnable = true
	builder.depth_stencil.depthWriteEnable = depth_write_enable
	builder.depth_stencil.depthCompareOp = op
	builder.depth_stencil.depthBoundsTestEnable = false
	builder.depth_stencil.stencilTestEnable = false
	builder.depth_stencil.front = {}
	builder.depth_stencil.back = {}
	builder.depth_stencil.minDepthBounds = 0.0
	builder.depth_stencil.maxDepthBounds = 1.0
}

pb_build_pipeline :: proc(builder: ^PipelineBuilder) -> vk.Pipeline {
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &builder.color_blend_attachment,
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	state := []vk.DynamicState{.VIEWPORT, .SCISSOR}

	dynamicInfo := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		pDynamicStates    = raw_data(state),
		dynamicStateCount = u32(len(state)),
	}


	pipelineInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &builder.render_info,
		pStages             = raw_data(builder.shader_stages),
		stageCount          = u32(len(builder.shader_stages)),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &builder.input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &builder.rasterizer,
		pMultisampleState   = &builder.multisampling,
		pColorBlendState    = &color_blending,
		pDepthStencilState  = &builder.depth_stencil,
		layout              = builder.pipeline_layout,
		pDynamicState       = &dynamicInfo,
	}

	newPipeline: vk.Pipeline
	if vk.CreateGraphicsPipelines(r_ctx.device, 0, 1, &pipelineInfo, nil, &newPipeline) != .SUCCESS {
		fmt.eprintln("Failed to create pipeline")
		return 0
	}

	return newPipeline
}

pb_delete :: proc(builder: PipelineBuilder) {
	delete(builder.shader_stages)
}
