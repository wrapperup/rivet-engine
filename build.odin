package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import build_meta "meta"

run_command :: proc(command: []string) -> int {
	fmt.println(">", strings.join(command, " ", context.temp_allocator))
	process, start_error := os.process_start({
		command = command,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if start_error != nil {
		fmt.eprintln("Failed to start compiler:", start_error)
		return 1
	}
	state, wait_error := os.process_wait(process)
	if wait_error != nil || !state.exited {
		fmt.eprintln("Failed to wait for compiler:", wait_error)
		return 1
	}
	return state.exit_code
}

run_build :: proc() -> int {
	release := false
	for argument in os.args[1:] {
		switch argument {
		case "debug", "--debug":
			release = false
		case "release", "--release", "1":
			release = true
		case "-h", "--help", "help":
			fmt.println("Usage: build.bat [debug|release|1] (default: debug)")
			return 0
		case:
			fmt.eprintln("Unknown build argument:", argument)
			return 2
		}
	}

	output_directory := "build/release" if release else "build/debug"
	if err := os.make_directory_all(output_directory); err != nil {
		fmt.eprintln("Failed to create output directory:", err)
		return 1
	}
	if !build_meta.generate() {
		fmt.eprintln("Source generation failed.")
		return 1
	}

	when ODIN_OS == .Windows {
		runtime_dlls := []string {
			"gfx.dll",
			"slang.dll",
			"slang-glsl-module.dll",
			"slang-glslang.dll",
			"slang-llvm.dll",
			"slang-rt.dll",
		}
		for filename in runtime_dlls {
			source := fmt.tprintf("deps/odin-slang/slang/bin/%s", filename)
			destination := fmt.tprintf("%s/%s", output_directory, filename)
			if os.exists(destination) do continue
			if err := os.copy_file(destination, source); err != nil {
				fmt.eprintln("Failed to copy runtime library:", source, "->", destination, err)
				return 1
			}
			fmt.println("Copied", destination)
		}
	}

	command := make([dynamic]string)
	defer delete(command)
	append(&command,
		"odin", "build", "src",
		"-collection:deps=deps",
		"-custom-attribute:shader_shared",
		"-custom-attribute:entity",
		"-show-timings",
	)
	when ODIN_OS == .Windows {
		append(&command, "-linker:radlink")
	}
	if release {
		append(&command, "-o:speed")
	} else {
		append(&command, "-debug", "-o:none")
	}
	executable := "/main.exe" when ODIN_OS == .Windows else "/main"
	append(&command, fmt.tprintf("-out:%s%s", output_directory, executable))
	return run_command(command[:])
}

main :: proc() {
	start_time := time.now()
	exit_code := run_build()
	fmt.eprintln("Total build time:", time.since(start_time))
	if exit_code != 0 do os.exit(exit_code)
}
