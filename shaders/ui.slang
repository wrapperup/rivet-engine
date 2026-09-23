import bindless;
import common;
import types;
import sdf;

// Naming convention:
// *_ws: World space
// *_vs: View space
// *_cs: Clip space

struct VertexInput {
    u32 vertex_id : SV_VertexID;
    u32 instance_id : SV_InstanceID;
};

[vk_push_constant]
UI_Push pc;

struct FragmentInput {
    [vk_location(0)]
    Vec4 pos_cs : SV_Position;

    [vk_location(1)]
    Vec4 color : COLOR0;

    [vk_location(2)]
    Vec2 pos;

    [vk_location(3)]
    Vec2 size;

    [vk_location(4)]
    Vec4 radius;
};

[shader("vertex")]
FragmentInput vertex_main(VertexInput in) {
    let command = pc.commands[in.instance_id];

    let left = bool(in.vertex_id & 1);
    let top = bool((in.vertex_id >> 1) & 1);

    let pos = Vec2(
        left ? command.pos.x : command.pos.x + command.size.x,
        top ? command.pos.y : command.pos.y + command.size.y
    );

    let pos_cs = Vec4(pos / pc.viewport_size * 2.0 - 1.0, 0.0, 1.0);
    let color = command.color;

    return {
        pos_cs,
        color,
        command.pos,
        command.size,
        command.radius,
    };
}

struct FragmentOutput {
    [vk_location(0)]
    Vec4 frag_color : COLOR0;
};

[shader("fragment")]
FragmentOutput fragment_main(FragmentInput in) {
    let dist = sdf_rounded_box(in.pos_cs.xy - in.pos - in.size/2.f, in.size / 2.f, in.radius); 

    let aa = max(fwidth(dist), 1e-4);
    let coverage = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, dist);

    var frag_color = saturate(in.color);
    frag_color.a *= coverage;

    return {
      frag_color,
    };
}
