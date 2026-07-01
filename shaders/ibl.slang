import bindless;
import brdf;
import common;
import types;

struct PBR_Params {
    ImageCube env_map;
    Image2D dfg;
    Sampler env_sampler;
    Sampler default_sampler;
}

Vec3 evaluate_specular_ibl(PBR_Params params, Vec3 r, f32 perceptualRoughness) {
    // This assumes a 256x256 cubemap, with 9 mip levels
    let lod = 8.0 * perceptualRoughness;
    return params.env_map.sample_level(params.env_sampler, r, lod).rgb;
}

Vec3 sample_dfg(PBR_Params params, f32 NoV, f32 p_roughness) {
    let linear_roughness = p_roughness * p_roughness;
    return params.dfg.sample(params.default_sampler, Vec2(NoV, linear_roughness)).rgb;
}

Vec3 evaluate_specular_ibl_term(PBR_Params params, Vec3 n, Vec3 v, Vec3 f0, f32 p_roughness) {
    let f90 = saturate(dot(f0, Vec3(50.0 * 0.33)));
    let NoV = max(dot(n, v), 0.0);
    let r = reflect(-v, n);

    let Lld = evaluate_specular_ibl(params, r, p_roughness);
    let Ldfg = sample_dfg(params, NoV, p_roughness).rg;

    return (f0 * Ldfg.r + f90 * Ldfg.g) * Lld;
}

Vec3 evaluate_ibl(PBR_Params params, Vec3 n, Vec3 v, Vec3 diffuse_color, Vec3 f0, f32 p_roughness) {
    let NoV = max(dot(n, v), 0.0);

    let Lr = evaluate_specular_ibl_term(params, n, v, f0, p_roughness);
    let Ld = diffuse_color;

    return Lr + Ld;
}
