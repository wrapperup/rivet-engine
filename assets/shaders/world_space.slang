import types;

Vec2 world_space_uv(Vec3 world_pos, Vec3 world_normal) {
  if (abs(world_normal.x) > 0.5f) {
    return world_pos.yz;
  } else if (abs(world_normal.y) > 0.5f) {
    return world_pos.xz;
  } else {
    return world_pos.xy;
  }
}

Vec4 world_space_tangent(Vec3 world_normal) {
  if (abs(world_normal.x) > 0.5) {
    return Vec4(0.0, 1.0, 0.0, -sign(world_normal.x));
  } else if (abs(world_normal.y) > 0.5) {
    return Vec4(1.0, 0.0, 0.0, sign(world_normal.y));
  } else {
    return Vec4(1.0, 0.0, 0.0, -sign(world_normal.z));
  }
}
