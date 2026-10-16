package main

import "core:path/filepath"
import "core:strings"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:time"

import build_meta "meta"

Flavor :: enum {
	debug_editor,
	debug_game,
	release_game,
}

Build_Command_Flags :: struct {
	flavor: Flavor `args:"pos=0" usage:"Kind of build to make."`,
}

main :: proc() {
	start_time := time.now()

	args := Build_Command_Flags{}

	error := flags.parse(&args, os.args[1:])
	switch v in error {
	case flags.Help_Request:
		fmt.println("Usage:")
		fmt.println("  build [target=debug_editor]")
		os.exit(0)
	case flags.Parse_Error:
		fmt.println(v.message)
		os.exit(1)
	case flags.Open_File_Error:
		fmt.println("could not open", v.filename)
		os.exit(1)
	case flags.Validation_Error:
		fmt.println(v.message)
		os.exit(1)
	}

	output_directory: string
    livepatch := true

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
		"-custom-attribute:init",
		"-custom-attribute:destroy",
		"-show-timings",
	)

	switch args.flavor {
	case .debug_editor:
		output_directory = "build/debug"
		append(&command, "-o:none")
		append(&command, "-debug")

		append(&command, "-define:EDITOR=true")
	case .debug_game:
		output_directory = "build/debug"
		append(&command, "-o:none")
		append(&command, "-debug")

		append(&command, "-define:EDITOR=false")
		append(&command, "-define:REQUIRE_COOKED_ASSETS=true")

	case .release_game:
		output_directory = "build/release"
		append(&command, "-o:speed")

		append(&command, "-define:EDITOR=false")
		append(&command, "-define:REQUIRE_COOKED_ASSETS=true")
	}

	if livepatch {
        path, _ := filepath.abs(os.args[0])
		append(
			&command,
			"-use-separate-modules",
			"-define:LIVEPATCH=true",
			fmt.tprintf("-define:BUILD_COMMAND=%s %s", path, strings.join(os.args[1:], " ")),
			"-extra-linker-flags:/OPT:NOREF /OPT:NOICF /MAP:build/debug/main.map",
		)
	}

	executable := "/main.exe" when ODIN_OS == .Windows else "/main"
	append(&command, fmt.tprintf("-out:%s%s", output_directory, executable))

	if !build_meta.generate() {
		fmt.eprintln("Source generation failed.")
		os.exit(1)
	}

	code := run_command(command[:])

	fmt.eprintln("Total build time:", time.since(start_time))

	os.exit(code)
}

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
