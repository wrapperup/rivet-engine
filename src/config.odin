package game

GameConfig :: struct {
	use_stable_shadow_maps:      bool,
	shadow_map_size:             u32,
	shadow_cascade_split_lambda: f32,
}

default_game_config :: proc() -> GameConfig {
	return {use_stable_shadow_maps = true, shadow_map_size = 2048, shadow_cascade_split_lambda = 0.9}
}
