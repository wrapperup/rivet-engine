import common;
import types;

f32 sdf_rounded_box(Vec2 pos, Vec2 size, f32 radius) {
    let q = abs(pos) - size + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}
