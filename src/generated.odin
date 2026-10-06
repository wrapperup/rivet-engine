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
    {
        procs: SubtypeProcs(Ball)
        when #defined(ball_init) do procs.init = ball_init
        when #defined(ball_destroy) do procs.destroy = ball_destroy
        register_entity_subtype(Ball, procs)
    }
    {
        procs: SubtypeProcs(DDGIVolume)
        when #defined(ddgi_volume_init) do procs.init = ddgi_volume_init
        when #defined(ddgi_volume_destroy) do procs.destroy = ddgi_volume_destroy
        register_entity_subtype(DDGIVolume, procs)
    }
    {
        procs: SubtypeProcs(Player)
        when #defined(player_init) do procs.init = player_init
        when #defined(player_destroy) do procs.destroy = player_destroy
        register_entity_subtype(Player, procs)
    }
    {
        procs: SubtypeProcs(PointLight)
        when #defined(point_light_init) do procs.init = point_light_init
        when #defined(point_light_destroy) do procs.destroy = point_light_destroy
        register_entity_subtype(PointLight, procs)
    }
    {
        procs: SubtypeProcs(ReflectionProbe)
        when #defined(reflection_probe_init) do procs.init = reflection_probe_init
        when #defined(reflection_probe_destroy) do procs.destroy = reflection_probe_destroy
        register_entity_subtype(ReflectionProbe, procs)
    }
    {
        procs: SubtypeProcs(SoundSource)
        when #defined(sound_source_init) do procs.init = sound_source_init
        when #defined(sound_source_destroy) do procs.destroy = sound_source_destroy
        register_entity_subtype(SoundSource, procs)
    }
    {
        procs: SubtypeProcs(StaticMesh)
        when #defined(static_mesh_init) do procs.init = static_mesh_init
        when #defined(static_mesh_destroy) do procs.destroy = static_mesh_destroy
        register_entity_subtype(StaticMesh, procs)
    }
    {
        procs: SubtypeProcs(Terrain)
        when #defined(terrain_init) do procs.init = terrain_init
        when #defined(terrain_destroy) do procs.destroy = terrain_destroy
        register_entity_subtype(Terrain, procs)
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

// GPURenderInstance
#assert(offset_of(GPURenderInstance, model_to_world) == 0)
