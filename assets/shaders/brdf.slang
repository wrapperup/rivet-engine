import types;

static const f32 PI = 3.14159265359;

f32 D_ggx(f32 NoH, f32 a) {
    let a2 = a * a;
    let f = (NoH * a2 - NoH) * NoH + 1.0;
    return a2 / (PI * f * f);
}

Vec3 F_schlick(const Vec3 f0, Vec3 f90, f32 VoH) {
    return f0 + (f90 - f0) * pow(1.0 - VoH, 5.0);
}

f32 V_smith_ggx_correlated(f32 NoV, f32 NoL, f32 a) {
    let a2 = a * a;
    let GGXL = NoV * sqrt((-NoL * a2 + NoL) * NoL + a2);
    let GGXV = NoL * sqrt((-NoV * a2 + NoV) * NoV + a2);
    return 0.5 / (GGXV + GGXL);
}

f32 Fd_lambert() {
    return 1.0 / PI;
}

// https://google.github.io/filament/Filament.md.html#toc9.4
Vec2 hammersley(u32 i, f32 numSamples) {
	u32 bits = i;
	bits = (bits << 16) | (bits >> 16);
	bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
	bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
	bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
	bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
	return Vec2(i / numSamples, bits / pow(2.f,32.f));
}

Vec3 hemisphere_importance_sample_ggx(Vec2 u, f32 a) {
	let phi = 2.0 * float(PI) * u.x;
	// NOTE: (aa-1) == (a-1)(a+1) produces better fp accuracy
	let cosTheta2 = (1 - u.y) / (1 + (a + 1) * ((a - 1) * u.y));
	let cosTheta = sqrt(cosTheta2);
	let sinTheta = sqrt(1 - cosTheta2);
	return Vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

f32 distribution_ggx(f32 NoH, f32 p_roughness) {
    // NOTE: (aa-1) == (a-1)(a+1) produces better fp accuracy
    let a = p_roughness * p_roughness;
    let f = (a - 1) * ((a + 1) * (NoH * NoH)) + 1;
    return (a * a) / ((float) PI * f * f);
}

// GGX NDF via importance sampling
Vec3 importance_sample_ggx(Vec2 Xi, Vec3 N, f32 roughness)
{
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
	
    let phi = 2.0 * PI * Xi.x;
    let cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (alpha2 - 1.0) * Xi.y));
    let sinTheta = sqrt(1.0 - cosTheta * cosTheta);
	
    // from spherical coordinates to cartesian coordinates
    Vec3 H;
    H.x = cos(phi) * sinTheta;
    H.y = sin(phi) * sinTheta;
    H.z = cosTheta;
	
    // from tangent-space vector to world-space sample vector
    Vec3 up        = abs(N.z) < 0.999 ? Vec3(0.0, 0.0, 1.0) : Vec3(1.0, 0.0, 0.0);
    Vec3 tangent   = normalize(cross(up, N));
    Vec3 bitangent = cross(N, tangent);
	
    Vec3 sampleVec = tangent * H.x + bitangent * H.y + N * H.z;
    return normalize(sampleVec);
}
