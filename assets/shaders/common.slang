import bindless;
import types;
typealias MaterialId = u32;

#include "generated.slang"

Vec3 srgb_to_linear(Vec3 color) { return pow(color, 2.2); }
Vec3 linear_to_srgb(Vec3 color) { return pow(color, 1.0 / 2.2); }
