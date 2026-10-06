import bindless;
import common;
import consts;
import types;

// Naming convention:
// *_ws: World space
// *_vs: View space
// *_cs: Clip space

struct FontInstance {
    Vec2 pos_min;
    Vec2 pos_max;
    Vec2 uv_min;
    Vec2 uv_max;
    Vec4 color;
}

struct DrawPushConstants {
    Tex2D<u8> atlas;
    Sampler sampler;
    FontInstance *instances;
};

struct VertexInput {
    u32 vertex_id : SV_VertexID;
    u32 instance_id : SV_InstanceID;
};

[vk_push_constant]
DrawPushConstants pc;

struct FragmentInput {
    [vk_location(0)]
    Vec4 pos_cs : SV_Position;

    [vk_location(1)]
    Vec4 color : COLOR0;

    [vk_location(2)]
    Vec2 uv;
};

[shader("vertex")]
FragmentInput vertex_main(VertexInput in) {
    let inst = pc.instances[in.instance_id];

    // Note: we could change the quad definition to use offset+size instead for both position and UVs instead of the bit hacks.
    let left = bool(in.vertex_id & 1);
    let bottom = bool((in.vertex_id >> 1) & 1);

    let pos = Vec2(left ? inst.pos_min.x : inst.pos_max.x, bottom ? inst.pos_min.y : inst.pos_max.y);
    let uv = Vec2(left ? inst.uv_min.x : inst.uv_max.x, bottom ? inst.uv_min.y : inst.uv_max.y);

    let pos_cs = Vec4(pos, 0.0, 1.0);
    let color = inst.color;

    return {
        pos_cs,
        color,
        uv,
    };
}

struct FragmentOutput {
    [vk_location(0)]
    Vec4 frag_color : COLOR0;
};

[shader("fragment")]
FragmentOutput fragment_main(FragmentInput in) {
    let frag_color = saturate(in.color * Vec4(pc.atlas.sample(pc.sampler, in.uv).r));

    return {
      frag_color,
    };
}
