//
// This is a generated file, do not modify. See src/meta.odin
//

package game

// Entity System
Entity_Kind :: enum {
    Ball,
    DDGIVolume,
    Player,
    PointLight,
    ReflectionProbe,
    SoundSource,
    StaticMesh,
    Terrain,
}

register_entity_subtypes :: proc() {
    when #defined(ball_destroy) {
        register_entity_subtype(Ball, ball_destroy)
    } else {
        register_entity_subtype(Ball)
    }
    when #defined(ddgi_volume_destroy) {
        register_entity_subtype(DDGIVolume, ddgi_volume_destroy)
    } else {
        register_entity_subtype(DDGIVolume)
    }
    when #defined(player_destroy) {
        register_entity_subtype(Player, player_destroy)
    } else {
        register_entity_subtype(Player)
    }
    when #defined(point_light_destroy) {
        register_entity_subtype(PointLight, point_light_destroy)
    } else {
        register_entity_subtype(PointLight)
    }
    when #defined(reflection_probe_destroy) {
        register_entity_subtype(ReflectionProbe, reflection_probe_destroy)
    } else {
        register_entity_subtype(ReflectionProbe)
    }
    when #defined(sound_source_destroy) {
        register_entity_subtype(SoundSource, sound_source_destroy)
    } else {
        register_entity_subtype(SoundSource)
    }
    when #defined(static_mesh_destroy) {
        register_entity_subtype(StaticMesh, static_mesh_destroy)
    } else {
        register_entity_subtype(StaticMesh)
    }
    when #defined(terrain_destroy) {
        register_entity_subtype(Terrain, terrain_destroy)
    } else {
        register_entity_subtype(Terrain)
    }
}

entity_type_to_kind :: proc($T: typeid) -> Entity_Kind {
    return .Base when T == Entity else
           .Ball when T == Ball else
           .DDGIVolume when T == DDGIVolume else
           .Player when T == Player else
           .PointLight when T == PointLight else
           .ReflectionProbe when T == ReflectionProbe else
           .SoundSource when T == SoundSource else
           .StaticMesh when T == StaticMesh else
           .Terrain when T == Terrain else
           #panic("Unregistered entity type")
}


// GPUGlobalData
#assert(offset_of(GPUGlobalData, view_to_clip) == 0)
#assert(offset_of(GPUGlobalData, world_to_view) == (offset_of(GPUGlobalData, view_to_clip) + size_of(type_of(GPUGlobalData{}.view_to_clip)) + 3) / 4 * 4)
#assert(offset_of(GPUGlobalData, clip_to_world) == (offset_of(GPUGlobalData, world_to_view) + size_of(type_of(GPUGlobalData{}.world_to_view)) + 3) / 4 * 4)
