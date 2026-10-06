package game

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import vk "vendor:vulkan"

import sp "deps:odin-slang/slang"

import "gfx"

ShaderManager :: struct {
	graphics_shaders: [dynamic]Shader(gfx.GraphicsPipeline),
	compute_shaders:  [dynamic]Shader(gfx.ComputePipeline),
}

add_graphics_shader :: proc(
	asset: Handle(Shader_Asset),
	pipeline_create_callback: proc(_: vk.ShaderModule) -> gfx.GraphicsPipeline,
) -> ^gfx.GraphicsPipeline {
	shader := init_shader(gfx.GraphicsPipeline, asset, pipeline_create_callback)
	append(&game.render_state.shader_manager.graphics_shaders, shader)

	return shader.pipeline
}

add_compute_shader :: proc(
	asset: Handle(Shader_Asset),
	pipeline_create_callback: proc(_: vk.ShaderModule) -> gfx.ComputePipeline,
) -> ^gfx.ComputePipeline {
	shader := init_shader(gfx.ComputePipeline, asset, pipeline_create_callback)
	append(&game.render_state.shader_manager.compute_shaders, shader)

	return shader.pipeline
}

// ================================================

Shader :: struct($T: typeid) {
	pipeline:                 ^T,
	asset:                    Handle(Shader_Asset),
	pipeline_create_callback: proc(_: vk.ShaderModule) -> T,
}

init_shader :: proc($T: typeid, asset: Handle(Shader_Asset), pipeline_create_callback: proc(_: vk.ShaderModule) -> T) -> Shader(T) {
	shader := Shader(T) {
		asset                    = asset,
		pipeline_create_callback = pipeline_create_callback,
	}

	assert(load_shader_pipeline(&shader))

	return shader
}

load_shader_pipeline :: proc(shader: ^Shader($T)) -> bool {
	code := load_asset(shader.asset).spirv_bytes

	shader_module, f_ok := gfx.load_shader_module_from_bytes(code)
	assert(f_ok, "Failed to load shaders.")

	pipeline := shader.pipeline_create_callback(shader_module)

	assert(pipeline.pipeline != 0)

	if shader.pipeline != nil {
		if shader.pipeline.pipeline != 0 {
			vk.DestroyPipeline(gfx.r_ctx.device, shader.pipeline.pipeline, nil)
		}
		// Destroy the old layout too, or each hotreload leaks one (which validation
		// then has to report at shutdown -> slow close after many reloads).
		if shader.pipeline.layout != 0 {
			vk.DestroyPipelineLayout(gfx.r_ctx.device, shader.pipeline.layout, nil)
		}
		// Update in place: pointers handed out by add_*_shader (e.g. the
		// render_state.*_pipeline fields) alias this allocation, so it must NOT move.
		shader.pipeline^ = pipeline
	} else {
		shader.pipeline = new(T)
		shader.pipeline^ = pipeline
	}

	gfx.destroy_shader_module(shader_module)

	return true
}

slang_check :: #force_inline proc(#any_int result: int, loc := #caller_location) {
	// result := -sp.Result(result)
	// if sp.FAILED(result) {
	// 	code := sp.GET_RESULT_CODE(result)
	// 	facility := sp.GET_RESULT_FACILITY(result)
	// 	estr: string
	// 	switch sp.Result(result) {
	// 	case:
	// 		estr = "Unknown error"
	// 	case sp.E_NOT_IMPLEMENTED():
	// 		estr = "E_NOT_IMPLEMENTED"
	// 	case sp.E_NO_INTERFACE():
	// 		estr = "E_NO_INTERFACE"
	// 	case sp.E_ABORT():
	// 		estr = "E_ABORT"
	// 	case sp.E_INVALID_HANDLE():
	// 		estr = "E_INVALID_HANDLE"
	// 	case sp.E_INVALID_ARG():
	// 		estr = "E_INVALID_ARG"
	// 	case sp.E_OUT_OF_MEMORY():
	// 		estr = "E_OUT_OF_MEMORY"
	// 	case sp.E_BUFFER_TOO_SMALL():
	// 		estr = "E_BUFFER_TOO_SMALL"
	// 	case sp.E_UNINITIALIZED():
	// 		estr = "E_UNINITIALIZED"
	// 	case sp.E_PENDING():
	// 		estr = "E_PENDING"
	// 	case sp.E_CANNOT_OPEN():
	// 		estr = "E_CANNOT_OPEN"
	// 	case sp.E_NOT_FOUND():
	// 		estr = "E_NOT_FOUND"
	// 	case sp.E_INTERNAL_FAIL():
	// 		estr = "E_INTERNAL_FAIL"
	// 	case sp.E_NOT_AVAILABLE():
	// 		estr = "E_NOT_AVAILABLE"
	// 	case sp.E_TIME_OUT():
	// 		estr = "E_TIME_OUT"
	// 	}
	//
	// 	fmt.panicf("Failed with error: %v (%v) Facility: %v", estr, code, facility, loc = loc)
	// }
}

diagnostics_check :: #force_inline proc(diagnostics: ^sp.IBlob, loc := #caller_location) {
	if diagnostics != nil {
		buffer := slice.bytes_from_ptr(diagnostics->getBufferPointer(), int(diagnostics->getBufferSize()))
		fmt.eprintln(string(buffer), loc)
	}
}

init_slang_session :: proc() -> ^sp.ISession {
	options: []sp.CompilerOptionEntry = {
		{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
		{name = .GLSLForceScalarLayout, value = {kind = .Int, intValue0 = 1}},
		// {name = .Optimization, value = {kind = .Int, intValue0 = 3}},
	}

	target_desc := sp.TargetDesc {
		structureSize               = size_of(sp.TargetDesc),
		format                      = .SPIRV,
		flags                       = {.GENERATE_SPIRV_DIRECTLY},
		profile                     = game.render_state.global_session->findProfile("sm_6_5"),
		forceGLSLScalarBufferLayout = true,
		compilerOptionEntries       = &options[0],
		compilerOptionEntryCount    = u32(len(options)),
	}

	session_desc := sp.SessionDesc {
		structureSize            = size_of(sp.SessionDesc),
		targets                  = &target_desc,
		targetCount              = 1,
		defaultMatrixLayoutMode  = .COLUMN_MAJOR,
		compilerOptionEntries    = &options[0],
		compilerOptionEntryCount = u32(len(options)),
	}

	session: ^sp.ISession
	global_session := game.render_state.global_session
	slang_check(game.render_state.global_session->createSession(session_desc, &session))
	return session
}

safe_release :: proc(unknown: ^sp.IUnknown) {
	if unknown != nil {
		unknown->release()
	}
}

shutdown_shader :: proc(shader: ^Shader($T)) {
	if shader.pipeline != nil {
		if shader.pipeline.pipeline != 0 {
			vk.DestroyPipeline(gfx.r_ctx.device, shader.pipeline.pipeline, nil)
		}
		if shader.pipeline.layout != 0 {
			vk.DestroyPipelineLayout(gfx.r_ctx.device, shader.pipeline.layout, nil)
		}
		free(shader.pipeline)
	}
	release_asset(shader.asset)
	shader^ = {}
}

shutdown_shader_manager :: proc() {
	for &shader in game.render_state.shader_manager.graphics_shaders {
		shutdown_shader(&shader)
	}
	for &shader in game.render_state.shader_manager.compute_shaders {
		shutdown_shader(&shader)
	}
	delete(game.render_state.shader_manager.graphics_shaders)
	delete(game.render_state.shader_manager.compute_shaders)
	game.render_state.shader_manager = {}

	if game.render_state.global_session != nil {
		safe_release(game.render_state.global_session)
		game.render_state.global_session = nil
	}
}

get_dependency_file_paths :: proc(root_path: cstring, allocator := context.allocator) -> []string {
	session := init_slang_session()
	defer safe_release(session)

	diagnostics: ^sp.IBlob
	module: ^sp.IModule = session->loadModule(root_path, &diagnostics)
	diagnostics_check(diagnostics)
	assert(module != nil)

	count := module->getDependencyFileCount()

	file_paths := make([]string, count)

	for i in 0 ..< module->getDependencyFileCount() {
		str := module->getDependencyFilePath(i)
		file_paths[i] = strings.clone_from_cstring(str)
	}

	return file_paths
}
