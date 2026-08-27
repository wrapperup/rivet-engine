package game

import "core:strings"
import ma "vendor:miniaudio"

@entity
SoundSource :: struct {
	using entity: ^Entity,
	sound:        ma.sound,
}

init_sound_source :: proc(
	source: ^SoundSource,
    asset_name: Asset_Name,
	loop: b32 = false,
	rolloff: f32 = 1,
	spatialization := true,
	volume: f32 = 1.0,
) {
	extra_flags: ma.sound_flags = spatialization ? {} : {.NO_SPATIALIZATION}

    path := strings.clone_to_cstring(asset_path(asset_name))
    defer delete(path)

	result := ma.sound_init_from_file(&game.sound_system.sound_engine, path, {.DECODE} + extra_flags, nil, nil, &source.sound)
	assert(result == .SUCCESS)
	ma.sound_set_looping(&source.sound, loop)
	ma.sound_set_rolloff(&source.sound, rolloff)
	ma.sound_set_volume(&source.sound, volume)
	ma.sound_start(&source.sound)

}

destroy_sound_source :: proc(source: ^SoundSource) {
	ma.sound_uninit(&source.sound)
}
