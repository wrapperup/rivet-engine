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
	initialized:     bool,
}

scene_init :: proc(scene: ^Scene) -> bool {
	if scene.initialized do return true
	if virtual.arena_init_growing(&scene.arena) != nil {
		return false
	}
	scene.entities = make([dynamic]EntityId, virtual.arena_allocator(&scene.arena))
	scene.initialized = true
	return true
}

load_scene_from_file :: proc(scene: ^Scene, path: string) -> bool {
	if !scene_init(scene) {
		return false
	}
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

reload_scene :: proc(scene: ^Scene) {
	vk.DeviceWaitIdle(gfx.r_ctx.device)

	for id in scene.entities {
		destroy_entity(id)
	}
	gfx.flush_vk_arena(&scene.gpu_arena)
	gfx.delete_vk_arena(scene.gpu_arena)
	scene.gpu_arena = {}

	source := scene.source
	virtual.arena_free_all(&scene.arena)
	scene.entities = make([dynamic]EntityId, virtual.arena_allocator(&scene.arena))

	if !load_scene_from_file(scene, source) {
		log.error("Failed to reload scene:", source)
	}
}

scene_shutdown :: proc(scene: ^Scene) {
	if !scene.initialized do return

	for id in scene.entities {
		destroy_entity(id)
	}
	gfx.flush_vk_arena(&scene.gpu_arena)
	gfx.delete_vk_arena(scene.gpu_arena)
	virtual.arena_destroy(&scene.arena)
	scene^ = {}
}

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
		object, has_extras := node.extras.(json.Object)
		if !has_extras {
			continue
		}
		engine_type, _ := object["engine_type"].(json.String)

		switch engine_type {
		case "ddgi_volume":
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
			asset, has_asset := object["asset"].(json.String)
			if !has_asset || asset == "" {
				log.warn("static_mesh node missing 'asset' path, skipping:", node.name.? or_else "<unnamed>")
				continue
			}
			material := MaterialId(json_f32(object["material"], 0))
			sm := new_entity(StaticMesh)
			init_static_mesh(sm, asset, material, &scene.gpu_arena, node.translation, node.rotation)
			append(&scene.entities, sm.id)
		case "heightfield":
			asset, has_asset := object["heightfield_asset"].(json.String)
			if !has_asset || asset == "" {
				log.warn("heightfield node missing generated asset, skipping:", node.name.? or_else "<unnamed>")
				continue
			}
			material := MaterialId(json_f32(object["material"], 0))
			uv_scale := json_f32(object["uv_scale"], 1.0)
			terrain := new_entity(Terrain)
			if !init_terrain(terrain, asset, material, uv_scale, &scene.gpu_arena, node.translation, node.rotation) {
				destroy_entity(terrain.id)
				log.warn("failed to initialize heightfield:", asset)
				continue
			}
			append(&scene.entities, terrain.id)		}
	}
}
