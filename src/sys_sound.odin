package game

import "core:strings"
import ma "vendor:miniaudio"

SoundSystem :: struct {
	initialized:  bool,
	sound_engine: ma.engine,
}

init_sound_system :: proc() {
	config := ma.engine_config_init()
	result := ma.engine_init(&config, &game.sound_system.sound_engine)
	assert(result == .SUCCESS)

	ma.engine_listener_set_cone(&game.sound_system.sound_engine, 0, 40, 60, 10)

	game.sound_system.initialized = true
}

shutdown_sound_system :: proc() {
	if !game.sound_system.initialized do return
	ma.engine_uninit(&game.sound_system.sound_engine)
	game.sound_system = {}
}

play_sound :: proc(asset_name: Asset_Name) {
	assert(game.sound_system.initialized)
    path_c := strings.clone_to_cstring(asset_path(asset_name))
    defer delete(path_c)

	ma.engine_play_sound(&game.sound_system.sound_engine, path_c, nil)
}

// The caller owns `sound` and must call ma.sound_uninit when it is finished.
play_sound_3d :: proc(sound: ^ma.sound, path: cstring, position: Vec3) -> bool {
	assert(game.sound_system.initialized)

	if ma.sound_init_from_file(&game.sound_system.sound_engine, path, {.DECODE}, nil, nil, sound) != .SUCCESS {
		return false
	}
	ma.sound_set_position(sound, position.x, position.y, position.z)
	ma.sound_set_looping(sound, true)
	ma.sound_start(sound)
	return true
}

set_listener_position :: proc(position: Vec3, forward: Vec3) {
	assert(game.sound_system.initialized)

	ma.engine_listener_set_position(&game.sound_system.sound_engine, 0, position.x, position.y, position.z)
	ma.engine_listener_set_direction(&game.sound_system.sound_engine, 0, forward.x, forward.y, forward.z)
}
