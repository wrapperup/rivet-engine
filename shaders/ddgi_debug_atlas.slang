// DDGI, derived from:
//
// [2019] Majercik, Guertin, Nowrouzezahrai, McGuire. "Dynamic Diffuse Global Illumination with Ray-Traced
//        Irradiance Fields". JCGT 8(2), 2019. https://jcgt.org/published/0008/02/01/
// [2021] Majercik, Marrs, Spjut, McGuire. "Scaling Probe-Based Real-Time Dynamic Global Illumination for
//        Production". JCGT 10(2), 2021. https://jcgt.org/published/0010/02/01/
//
// Source code: [2021] supplement.zip (https://jcgt.org/published/0010/02/01/supplement.zip)

import bindless;
import common;
import types;
import ddgi_common;

[vk_push_constant]
DDGIDebugAtlasPush pc;

[numthreads(16, 16, 1)]
[shader("compute")]
void compute_main(Vec3u32 dispatchThreadID: SV_DispatchThreadID) {
  let px = Vec2u32(dispatchThreadID.xy);
  uint2 size;
  pc.out_image.get_dimensions(size.x, size.y);
  if (px.x >= size.x || px.y >= size.y) {
    return;
  }

  let v = pc.volume;
  let uv = (Vec2(px) + 0.5) / Vec2(size);
  // Probes store irradiance gamma encoded (ddgi_update.slang).
  let c = pow(v.irradiance.sample_level(v.sampler, uv, 0).rgb, Vec3(DDGI_IRRADIANCE_GAMMA));

  let mapped = c / (c + 1.0);
  pc.out_image.store(px, Vec4(pow(mapped, Vec3(1.0 / 2.2)), 1.0));
}
