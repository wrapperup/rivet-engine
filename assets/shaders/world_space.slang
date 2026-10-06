import types;

Vec2 get_world_space_uv(Vec3 world_pos, Vec3 world_normal) {
  if (abs(world_normal.x) > 0.5f) {
    return world_pos.yz;
  } else if (abs(world_normal.y) > 0.5f) {
    return world_pos.xz;
  } else {
    return world_pos.xy;
  }
}

Vec4 get_world_space_tangent(Vec3 world_normal) {
  if (abs(world_normal.x) > 0.5f) {
    return Vec4(0.f, 1.f, 0.f, sign(world_normal.x));
  } else if (abs(world_normal.y) > 0.5f) {
    return Vec4(1.f, 0.f, 0.f, -sign(world_normal.y));
  } else {
    return Vec4(1.f, 0.f, 0.f, sign(world_normal.z));
  }
}
