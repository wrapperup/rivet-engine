package game

import "base:runtime"
import "core:fmt"

import im "deps:odin-imgui"

GAME_EDITOR :: true

Debug_Vis_Flag :: enum {
    Irradiance_Probes,
    Reflection_Probes,
}

Debug_Vis_Flags :: bit_set[Debug_Vis_Flag;u32]

Editor_Settings :: struct {
	debug_vis_flags: Debug_Vis_Flags,
}
