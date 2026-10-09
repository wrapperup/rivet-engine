import bindless;
import types;
typealias MaterialId = u32;

#include "generated.slang"

Vec3 srgb_to_linear(Vec3 color) { return pow(color, 2.2); }
Vec3 linear_to_srgb(Vec3 color) { return pow(color, 1.0 / 2.2); }

Vec3 transform_normal(Mat3x3 transform, Vec3 normal) {
  let column_x = mul(transform, Vec3(1, 0, 0));
  let column_y = mul(transform, Vec3(0, 1, 0));
  let column_z = mul(transform, Vec3(0, 0, 1));

  let transformed = cross(column_y, column_z) * normal.x +
                    cross(column_z, column_x) * normal.y +
                    cross(column_x, column_y) * normal.z;
  let det_sign = dot(column_x, cross(column_y, column_z)) < 0 ? -1.0 : 1.0;

  return normalize(transformed) * det_sign;
}

Vec3 tangent_to_world(Vec3 vector_ts, Vec3 tangent, Vec3 bitangent, Vec3 normal) {
  return vector_ts.x * tangent + vector_ts.y * bitangent + vector_ts.z * normal;
}

// BC5 decode
Vec3 decode_normal_map(Vec2 encoded) {
  let xy = encoded * 2.0 - 1.0;
  return Vec3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
}
