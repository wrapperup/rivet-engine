// Based on https://google.github.io/filament/Filament.md.html#materialsystem/standardmodel

import bindless;
import brdf;
import types;

Vec3 standard_bsdf(Vec3 diffuse, float p_roughness, Vec3 v, Vec3 l, Vec3 n, Vec3 f0, f32 NoL) {
    let f90 = saturate(dot(f0, Vec3(50.0 * 0.33)));
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
