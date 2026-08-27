package game

import "core:testing"

@(test)
asset_type_uses_dotted_extensions :: proc(t: ^testing.T) {
	testing.expect_value(t, asset_type_from_base("sound.wav"), Asset_Type.Sound)
	testing.expect_value(t, asset_type_from_base("mesh.glb"), Asset_Type.Mesh)
	testing.expect_value(t, asset_type_from_base("sk_character.glb"), Asset_Type.SkinnedMesh)
	testing.expect_value(t, asset_type_from_base("texture.ktx2"), Asset_Type.Texture)
	testing.expect_value(t, asset_type_from_base("font.ttf"), Asset_Type.Font)
}

@(test)
action_edges_advance_once_per_sample :: proc(t: ^testing.T) {
	state: ActionState

	update_action_state(&state, true)
	testing.expect(t, state.current_state)
	testing.expect(t, !state.previous_state)

	update_action_state(&state, true)
	testing.expect(t, state.current_state)
	testing.expect(t, state.previous_state)

	update_action_state(&state, false)
	testing.expect(t, !state.current_state)
	testing.expect(t, state.previous_state)
}
