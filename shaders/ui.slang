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
    Vec4 pos_cs : SV_Position;
    Vec2 uv : TEXCOORD0;
    Vec4 color : COLOR0;
    Vec2 pos;
    Vec2 size;
    Vec4 radius;
    nointerpolation Image2D image;
    nointerpolation u32 mode;
    nointerpolation Vec2 unit_range;
    nointerpolation Vec4 outline_color;
    nointerpolation f32 outline_width;
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

    let u = left ? command.uv_min.x : command.uv_max.x;
    let v = top ? command.uv_min.y : command.uv_max.y;

    let uv = Vec2(u, v);

    return {
        pos_cs,
        uv,
        color,
        command.pos,
        command.size,
        command.radius,
        command.image,
        command.mode,
        command.unit_range,
        command.outline_color,
        command.outline_width,
    };
}

struct FragmentOutput {
    Vec4 frag_color : COLOR0;
};

Vec2 mtsdf(
    Vec4 texel,
    Vec2 uv_fwidth,
    Vec2 unit_range,
) {
    let screen_tex_size = 1.0 / max(uv_fwidth, Vec2(1e-8));
    let screen_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);

    let median = max(
        min(texel.r, texel.g),
        min(max(texel.r, texel.g), texel.b)
    );

    let sharp_distance = (median - 0.5) * screen_range;
    let round_distance = (texel.a - 0.5) * screen_range;

    let fill = saturate(sharp_distance + 0.5);
    let r = round_distance + 0.5;
    var outline = 0.0;

    return Vec2(fill, r);
}

[shader("fragment")]
FragmentOutput fragment_main(FragmentInput in) {
    let dx = ddx(in.uv);
    let dy = ddy(in.uv);

    var frag_color = saturate(in.color);

    switch (in.mode) {
    case 2: // glyph
        let texel = in.image.sample_grad(pc.sampler, in.uv, dx, dy);
        let glyph_coverage = mtsdf(texel, abs(dx) + abs(dy), in.unit_range);

        var outline = 0.0;
        if (in.outline_width > 0.0) {
            let outer = saturate(glyph_coverage.y + in.outline_width);
            outline = max(outer - glyph_coverage.x, 0.0);
        }

        let outline_color = saturate(in.outline_color);
        let fill_alpha = frag_color.a * glyph_coverage.x;
        let outline_alpha = outline_color.a * outline;
        let alpha = fill_alpha + outline_alpha;

        let rgb = (frag_color.rgb * fill_alpha + outline_color.rgb * outline_alpha)
                / max(alpha, 1e-8);

        frag_color = Vec4(rgb, alpha);
        break;

    default: // rectangle
        let dist = sdf_rounded_box(in.pos_cs.xy - in.pos - in.size/2.f, in.size / 2.f, in.radius); 

        let aa = max(fwidth(dist) + 0.5f, 1e-4);
        let coverage = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, dist);

        frag_color.a *= coverage;
        if (in.mode == 1) {
            frag_color *= in.image.sample_grad(pc.sampler, in.uv, dx, dy);
        }
        break;
    }

    return {
      frag_color,
    };
}
