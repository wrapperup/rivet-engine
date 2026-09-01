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
	$T: typeid,
	stage_flags: vk.ShaderStageFlags = {.VERTEX, .FRAGMENT},
	loc := #caller_location,
) -> (
	pipeline_layout: vk.PipelineLayout,
) {
	buffer_range := vk.PushConstantRange {
		offset     = 0,
		size       = size_of(T),
		stageFlags = stage_flags,
	}

	pipeline_layout_info := init_pipeline_layout_create_info()
	pipeline_layout_info.pPushConstantRanges = &buffer_range
	pipeline_layout_info.pushConstantRangeCount = 1
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
}

GraphicsPipeline :: struct {
	using common: Pipeline,
}

PipelineBlendMode :: enum {
	None,
	Additive,
	Alpha,
}

create_graphics_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	input_topology: vk.PrimitiveTopology,
	polygon_mode: vk.PolygonMode,
	front_face: vk.FrontFace,
	$push_constants: typeid,
	depth: struct {
		write_enabled: b32,
		compare_op:    vk.CompareOp,
		format:        vk.Format,
	} = {},
	cull_mode: vk.CullModeFlags = {},
	depth_clamp: bool = false,
	blend_mode: PipelineBlendMode = .None,
	multisampling_samples: vk.SampleCountFlag = ._1,
	color_format: vk.Format = .UNDEFINED,
	vertex_entry: cstring = DEFAULT_VERTEX_ENTRY,
	fragment_entry: cstring = DEFAULT_FRAGMENT_ENTRY,
	loc := #caller_location,
) -> GraphicsPipeline {
	pipeline_layout: vk.PipelineLayout
	pipeline: vk.Pipeline

	{
		pipeline_layout = _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants, loc = loc)
	}

	{
		pipeline_builder := pb_init()
		defer pb_delete(pipeline_builder)

		pipeline_builder.pipeline_layout = pipeline_layout
		pb_set_shaders(&pipeline_builder, shader, vertex_entry, fragment_entry)
		pb_set_input_topology(&pipeline_builder, input_topology)
		pb_set_polygon_mode(&pipeline_builder, polygon_mode)
		pb_set_cull_mode(&pipeline_builder, cull_mode, front_face)
		if depth_clamp {
			pb_enable_depth_clamp(&pipeline_builder)
		}
		pb_set_multisampling(&pipeline_builder, multisampling_samples)

		switch blend_mode {
		case .None:
			pb_disable_blending(&pipeline_builder)
		case .Additive:
			pb_enable_blending_additive(&pipeline_builder)
		case .Alpha:
			pb_enable_blending_alphablend(&pipeline_builder)
		}

		pb_enable_depthtest(&pipeline_builder, depth.write_enabled, depth.compare_op)
		pb_set_depth_format(&pipeline_builder, depth.format)

		if color_format == .UNDEFINED {
			pb_disable_color_attachment(&pipeline_builder)
		} else {
			pb_set_color_attachment_format(&pipeline_builder, color_format)
		}

		pipeline = pb_build_pipeline(&pipeline_builder)

		debug_set_object_name(pipeline, name)
	}

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = {.VERTEX, .FRAGMENT}}
}

ComputePipeline :: struct {
	using common: Pipeline,
}

create_compute_pipeline :: proc(
	name: cstring,
	shader: vk.ShaderModule,
	$push_constants: typeid,
	entry: cstring = DEFAULT_COMPUTE_ENTRY,
	loc := #caller_location,
) -> ComputePipeline {
	pipeline_layout := _create_pipeline_layout(name, &r_ctx.bindless_system.descriptor_layout, push_constants, {.COMPUTE}, loc = loc)

	stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = shader,
		pName  = entry,
	}

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = pipeline_layout,
		stage  = stage_info,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(r_ctx.device, 0, 1, &compute_pipeline_create_info, nil, &pipeline), loc)

	debug_set_object_name(pipeline, name)

	return {layout = pipeline_layout, pipeline = pipeline, stage_flags = {.COMPUTE}}
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
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = shader,
            pName = vertex_entry,
        }
		append(&builder.shader_stages, info)
	}

	if fragment_entry != nil {
        info := vk.PipelineShaderStageCreateInfo {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = shader,
            pName = fragment_entry,
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
