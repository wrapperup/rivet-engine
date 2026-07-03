package game

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:time"

import gltf2 "deps:gltf2"
import vk "vendor:vulkan"

import gfx "gfx"

Scene :: struct {
	source:          string,
	last_write_time: i64, // mtime of `source` at load, for auto-reload on change
	arena:           virtual.Arena,
	gpu_arena:       gfx.ResourceArena,
	entities:        [dynamic]EntityId,
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
	t, _ := os.last_write_time_by_name(path)
	scene.last_write_time = t._nsec
	parse_gltf_into_scene(scene, data)
	return true
}

// Poll the source file's mtime and reload if it changed (e.g. a Blender re-export). Throttled so
// it's not hundreds of filesystem calls per second, like check_shader_hotreload. Call from update.
check_scene_hotreload :: proc(scene: ^Scene) {
	@(static) last_check: time.Time
	now := time.now()
	if time.duration_seconds(time.diff(last_check, now)) < 0.5 {
		return
	}
	last_check = now

	if scene.source == "" {
		return
	}
	t, _ := os.last_write_time_by_name(scene.source)
	if t._nsec > scene.last_write_time {
		log.info("Scene changed on disk, reloading:", scene.source)
		reload_scene(scene) // load_scene_from_file refreshes scene.last_write_time
	}
}

// Rebuild the scene from its source file: destroy the old entities + GPU resources, then reload
// into the same Scene.
reload_scene :: proc(scene: ^Scene) {
	// The GPU may still be using probe cubes from an in-flight frame; wait before freeing.
	vk.DeviceWaitIdle(gfx.r_ctx.device)

	gfx.flush_vk_arena(&scene.gpu_arena) // frees probe cubes/samplers/buffers (clears the queue)
	for id in scene.entities {
		destroy_entity(id) // runs the probe teardown (bindless slots) + removes from storage
	}
	clear(&scene.entities)

	load_scene_from_file(scene, scene.source)
}

// glTF numbers arrive as json.Integer OR json.Float depending on whether the value had a decimal
// point (e.g. "intensity": 1 vs "blend_distance": 1.6), so accept both.
json_f32 :: proc(v: json.Value, default: f32) -> f32 {
	#partial switch t in v {
	case json.Integer:
		return f32(t)
	case json.Float:
		return f32(t)
	}
	return default
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
		case "ddgi_volume":
			// The node's box (translation = center, scale = half-extents) is the probe-grid AABB.
			// Counts derive from the target spacing, then spacing is re-fit so the grid spans the
			// box exactly (grid AABB == authored box, which is what edge_fade measures against).
			spacing_target := json_f32(object["probe_spacing"], 2.5)
			half := Vec3{node.scale.x, node.scale.y, node.scale.z}
			origin := Vec3{node.translation.x, node.translation.y, node.translation.z} - half

			counts: [3]u32
			spacing: Vec3
			for i in 0 ..< 3 {
				size := 2 * half[i]
				counts[i] = clamp(u32(math.round(size / spacing_target)) + 1, 2, 64)
				spacing[i] = size / f32(counts[i] - 1)
			}

			vol := new_entity(DDGIVolume)
			vol.translation = origin + half
			ddgi_volume_resources_init(
				&vol.volume,
				origin,
				spacing,
				counts,
				&scene.gpu_arena,
				priority = json_f32(object["priority"], 0),
				edge_fade = json_f32(object["edge_fade"], 1.0),
			)
			append(&scene.entities, vol.id)
		case "reflection_probe":
			probe := new_entity(ReflectionProbe)
			reflection_probe_init(probe, node.translation, node.scale, &scene.gpu_arena)
			probe.blend_distance = json_f32(object["blend_distance"], probe.blend_distance)
			probe.intensity = json_f32(object["intensity"], probe.intensity)
			probe.priority = json_f32(object["priority"], probe.priority)
			append(&scene.entities, probe.id)
		case "static_mesh":
			// The node's `asset` extra is a mesh path relative to the working dir; the transform
			// places both the rendered mesh and its physics body. We ignore the glTF mesh data.
			asset, has_asset := object["asset"].(json.String)
			if !has_asset || asset == "" {
				log.warn("static_mesh node missing 'asset' path, skipping:", node.name.? or_else "<unnamed>")
				continue
			}
			material := MaterialId(json_f32(object["material"], 0))
			sm := new_entity(StaticMesh)
			init_static_mesh(sm, asset, material, node.translation, node.rotation)
			append(&scene.entities, sm.id)
		}
	}
}
