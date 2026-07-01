package game

import "core:encoding/json"
import "core:mem/virtual"

import gltf2 "deps:gltf2"
import vk "vendor:vulkan"

import gfx "gfx"

Scene :: struct {
	source:    string,
	arena:     virtual.Arena,
	gpu_arena: gfx.ResourceArena,
	entities:  [dynamic]EntityId,
}

// Load a scene glTF into `scene` in place. Everything the scene spawns is owned by it: entity ids
// go in scene.entities, GPU resources are deferred to scene.gpu_arena — so reload_scene can tear
// it all down cleanly. Building in place (rather than returning by value) is what keeps the probe
// GPU deferrals landing in the arena that actually survives.
load_scene_from_file :: proc(scene: ^Scene, path: string) -> bool {
	data, error := gltf2.load_from_file(path)
	if error != nil {
		return false
	}
	defer gltf2.unload(data)

	scene.source = path
	parse_gltf_into_scene(scene, data)
	return true
}

// Rebuild the scene from its source file: destroy the old entities + GPU resources, then reload
// into the same Scene.
reload_scene :: proc(scene: ^Scene) {
	// The GPU may still be using probe cubes from an in-flight frame; wait before freeing.
	vk.DeviceWaitIdle(gfx.r_ctx.device)

	gfx.flush_vk_arena(&scene.gpu_arena) // frees probe cubes/samplers/buffers (clears the queue)
	for id in scene.entities {
		if probe := get_entity(ReflectionProbe, id); probe != nil {
			reflection_probe_destroy(probe) // release its bindless slots for reuse
		}
		remove_entity(ReflectionProbe, id)
	}
	clear(&scene.entities)

	load_scene_from_file(scene, scene.source)
}

ReflectionProbeJson :: struct {
	engine_type:    string,
	blend_distance: f32,
	intensity:      f32,
}

parse_gltf_into_scene :: proc(scene: ^Scene, data: ^gltf2.Data) {
	for node in data.nodes {
		// Nodes without extras (meshes, empties) simply aren't engine entities — skip, don't crash.
		object, has_extras := node.extras.(json.Object)
		if !has_extras {
			continue
		}
		engine_type, _ := object["engine_type"].(json.String)

		switch engine_type {
		case "reflection_probe":
			probe := new_entity(ReflectionProbe)
			reflection_probe_init(probe, node.translation, node.scale, &scene.gpu_arena)
			append(&scene.entities, probe.id)
		}
	}
}
