// Based on https://google.github.io/filament/Filament.md.html#materialsystem/standardmodel

import bindless;
import brdf;
import types;

// https://google.github.io/filament/Filament.md.html#materialsystem/parameterization
static const f32 DEFAULT_REFLECTANCE = 0.5;

Vec3 fresnel_0(Vec3 base_color, f32 metallic, f32 reflectance) {
  let dielectric_f0 = 0.16 * reflectance * reflectance;
  return dielectric_f0 * (1.0 - metallic) + base_color * metallic;
}

// https://google.github.io/filament/Filament.md.html#lighting/occlusion/specularocclusion
f32 fresnel_90(Vec3 f0) {
  return saturate(50.0 * dot(f0, Vec3(0.33)));
}

struct PBR_Surface {
  Vec3 pos_ws;
  Vec3 view_dir;
  Vec3 geometric_normal;
  Vec3 tangent;
  Vec3 bitangent;
  Vec3 normal;
  Vec3 base_color;
  Vec3 diffuse_color;
  Vec3 f0;
  f32 perceptual_roughness;
  f32 ao;
};

Vec3 standard_bsdf(Vec3 diffuse, float p_roughness, Vec3 v, Vec3 l, Vec3 n, Vec3 f0, f32 NoL) {
    let f90 = fresnel_90(f0);
    let h = normalize(v + l);

    let NoV = abs(dot(n, v)) + 1e-5;
    let NoH = clamp(dot(n, h), 0.0, 1.0);
    let LoH = clamp(dot(l, h), 0.0, 1.0);
    let VoH = clamp(dot(v, h), 0.0, 1.0);

    let l_roughness = p_roughness * p_roughness;

    let D = D_ggx(NoH, l_roughness);
    let F = F_schlick(f0, f90, VoH);
    // TODO: FIX: Why do I need to saturate this?
    let V = saturate(V_smith_ggx_correlated(NoV, NoL, l_roughness));

    // specular BRDF
    let Fr = (D * V) * F;

    // diffuse BRDF
    let Fd = diffuse * Fd_lambert();

    // let dfg = sample_dfg(NoV, l_roughness);
    // let energyCompensation = 1.0 + f0 * (1.0 / dfg.g - 1.0);
    // Fr *= energyCompensation;

    // apply lighting...
    return Fd + Fr;
}
