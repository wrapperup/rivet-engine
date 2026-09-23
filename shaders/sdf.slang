import common;
import types;

// adapted from https://iquilezles.org/articles/distfunctions2d/

f32 sdf_rounded_box(Vec2 pos, Vec2 size, Vec4 radius) {
    // clockwise winding
    radius.xy = (pos.y > 0.0) ? radius.wz : radius.xy;
    radius.x  = (pos.x > 0.0) ? radius.y  : radius.x;

    Vec2 q = abs(pos) - size + radius.x;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius.x;
}
