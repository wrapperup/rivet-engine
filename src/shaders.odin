package game

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import vk "vendor:vulkan"

import sp "deps:odin-slang/slang"

import "gfx"

ShaderManager :: struct {
	graphics_shaders: [dynamic]Shader(gfx.GraphicsPipeline),
	compute_shaders:  [dynamic]Shader(gfx.ComputePipeline),
}

// TODO: I want to use proper assets for this, so we can target spv in the release.
add_graphics_shader :: proc(
	path: cstring,
	pipeline_create_callback: proc(_: vk.ShaderModule) -> gfx.GraphicsPipeline,
) -> ^gfx.GraphicsPipeline {
	shader := init_shader(gfx.GraphicsPipeline, path, pipeline_create_callback)
	append(&game.render_state.shader_manager.graphics_shaders, shader)

	return shader.pipeline
}

add_compute_shader :: proc(
	path: cstring,
	pipeline_create_callback: proc(_: vk.ShaderModule) -> gfx.ComputePipeline,
) -> ^gfx.ComputePipeline {
	shader := init_shader(gfx.ComputePipeline, path, pipeline_create_callback)
	append(&game.render_state.shader_manager.compute_shaders, shader)

	return shader.pipeline
}

check_shader_hotreload :: proc() -> (needs_reload: bool) {
	// Polling every file's mtime every frame is hundreds of filesystem syscalls
	// (each shader + all its transitive imports). Throttle to a few times a second
	// so it doesn't dominate the frame; 250ms reload latency is imperceptible.
	@(static) last_check: time.Time
	now := time.now()
	if time.duration_seconds(time.diff(last_check, now)) < 0.25 {
		return false
	}
	last_check = now

	for &shader in game.render_state.shader_manager.graphics_shaders {
		max_last_write_time: i64
		last_write_time, _ := os.last_write_time_by_name(string(shader.path))
		max_last_write_time = last_write_time._nsec

		for path in shader.extra_files {
			last, _ := os.last_write_time_by_name(string(path))
			if last._nsec > max_last_write_time {
				max_last_write_time = last._nsec
			}
		}

		if shader.last_compile_time._nsec < max_last_write_time {
			shader.needs_recompile = true
			needs_reload = true
		}
	}

	for &shader in game.render_state.shader_manager.compute_shaders {
		max_last_write_time: i64
		last_write_time, _ := os.last_write_time_by_name(string(shader.path))
		max_last_write_time = last_write_time._nsec

		for path in shader.extra_files {
			last, _ := os.last_write_time_by_name(string(path))
			if last._nsec > max_last_write_time {
				max_last_write_time = last._nsec
			}
		}

		if shader.last_compile_time._nsec < max_last_write_time {
			shader.needs_recompile = true
			needs_reload = true
		}
	}

	return
}

hotreload_modified_shaders :: proc() -> bool {
	// TODO: SPEED: Maybe iter this across frames?
	for &shader in game.render_state.shader_manager.graphics_shaders {
		if shader.needs_recompile {
			ok := reload_shader_pipeline(&shader)

			shader.last_compile_time = time.now()
			shader.needs_recompile = false
			return ok
		}
	}

	for &shader in game.render_state.shader_manager.compute_shaders {
		if shader.needs_recompile {
			ok := reload_shader_pipeline(&shader)

			shader.last_compile_time = time.now()
			shader.needs_recompile = false
			return ok
		}
	}

	return false
}

// ================================================

Shader :: struct($T: typeid) {
	pipeline:                 ^T,
	path:                     cstring,
	extra_files:              []string,
	last_compile_time:        time.Time,
	needs_recompile:          bool,
	pipeline_create_callback: proc(_: vk.ShaderModule) -> T,
}

init_shader :: proc($T: typeid, path: cstring, pipeline_create_callback: proc(_: vk.ShaderModule) -> T) -> Shader(T) {
	assert(os.exists(string(path)))

	extra_files := get_dependency_file_paths(path)

	shader := Shader(T) {
		path                     = path,
		extra_files              = extra_files,
		last_compile_time        = time.now(),
		pipeline_create_callback = pipeline_create_callback,
	}

	// Load shader on demand.
	// TODO: Since this is at startup, we'll assert... for now
	assert(reload_shader_pipeline(&shader))

	return shader
}

get_cached_shader_path :: proc(path: string, allocator: runtime.Allocator) -> string {
	return filepath.join({"shaders", ".cache", filepath.base(path)}, allocator) or_else ""
}

get_last_write_time :: proc(shader: ^Shader($T)) -> time.Time {
	max_last_write_time: i64
	last_write_time, _ := os.last_write_time_by_name(string(shader.path))
	max_last_write_time = last_write_time._nsec

	for path in shader.extra_files {
		last, _ := os.last_write_time_by_name(string(path))
		if last._nsec > max_last_write_time {
			max_last_write_time = last._nsec
		}
	}

	return time.Time{max_last_write_time}
}

reload_shader_pipeline :: proc(shader: ^Shader($T)) -> bool {
	cached_path := get_cached_shader_path(string(shader.path), context.temp_allocator)

	use_cached_spirv := false

	if os.exists(cached_path) {
		shader_last_time := get_last_write_time(shader)
		cache_time, time_ok := os.last_write_time_by_name(cached_path)
		assert(time_ok == nil, "This shouldn't be hit...?")

		if shader_last_time._nsec < cache_time._nsec {
			use_cached_spirv = true
		}
	}

	use_cached_spirv = false

	code: []u8

	if use_cached_spirv {
		spirv_code, err := os.read_entire_file_from_path(string(cached_path), context.allocator)
		if err != nil {
			return false
		}

		code = spirv_code
	} else {
		code = compile_slang_to_spirv(shader) or_return
		err := os.write_entire_file(string(cached_path), code)
		if err != nil {
			log.warn("Warning: Shader couldn't be cached.", err, cached_path)
		}
	}

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

compile_slang_to_spirv :: proc(shader: ^Shader($T)) -> (compiled_code: []u8, ok: bool) {
	diagnostics: ^sp.IBlob
	r: sp.Result

	session := init_slang_session()
	defer safe_release(session)

	module: ^sp.IModule = session->loadModule(shader.path, &diagnostics)
	diagnostics_check(diagnostics)
	if module == nil {
		log.error("Shader", shader.path, "doesn't exist.")
		return
	}

	components: [dynamic]^sp.IComponentType
	defer delete(components)

	append(&components, module)

	linked_program: ^sp.IComponentType
	r = session->createCompositeComponentType(&components[0], len(components), &linked_program, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	target_code: ^sp.IBlob
	r = linked_program->getTargetCode(0, &target_code, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	code_size := target_code->getBufferSize()
	source_code := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	assert(code_size % 4 == 0)

	compiled_code = slice.clone(source_code)
	ok = true

	return
}
