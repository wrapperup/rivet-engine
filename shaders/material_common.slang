import types;
import world_space;

Vec3 material_base_color(Vec3 sampled_color, Vec3 vertex_color) {
  return sampled_color * vertex_color;
}

Vec3 material_normal(Vec3 sampled_normal, Mat3x3 tbn) {
  var normal = sampled_normal * 2.0 - 1.0;
  normal.y *= -1;
  return normalize(mul(normal, tbn));
}
