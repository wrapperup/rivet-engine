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
    return params.dfg.sample(params.env_sampler, Vec2(NoV, p_roughness)).rgb;
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

// Reflection probes

f32 reflection_probe_weight(ReflectionProbe probe, Vec3 pos_ws) {
    let d = abs(pos_ws - probe.center) - probe.half_extents;
    let outside = max(max(d.x, d.y), d.z);
    return saturate(-outside / max(probe.blend_distance, 1e-4));
}

Vec3 reflection_probe_parallax_dir(ReflectionProbe probe, Vec3 pos_ws, Vec3 r) {
    let t1 = (probe.center - probe.half_extents - pos_ws) / r;
    let t2 = (probe.center + probe.half_extents - pos_ws) / r;
    let tfar = min(min(max(t1.x, t2.x), max(t1.y, t2.y)), max(t1.z, t2.z));
    return tfar > 1e-3 ? normalize(pos_ws + r * tfar - probe.center) : r;
}

Vec3 sample_reflection_probes(GlobalData* gd, Vec3 pos_ws, Vec3 r, f32 p_roughness) {
    Vec3 probe_sum = Vec3(0.0);
    float probe_wsum = 0.0;

    let probe_count = gd.num_reflection_probes;
    for (uint pi = 0; pi < probe_count; pi++) {
        let probe = gd.reflection_probes[pi];

        let w = reflection_probe_weight(probe, pos_ws);
        if (w <= 0.0) {
            continue; // point not inside this probe's volume -> skip the expensive sample
        }

        let contrib = min(w, 1.0 - probe_wsum);
        let pdir = reflection_probe_parallax_dir(probe, pos_ws, r);
        let lod = p_roughness * float(probe.mip_count - 1);
        probe_sum += probe.cube.sample_level(probe.sampler, pdir, lod).rgb * probe.intensity * contrib;
        probe_wsum += contrib;

        if (probe_wsum >= 1.0) {
            break;
        }
    }

    if (probe_wsum >= 1.0) {
        return probe_sum / probe_wsum;
    }

    PBR_Params ibl;
    ibl.env_map = gd.environment.env_map;
    ibl.dfg = gd.environment.dfg;
    ibl.env_sampler = gd.environment.env_sampler;
    ibl.default_sampler = gd.default_sampler;
    Vec3 env_refl = gd.sky_color * evaluate_specular_ibl(ibl, r, p_roughness);
    return probe_wsum > 0.0 ? lerp(env_refl, probe_sum / probe_wsum, probe_wsum) : env_refl;
}
