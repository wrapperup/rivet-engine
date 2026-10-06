import types;

// From Filament https://google.github.io/filament/Filament.md.html#listing_glslpunctuallight
f32 get_square_falloff_attenuation(Vec3 pos_to_light, f32 light_inv_radius) {
    let distance_square = dot(pos_to_light, pos_to_light);
    let factor = distance_square * light_inv_radius * light_inv_radius;
    let smooth_factor = saturate(1.0 - factor * factor);
    return (smooth_factor * smooth_factor) / max(distance_square, 1e-4);
}
