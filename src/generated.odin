//
// This is a generated file, do not modify. See src/meta.odin
//

package game

// Entity System
Entity_Kind :: enum {
    Ball,
    DDGIVolume,
    StaticMesh,
    ReflectionProbe,
    Terrain,
    PointLight,
    Player,
    SoundSource,
}

register_entity_subtypes :: proc() {
    {
        procs: SubtypeProcs(Ball)
        procs.init = init_ball
        register_entity_subtype(Ball, procs)
    }
    {
        procs: SubtypeProcs(DDGIVolume)
        register_entity_subtype(DDGIVolume, procs)
    }
    {
        procs: SubtypeProcs(StaticMesh)
        procs.init = static_mesh_init
        procs.destroy = static_mesh_destroy
        register_entity_subtype(StaticMesh, procs)
    }
    {
        procs: SubtypeProcs(ReflectionProbe)
        procs.init = reflection_probe_init
        procs.destroy = reflection_probe_destroy
        register_entity_subtype(ReflectionProbe, procs)
    }
    {
        procs: SubtypeProcs(Terrain)
        procs.init = terrain_init
        procs.destroy = terrain_destroy
        register_entity_subtype(Terrain, procs)
    }
    {
        procs: SubtypeProcs(PointLight)
        register_entity_subtype(PointLight, procs)
    }
    {
        procs: SubtypeProcs(Player)
        register_entity_subtype(Player, procs)
    }
    {
        procs: SubtypeProcs(SoundSource)
        procs.init = init_sound_source
        procs.destroy = destroy_sound_source
        register_entity_subtype(SoundSource, procs)
    }
}

entity_type_to_kind :: proc($T: typeid) -> Entity_Kind {
    return .Base when T == Entity else
           .Ball when T == Ball else
           .DDGIVolume when T == DDGIVolume else
           .StaticMesh when T == StaticMesh else
           .ReflectionProbe when T == ReflectionProbe else
           .Terrain when T == Terrain else
           .PointLight when T == PointLight else
           .Player when T == Player else
           .SoundSource when T == SoundSource else
           #panic("Unregistered entity type")
}


// GPUGlobalData
#assert(offset_of(GPUGlobalData, view_to_clip) == 0)
#assert(offset_of(GPUGlobalData, world_to_view) == (offset_of(GPUGlobalData, view_to_clip) + size_of(type_of(GPUGlobalData{}.view_to_clip)) + 3) / 4 * 4)
#assert(offset_of(GPUGlobalData, clip_to_world) == (offset_of(GPUGlobalData, world_to_view) + size_of(type_of(GPUGlobalData{}.world_to_view)) + 3) / 4 * 4)

// GPURenderInstance
#assert(offset_of(GPURenderInstance, model_to_world) == 0)
