package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import build_meta "meta"

run_command :: proc(command: []string) -> int {
	process, start_err := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_err != nil {
		fmt.eprintln("Failed to exec:", start_err)
		return 1
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil || !state.exited {
		fmt.eprintln("Failed to exec:", wait_err)
		return 1
	}

	return state.exit_code
}

main :: proc() {
	start_time := time.now()

	release := false
	patch_directory := ""

	for argument in os.args[1:] {
		switch argument {
		case "debug", "--debug":
			release = false
		case "release", "--release", "1":
			release = true
		case "-h", "--help", "help":
			fmt.println("Usage: build.bat [debug|release|1] (default: debug)")
			fmt.println("Debug builds enable livepatch on Windows x64.")
			fmt.println("  build.bat --patch-dir=<directory>    Build livepatch objects")
			os.exit(0)
		case:
			if strings.has_prefix(argument, "--patch-dir=") {
				patch_directory = strings.trim_prefix(argument, "--patch-dir=")
				if patch_directory != "" do continue
			}
			fmt.eprintln("Unknown build argument:", argument)
			os.exit(2)
		}
	}

	livepatch := !release && ODIN_OS == .Windows && ODIN_ARCH == .amd64
	if patch_directory != "" && !livepatch {
		fmt.eprintln("Livepatch objects require a Windows x64 debug build.")
		os.exit(2)
	}

	output_directory := "build/release" if release else "build/debug"
	if patch_directory != "" do output_directory = patch_directory
	if err := os.make_directory_all(output_directory); err != nil {
		fmt.eprintln("Failed to create output directory:", err)
		os.exit(1)
	}
	if !build_meta.generate() {
		fmt.eprintln("Source generation failed.")
		os.exit(1)
	}

	if ODIN_OS == .Windows && patch_directory == "" {
		runtime_dlls := []string{"gfx.dll", "slang.dll", "slang-glsl-module.dll", "slang-glslang.dll", "slang-llvm.dll", "slang-rt.dll"}
		for filename in runtime_dlls {
			source := fmt.tprintf("deps/odin-slang/slang/bin/%s", filename)
			destination := fmt.tprintf("%s/%s", output_directory, filename)
			if os.exists(destination) do continue
			if err := os.copy_file(destination, source); err != nil {
				fmt.eprintln("Failed to copy runtime library:", source, "->", destination, err)
				os.exit(1)
			}
			fmt.println("Copied", destination)
		}
	}

	command: [dynamic]string

	compiler, found := os.lookup_env("ODIN", context.temp_allocator)
	if !found || compiler == "" {
		compiler = "odin"
	}

	append(
		&command,
		compiler,
		"build",
		"src",
		"-collection:deps=deps",
		"-custom-attribute:shader_shared",
		"-custom-attribute:entity",
		"-show-timings",
	)
	when ODIN_OS == .Windows {
		if livepatch {
			append(
				&command,
				"-use-separate-modules",
				"-define:LIVEPATCH=true",
				"-linker:lld",
				"-extra-linker-flags:/OPT:NOREF /OPT:NOICF /MAP:build/debug/main.map",
			)
		} else {
			append(&command, "-linker:radlink")
		}
	}

	if release {
		append(&command, "-o:speed")
	} else {
		append(&command, "-debug", "-o:none")
	}
	if patch_directory != "" {
		append(&command, "-build-mode:obj", fmt.tprintf("-out:%s/", patch_directory))
	} else {
		executable := "/main.exe" when ODIN_OS == .Windows else "/main"
		append(&command, fmt.tprintf("-out:%s%s", output_directory, executable))
	}

	code := run_command(command[:])

	fmt.eprintln("Total build time:", time.since(start_time))

	os.exit(code)
}
