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

@(test)
entity_storage_keeps_addresses_stable_and_reuses_slots :: proc(t: ^testing.T) {
	system: EntitySystem
	testing.expect(t, init_entity_system_storage(&system))
	defer shutdown_entity_system_storage(&system)

	first := new_entity_raw_from_storage(&system)
	first_id := first.id
	testing.expect(t, first_id.generation != 0)
	testing.expect(t, entity_id_to_rawptr(first_id) != nil)

	// Force a second page to be allocated. The first entity's address must stay
	// stable because subtype instances retain pointers to their core entities.
	for _ in 0 ..< ENTITY_PAGE_SIZE {
		_ = new_entity_raw_from_storage(&system)
	}
	testing.expect(t, get_entity_raw_from_storage(&system, first_id) == first)
	testing.expect_value(t, system.slot_count, u32(ENTITY_PAGE_SIZE + 1))

	testing.expect(t, release_entity_slot(&system, first_id))
	testing.expect(t, get_entity_raw_from_storage(&system, first_id) == nil)
	testing.expect(t, !release_entity_slot(&system, first_id))

	reused := new_entity_raw_from_storage(&system)
	testing.expect_value(t, reused.id.index, first_id.index)
	testing.expect(t, reused.id.generation != first_id.generation)
	testing.expect(t, get_entity_raw_from_storage(&system, first_id) == nil)
	testing.expect(t, get_entity_raw_from_storage(&system, reused.id) == reused)
	testing.expect_value(t, system.slot_count, u32(ENTITY_PAGE_SIZE + 1))
	testing.expect_value(t, system.live_count, u32(ENTITY_PAGE_SIZE + 1))

	testing.expect(t, get_entity_raw_from_storage(&system, {}) == nil)
	testing.expect(
		t,
		get_entity_raw_from_storage(&system, {generation = 1, index = system.slot_count}) == nil,
	)
}
