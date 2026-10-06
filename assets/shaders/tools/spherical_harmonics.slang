import common;

// Explanation: https://www.rorydriscoll.com/2012/01/15/cubemap-texel-solid-angle/
float solid_angle(float au, float av, float size) {
    //scale up to [-1, 1] range (inclusive), offset by 0.5 to point to texel center.
    let u = (2.0 * (au + 0.5) / size) - 1.0;
    let v = (2.0 * (av + 0.5) / size) - 1.0;

    let inv_size = 1.0 / size;

    // U and V are the -1..1 texture coordinate on the current face.
    // get projected area for this texel
    let x0 = u - inv_size;
    let y0 = v - inv_size;
    let x1 = u + inv_size;
    let y1 = v + inv_size;
    let angle =
        area_element(x0, y0) - area_element(x0, y1) - area_element(x1, y0) + area_element(x1, y1);

    return angle;
}

float area_element(float x, float y) {
    return atan2(x * y, sqrt(x * x + y * y + 1.0));
}

[vk_binding(0, 0)] SamplerCube EnvironmentMap; // Use nearest sampling.

struct PushConstants {
    float3* sh;
};

[vk_push_constant] PushConstants pc;

[numthreads(1, 1, 1)]
[shader("compute")]
void compute_main(uint3 dispatchThreadID: SV_DispatchThreadID) {
    uint2 size;
    uint levels;
    EnvironmentMap.GetDimensions(0, size.x, size.y, levels);

    // Forsyth's weights
    let weight1 = 4.0 / 17.0;
    let weight2 = 8.0 / 17.0;
    let weight3 = 15.0 / 17.0;
    let weight4 = 5.0 / 68.0;
    let weight5 = 15.0 / 68.0;

    pc.sh[0] = float3(0, 0, 0);
    pc.sh[1] = float3(0, 0, 0);
    pc.sh[2] = float3(0, 0, 0);
    pc.sh[3] = float3(0, 0, 0);
    pc.sh[4] = float3(0, 0, 0);
    pc.sh[5] = float3(0, 0, 0);
    pc.sh[6] = float3(0, 0, 0);
    pc.sh[7] = float3(0, 0, 0);
    pc.sh[8] = float3(0, 0, 0);

    float weight_accum = 0.0;

    for (uint i = 0; i < 6; i++) {
        for (uint y = 0; y < size.y; y++) {
            for (uint x = 0; x < size.x; x++) {
                uint3 tex_coord = uint3(x, size.y - y, i);
                let v = get_world_direction(tex_coord, size.x);

                float3 color = EnvironmentMap.SampleLevel(v, 0).rgb;

                let weight = solid_angle(float(x), float(y), float(size.x));

                color *= weight;

                pc.sh[0] += color * weight1;

                pc.sh[1] += color * weight2 * v.x;
                pc.sh[2] += color * weight2 * v.y;
                pc.sh[3] += color * weight2 * v.z;

                pc.sh[4] += color * weight3 * v.x * v.z;
                pc.sh[5] += color * weight3 * v.z * v.y;
                pc.sh[6] += color * weight3 * v.y * v.x;
                pc.sh[7] += color * weight4 * (3.0 * v.z * v.z - 1.0);
                pc.sh[8] += color * weight5 * (v.x * v.x - v.y * v.y);

                weight_accum += weight * 3.0;
            }
        }
    }

    for (uint i = 0; i < 9; i++) {
        #define PI 3.14159265359
        pc.sh[i] *= 4.0 * PI / weight_accum;
    }
}
