import "../bindless";
import "../brdf";
import "../types";

// https://github.com/google/filament/blob/87249950421bb3552682185dc17c439d92805a99/libs/ibl/src/CubemapIBL.cpp#L170
float visibility(float NoV, float NoL, float a) {
    // Heitz 2014, "Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs"
    // Height-correlated GGX
    let a2 = a * a;
    let GGXL = NoV * sqrt((NoL - NoL * a2) * NoL + a2);
    let GGXV = NoL * sqrt((NoV - NoV * a2) * NoV + a2);
    return 0.5f / (GGXV + GGXL);
}


// Calculates DFG1 and DFG2 terms. If `multiscatter` is enabled, the terms for the
// multiscatter integration will be generated instead.
//
// Normal integration: https://google.github.io/filament/Filament.md.html#toc9.5
// Multiscattering integration: https://google.github.io/filament/Filament.md.html#toc5.3.4.7
float2 dfv(float NoV, float linear_roughness, int sample_count, bool multiscatter = false) {
	let V = float3(
		sqrt(1.0f - (NoV * NoV)),
		0.0f,
		NoV,
	);

	float2 r = 0.0f;
	for (uint i = 0; i < sample_count; i++) {
		float2 Xi = hammersley(i, float(sample_count));
		float3 H = hemisphere_importance_sample_ggx(Xi, linear_roughness);
		float3 L = 2.0f * dot(V, H) * H - V;

		float VoH = saturate(dot(V, H));
		float NoL = saturate(L.z);
		float NoH = saturate(H.z);

		if (NoL > 0.0f) {
			// Importance-sampling weight applied exactly once (Filament CubemapIBL DFV).
			float Gv = visibility(NoV, NoL, linear_roughness) * NoL * (VoH / NoH);
			float Fc = pow(1.0f - VoH, 5.0);

			if (multiscatter) {
				r.x += Gv * Fc;
				r.y += Gv;
			} else {
				r.x += Gv * (1.0f - Fc);
				r.y += Gv * Fc;
			}
		}
	}

	return r * (4.0f / float(sample_count));
}

// Matches DfgGeneratePassPC in src/dfg.odin (bindless storage image via ImageId).
struct DfgPushConstant {
    uint32_t sample_count;
    bool multiscatter;
    RWImage2D<float2> dfg_image;
};

[vk_push_constant] DfgPushConstant pc;

// Integrates DFG into a f16 sequence that can be stored in a texture.
// Recommended to store this in a R16G16_SFLOAT texture.
[numthreads(16, 16, 1)]
[shader("compute")]
void compute_main(uint3 dispatchThreadID: SV_DispatchThreadID) {
    let texel_coord = uint2(dispatchThreadID.xy);

    uint width;
    uint height;
    pc.dfg_image.get_dimensions(width, height);

    let x = texel_coord.x;
    let y = texel_coord.y;

    let h = float(height);
    let coord = saturate((float(y) + 0.5) / h);
    let linear_roughness = coord * coord;

    let NoV = saturate((float(x) + 0.5) / float(width));
    let r = dfv(NoV, linear_roughness, int(pc.sample_count), pc.multiscatter);

    pc.dfg_image.store(texel_coord, r);
}
