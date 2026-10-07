package game

import "core:strings"
import ma "vendor:miniaudio"

@(entity)
@(init = init_sound_source)
@(destroy = destroy_sound_source)
SoundSource :: struct {
	using entity:   ^Entity,
	translation:    Vec3,
	path:           string,
	loop:           bool,
	rolloff:        f32,
	spatialization: bool,
	volume:         f32,
	sound:          ma.sound,
}

new_sound_source :: proc(path: string, loop := false, rolloff: f32 = 1, spatialization := true, volume: f32 = 1.0) -> ^SoundSource {
	return new_entity(SoundSource{path = path, loop = loop, rolloff = rolloff, spatialization = spatialization, volume = volume})
}

init_sound_source :: proc(source: ^SoundSource) {
	extra_flags: ma.sound_flags = source.spatialization ? {} : {.NO_SPATIALIZATION}

	path := strings.clone_to_cstring(source.path)
	defer delete(path)

	result := ma.sound_init_from_file(&game.sound_system.sound_engine, path, {.DECODE} + extra_flags, nil, nil, &source.sound)
	assert(result == .SUCCESS)
	ma.sound_set_looping(&source.sound, cast(b32)source.loop)
	ma.sound_set_rolloff(&source.sound, source.rolloff)
	ma.sound_set_volume(&source.sound, source.volume)
	ma.sound_start(&source.sound)
}

destroy_sound_source :: proc(source: ^SoundSource) {
	ma.sound_uninit(&source.sound)
}
