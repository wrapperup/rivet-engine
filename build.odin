package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import build_meta "meta"

BUILD_TOOL_EXECUTABLE         :: "build/build.exe"
BUILD_TOOL_PENDING_EXECUTABLE :: "build/build.next.exe"
BUILD_TOOL_RESTART_EXIT_CODE  :: 75

Build_Mode :: enum {
	Debug,
	Release,
	Hot_Reload_Only,
}

when ODIN_OS == .Windows {
	DEBUG_EXECUTABLE :: "build/debug/main.exe"
	RELEASE_EXECUTABLE :: "build/release/main.exe"
	GAME_LIBRARY :: "build/debug/game.dll"
	GAME_LIBRARY_BUILD_OUTPUT :: "build/debug/game.pending.dll"
	GAME_DEBUG_DATABASE :: "build/debug/game.pdb"
	GLFW_RUNTIME_SOURCE :: ODIN_ROOT + "vendor/glfw/lib/glfw3.dll"
	SLANG_RUNTIME_DIRECTORY :: "deps/odin-slang/slang/bin/"
	SLANG_RUNTIME_DLLS :: [?]string {
		"gfx.dll",
		"slang.dll",
		"slang-glsl-module.dll",
		"slang-glslang.dll",
		"slang-llvm.dll",
		"slang-rt.dll",
	}
} else when ODIN_OS == .Darwin {
	DEBUG_EXECUTABLE :: "build/debug/main"
	RELEASE_EXECUTABLE :: "build/release/main"
	GAME_LIBRARY :: "build/debug/game.dylib"
	GAME_LIBRARY_BUILD_OUTPUT :: "build/debug/game.pending.dylib"
} else {
	DEBUG_EXECUTABLE :: "build/debug/main"
	RELEASE_EXECUTABLE :: "build/release/main"
	GAME_LIBRARY :: "build/debug/game.so"
	GAME_LIBRARY_BUILD_OUTPUT :: "build/debug/game.pending.so"
}

print_usage :: proc() {
	fmt.println("Usage:")
	fmt.println("  build.bat                 Build debug DLL and launcher")
	fmt.println("  build.bat release         Build the release executable")
	fmt.println("  build.bat hotreload       Build only the hot-reload DLL")
	fmt.println("")
	fmt.println("The legacy release argument `1` is also accepted.")
}

start_command :: proc(command: []string, description := "Command") -> (process: os.Process, started: bool) {
	fmt.print(">")
	for argument in command {
		fmt.print(" ", argument, sep = "")
	}
	fmt.println()

	start_error: os.Error
	process, start_error = os.process_start(
		{
			command = command,
			stdin   = os.stdin,
			stdout  = os.stdout,
			stderr  = os.stderr,
		},
	)
	if start_error != nil {
		fmt.eprintfln("Failed to start {0}: {1}", description, start_error)
		return {}, false
	}

	return process, true
}

wait_command :: proc(process: os.Process, description := "command") -> int {
	state, wait_error := os.process_wait(process)
	if wait_error != nil {
		fmt.eprintfln("Failed while waiting for {0}: {1}", description, wait_error)
		return 1
	}
	if !state.exited {
		fmt.eprintfln("{0} did not report an exit status.", description)
		return 1
	}
	return state.exit_code
}

run_command :: proc(command: []string, description := "command") -> int {
	process, started := start_command(command, description)
	if !started {
		return 1
	}
	return wait_command(process, description)
}

running_as_bootstrapped_build_tool :: proc() -> bool {
	if !os.exists(BUILD_TOOL_EXECUTABLE) {
		return false
	}

	executable_path, executable_path_error := os.get_executable_path(context.temp_allocator)
	if executable_path_error != nil {
		return false
	}

	executable_info, executable_error := os.stat(executable_path, context.temp_allocator)
	if executable_error != nil {
		return false
	}
	defer os.file_info_delete(executable_info, context.temp_allocator)

	build_tool_info, build_tool_error := os.stat(BUILD_TOOL_EXECUTABLE, context.temp_allocator)
	if build_tool_error != nil {
		return false
	}
	defer os.file_info_delete(build_tool_info, context.temp_allocator)

	return os.same_file(executable_info, build_tool_info)
}

source_is_newer_than :: proc(path: string, timestamp: time.Time) -> (newer: bool, ok: bool) {
	source_timestamp, timestamp_error := os.last_write_time_by_name(path)
	if timestamp_error != nil {
		fmt.eprintln("Failed to inspect build-tool source:", path, timestamp_error)
		return false, false
	}

	return time.to_unix_nanoseconds(source_timestamp) > time.to_unix_nanoseconds(timestamp), true
}

odin_source_tree_is_newer_than :: proc(path: string, timestamp: time.Time) -> (newer: bool, ok: bool) {
	// The directory timestamp catches added or removed files; walking it catches
	// edits to existing Odin source files.
	if newer, source_ok := source_is_newer_than(path, timestamp); !source_ok {
		return false, false
	} else if newer {
		return true, true
	}

	walker := os.walker_create(path)
	defer os.walker_destroy(&walker)

	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".odin") {
			continue
		}
		if time.to_unix_nanoseconds(info.modification_time) >
		   time.to_unix_nanoseconds(timestamp) {
			return true, true
		}
	}

	if failed_path, walk_error := os.walker_error(&walker); walk_error != nil {
		fmt.eprintln("Failed to inspect Odin sources:", failed_path, walk_error)
		return false, false
	}

	return false, true
}

build_tool_is_stale :: proc() -> (stale: bool, ok: bool) {
	build_tool_timestamp, timestamp_error := os.last_write_time_by_name(BUILD_TOOL_EXECUTABLE)
	if timestamp_error != nil {
		fmt.eprintln("Failed to inspect build tool:", timestamp_error)
		return false, false
	}

	if newer, source_ok := source_is_newer_than("build.odin", build_tool_timestamp); !source_ok {
		return false, false
	} else if newer {
		return true, true
	}

	return odin_source_tree_is_newer_than("meta", build_tool_timestamp)
}

debug_executable_is_stale :: proc() -> (stale: bool, ok: bool) {
	if !os.exists(DEBUG_EXECUTABLE) {
		return true, true
	}

	executable_timestamp, timestamp_error := os.last_write_time_by_name(DEBUG_EXECUTABLE)
	if timestamp_error != nil {
		fmt.eprintln("Failed to inspect debug executable:", timestamp_error)
		return false, false
	}

	// Changes here may alter the compiler flags even if the launcher source did
	// not change.
	if newer, source_ok := source_is_newer_than("build.odin", executable_timestamp); !source_ok {
		return false, false
	} else if newer {
		return true, true
	}

	return odin_source_tree_is_newer_than("entrypoints/hotreload", executable_timestamp)
}

rebuild_build_tool_if_stale :: proc() -> (handled: bool, exit_code: int) {
	when ODIN_OS != .Windows {
		return false, 0
	}

	if !running_as_bootstrapped_build_tool() {
		return false, 0
	}

	stale, freshness_check_ok := build_tool_is_stale()
	if !freshness_check_ok {
		return true, 1
	}
	if !stale {
		return false, 0
	}

	fmt.println("Build tool sources changed; rebuilding build/build.exe...")
	command := []string {
		"odin",
		"build",
		"build.odin",
		"-file",
		"-o:none",
		"-out:" + BUILD_TOOL_PENDING_EXECUTABLE,
	}
	if result := run_command(command); result != 0 {
		return true, result
	}

	// build.bat performs the replacement after this process releases build.exe.
	return true, BUILD_TOOL_RESTART_EXIT_CODE
}

ensure_directory :: proc(path: string) -> bool {
	if os.is_directory(path) {
		return true
	}
	if os.exists(path) {
		fmt.eprintln("Build output path exists but is not a directory:", path)
		return false
	}

	err := os.make_directory_all(path)
	if err != nil {
		fmt.eprintln("Failed to create build output directory:", path, err)
		return false
	}
	return true
}

output_is_replaceable :: proc(path: string) -> (replaceable: bool, reason: string) {
	if !os.exists(path) {
		return true, ""
	}

	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return false, fmt.tprintf("could not inspect output: %v", stat_error)
	}
	defer os.file_info_delete(info, context.temp_allocator)

	if .Write_User not_in info.mode {
		return false, "output is read-only"
	}

	file, open_error := os.open(path, {.Write})
	if open_error != nil {
		return false, fmt.tprintf("output is locked or not writable: %v", open_error)
	}
	close_error := os.close(file)
	if close_error != nil {
		return false, fmt.tprintf("could not close output probe: %v", close_error)
	}

	return true, ""
}

copy_runtime_dependency_if_missing :: proc(source, destination: string) -> bool {
	if os.exists(destination) {
		return true
	}
	if !os.exists(source) {
		fmt.eprintln("Runtime library is missing:", source)
		return false
	}
	if copy_error := os.copy_file(destination, source); copy_error != nil {
		fmt.eprintfln("Failed to copy runtime library {0} -> {1}: {2}", source, destination, copy_error)
		return false
	}
	fmt.println("Staged runtime library:", destination)
	return true
}

ensure_runtime_dependencies :: proc(output_directory: string, include_glfw: bool) -> bool {
	when ODIN_OS == .Windows {
		if include_glfw && !copy_runtime_dependency_if_missing(
			GLFW_RUNTIME_SOURCE,
			fmt.tprintf("{0}/glfw3.dll", output_directory),
		) {
			return false
		}

		for filename in SLANG_RUNTIME_DLLS {
			if !copy_runtime_dependency_if_missing(
				fmt.tprintf("{0}{1}", SLANG_RUNTIME_DIRECTORY, filename),
				fmt.tprintf("{0}/{1}", output_directory, filename),
			) {
				return false
			}
		}
	}
	return true
}

publish_game_library :: proc() -> bool {
	if publish_error := os.rename(GAME_LIBRARY_BUILD_OUTPUT, GAME_LIBRARY); publish_error != nil {
		fmt.eprintln("Failed to publish game library:", publish_error)
		return false
	}
	return true
}

start_game_library_build :: proc() -> (process: os.Process, started: bool) {
	when ODIN_OS == .Windows {
		command := []string {
			"odin",
			"build",
			"src",
			"-build-mode:dll",
			"-collection:deps=deps",
			"-custom-attribute:shader_shared",
			"-custom-attribute:entity",
			"-show-timings",
			"-debug",
			"-o:none",
			"-define:GLFW_SHARED=true",
			"-pdb-name:" + GAME_DEBUG_DATABASE,
			"-out:" + GAME_LIBRARY_BUILD_OUTPUT,
		}
		return start_command(command, "game library build")
	} else {
		command := []string {
			"odin",
			"build",
			"src",
			"-build-mode:dll",
			"-collection:deps=deps",
			"-custom-attribute:shader_shared",
			"-custom-attribute:entity",
			"-show-timings",
			"-debug",
			"-o:none",
			"-out:" + GAME_LIBRARY_BUILD_OUTPUT,
		}
		return start_command(command, "game library build")
	}
}

build_game_library :: proc() -> bool {
	process, started := start_game_library_build()
	if !started {
		return false
	}
	if wait_command(process, "game library build") != 0 {
		return false
	}
	return publish_game_library()
}

start_debug_executable_build :: proc() -> (process: os.Process, started: bool) {
	command := []string {
		"odin",
		"build",
		"entrypoints/hotreload",
		"-show-timings",
		"-debug",
		"-o:none",
		"-out:" + DEBUG_EXECUTABLE,
	}
	return start_command(command, "debug executable build")
}

build_debug_outputs :: proc() -> bool {
	game_process, game_started := start_game_library_build()
	if !game_started {
		return false
	}

	executable_process, executable_started := start_debug_executable_build()
	if !executable_started {
		// The game build is already running and must still be reaped.
		_ = wait_command(game_process, "game library build")
		return false
	}

	game_exit_code := wait_command(game_process, "game library build")
	executable_exit_code := wait_command(executable_process, "debug executable build")
	game_published := game_exit_code == 0 && publish_game_library()
	return game_published && executable_exit_code == 0
}

build_release_executable :: proc() -> bool {
	command := []string {
		"odin",
		"build",
		"entrypoints",
		"-collection:deps=deps",
		"-custom-attribute:shader_shared",
		"-custom-attribute:entity",
		"-show-timings",
		"-o:speed",
		"-out:" + RELEASE_EXECUTABLE,
	}
	return run_command(command) == 0
}

parse_build_mode :: proc() -> (mode: Build_Mode, ok: bool, help_requested: bool) {
	mode = .Debug
	ok = true

	for argument in os.args[1:] {
		switch argument {
		case "debug", "--debug":
			mode = .Debug
		case "release", "--release", "1":
			mode = .Release
		case "hotreload", "--hotreload", "dll", "--dll-only":
			mode = .Hot_Reload_Only
		case "-h", "--help", "help":
			help_requested = true
			return
		case:
			fmt.eprintln("Unknown build argument:", argument)
			ok = false
			return
		}
	}
	return
}

run_build :: proc() -> int {
	mode, arguments_ok, help_requested := parse_build_mode()
	if help_requested {
		print_usage()
		return 0
	}
	if !arguments_ok {
		print_usage()
		return 2
	}

	if !os.is_directory("src") || !os.is_directory("entrypoints") {
		fmt.eprintln("Run build.odin from the repository root.")
		return 1
	}
	if !ensure_directory("build") {
		return 1
	}

	switch mode {
	case .Release:
		if !ensure_directory("build/release") {
			return 1
		}
		if !ensure_runtime_dependencies("build/release", false) {
			return 1
		}
	case .Debug, .Hot_Reload_Only:
		if !ensure_directory("build/debug") {
			return 1
		}
		if !ensure_runtime_dependencies("build/debug", true) {
			return 1
		}
	}

	if !build_meta.generate() {
		fmt.eprintln("Source generation failed.")
		return 1
	}

	build_ok := false
	switch mode {
	case .Release:
		build_ok = build_release_executable()

	case .Hot_Reload_Only:
		fmt.println("Building hot-reload library only.")
		build_ok = build_game_library()

	case .Debug:
		executable_stale, freshness_check_ok := debug_executable_is_stale()
		if !freshness_check_ok {
			return 1
		}

		if !executable_stale {
			fmt.println("Debug executable is up to date; building only", GAME_LIBRARY + ".")
			build_ok = build_game_library()
		} else if executable_available, unavailable_reason := output_is_replaceable(DEBUG_EXECUTABLE); !executable_available {
			fmt.printfln(
				"{0} is unavailable ({1}); building only {2}.",
				DEBUG_EXECUTABLE,
				unavailable_reason,
				GAME_LIBRARY,
			)
			build_ok = build_game_library()
		} else {
			fmt.println("Building game library and debug executable concurrently.")
			build_ok = build_debug_outputs()
		}
	}

	if !build_ok {
		return 1
	}
	return 0
}

main :: proc() {
	if bootstrap_handled, bootstrap_exit_code := rebuild_build_tool_if_stale(); bootstrap_handled {
		if bootstrap_exit_code != 0 {
			os.exit(bootstrap_exit_code)
		}
		return
	}

	start_time := time.now()
	exit_code := run_build()
	fmt.eprintln("Total build time:", time.since(start_time))

	if exit_code != 0 {
		os.exit(exit_code)
	}
}
