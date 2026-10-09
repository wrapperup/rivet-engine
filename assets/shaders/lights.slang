import atmosphere_common;
import bindless;
import common;
import standard_brdf;
import types;

// From Filament https://google.github.io/filament/Filament.md.html#listing_glslpunctuallight
f32 get_square_falloff_attenuation(Vec3 pos_to_light, f32 light_inv_radius) {
    let distance_square = dot(pos_to_light, pos_to_light);
    let factor = distance_square * light_inv_radius * light_inv_radius;
    let smooth_factor = saturate(1.0 - factor * factor);
    return (smooth_factor * smooth_factor) / max(distance_square, 1e-4);
}

Vec3 shade_sun(PBR_Surface surface, GlobalData* global, f32 shadow) {
  let light_dir = normalize(global.sun_direction);
  let NoL = saturate(dot(surface.normal, light_dir));

  let visibility = min(NoL, surface.ao) * shadow;
  let bsdf = standard_bsdf(surface.diffuse_color, surface.perceptual_roughness, surface.view_dir, light_dir, surface.normal, surface.f0, NoL);

  return visibility * atmosphere_direct_sun(global, surface.pos_ws) * bsdf;
}

Vec3 shade_point_lights(PBR_Surface surface, Slice<PointLight> point_lights) {
  Vec3 color = 0;

  for (u32 light_index = 0; light_index < point_lights.count; light_index++) {
    let light = point_lights[light_index];
    let pos_to_light = light.world_pos - surface.pos_ws;

    if (length(pos_to_light) > light.radius) {
      continue;
    }

    let light_dir = normalize(pos_to_light);
    let NoL = saturate(dot(surface.normal, light_dir));
    let bsdf = standard_bsdf(surface.diffuse_color, surface.perceptual_roughness, surface.view_dir, light_dir, surface.normal, surface.f0, NoL);
    let attenuation = get_square_falloff_attenuation(pos_to_light, 1.0 / light.radius);

    color += bsdf * light.lumens * attenuation * NoL * normalize(light.color) * surface.ao;
  }

  return color;
}
