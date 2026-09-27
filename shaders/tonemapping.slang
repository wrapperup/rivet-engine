import bindless;
import common;
import types;

Vec3 tony_mc_mapface(Vec3 stimulus) {
  // Apply a non-linear transform that the LUT is encoded with.
  const Vec3 encoded = stimulus / (stimulus + 1.0);

  // Align the encoded range to texel centers.
  const f32 LUT_DIMS = 48.0;
  Vec3 uv = encoded * ((LUT_DIMS - 1.0) / LUT_DIMS) + 0.5 / LUT_DIMS;

  // Note: for OpenGL, do `uv.y = 1.0 - uv.y`
  return pc.tony_mc_mapface.sample_level(pc.sampler, uv, 0);
}

/* Gradient noise from Jorge Jimenez's presentation: */
/* http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare */
f32 gradient_noise(Vec2 pixel) {
  return frac(52.9829189 * frac(dot(pixel, Vec2(0.06711056, 0.00583715))));
}

[vk_push_constant]
PostProcessingPushConstants pc;

[numthreads(16, 16, 1)]
[shader("compute")]
void compute_main(Vec3u32 dispatchThreadID: SV_DispatchThreadID) {
  let texel_coord = Vec2u32(dispatchThreadID.xy);

  uint2 size;
  pc.resolved_image.get_dimensions(size.x, size.y);

  let exposure = 3.0f;
  if (texel_coord.x < size.x && texel_coord.y < size.y) {
    let hdr_color = pc.resolved_image.load(texel_coord).rgb * exposure;
    let mapped = tony_mc_mapface(hdr_color);

    let encoded = pow(max(mapped, Vec3(0.0)), Vec3(1.0 / 2.2));
    let dithered = encoded + ((2.0 / 255.0) * gradient_noise(texel_coord) - (1.0 / 255.0));

    pc.resolved_image.store(texel_coord, Vec4(dithered, 1.0));
  }
}
