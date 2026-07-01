import bindless;
import brdf;
import common;
import ddgi_common;
import ibl;
import lights;
import shadows;
import standard_brdf;
import types;
import world_space;

// Naming convention:
// *_ws: World space
// *_vs: View space
// *_cs: Clip space

static const Mat4x4 BIAS_MAT = {
  0.5, 0.0, 0.0, 0.5, //
  0.0, 0.5, 0.0, 0.5, //
  0.0, 0.0, 1.0, 0.0, //
  0.0, 0.0, 0.0, 1.0, //
};

[vk_push_constant]
DrawPushConstants pc;

struct VertexInput {
  u32 vertex_index : SV_VertexID;
};

[shader("vertex")]
FragmentInput vertex_main(VertexInput input) {
  let vertex = pc.vertex_buffer[input.vertex_index];

  let model_to_world = pc.model_matrices[pc.model_index];

  let pos_ws = mul(model_to_world, Vec4(vertex.position, 1.0));
  let uv = Vec2(vertex.uv_x, vertex.uv_y);

  let N = normalize(mul((Mat3x3)model_to_world, -vertex.normal));
  var tangent = vertex.tangent;
  if (pc.material_index == 0) {
    tangent = get_world_space_tangent(N);
  }

  let T = normalize(mul((Mat3x3)model_to_world, tangent.xyz));
  let B = cross(N, T) * tangent.w;

  let world_to_clip = mul(pc.global_data_buffer.view_to_clip,
                                   pc.global_data_buffer.world_to_view);

  FragmentInput output;
  output.color = vertex.color.rgb;
  output.pos_cs = mul(world_to_clip, pos_ws);
  output.uv = uv;
  output.pos_ws = pos_ws;
  output.pos_vs = mul(pc.global_data_buffer.world_to_view, pos_ws);
  output.tbn = Mat3x3(T, B, N);

  return output;
}

struct FragmentInput {
  Vec4 pos_cs : SV_Position;
  Vec3 color : COLOR0;
  Vec2 uv : TEXCOORD0;
  Vec4 pos_ws;
  Vec4 pos_vs;
  Mat3x3 tbn;
  u32 tex_id;
};

struct FragmentOutput {
  [vk_location(0)]
  Vec4 frag_color : COLOR0;
};

[shader("fragment")]
FragmentOutput fragment_main(FragmentInput in) {
  let pos_ws = in.pos_ws.xyz;
  let camera_pos_ws = pc.global_data_buffer.camera_pos;

  let material = pc.materials[pc.material_index];

  Vec2 uv = in.uv;
  // uv = 0;
  if (pc.material_index == 0) {
    uv = get_world_space_uv(pos_ws, in.tbn[2]) / 4.f;
  }

  Vec3 normal =
      material.normal_map_id.sample(pc.global_data_buffer.default_sampler, uv).rgb * 2.0 - 1.0;
  normal.y *= -1;
  normal = mul(normal, in.tbn); // Note: Matrices constructed in Slang/HLSL are row-major by default...
  normal = normalize(normal);

  Vec3 base_color =
      material.base_color_id.sample(pc.global_data_buffer.default_sampler, uv).xyz * in.color;

  f32 reflectance = 0.5f;

  let ao_roughness_metallic =
      material.ao_roughness_metallic_id.sample(pc.global_data_buffer.default_sampler, uv).rgb;

  let ao_roughness_metallic_srgb = linear_to_srgb(ao_roughness_metallic);

  let ao = ao_roughness_metallic.r;
  // let ao = 1.f;
  let proughness = ao_roughness_metallic_srgb.g;
  let metallic = ao_roughness_metallic_srgb.b;

  Vec3 f0 = 0.16 * reflectance * reflectance * (1.0 - metallic) +
            base_color * metallic;

  Vec3 diffuse = (1.0 - metallic) * base_color.rgb;

  Vec3 n = normal;
  Vec3 v = normalize(camera_pos_ws - pos_ws);
  Vec3 l = normalize(pc.global_data_buffer.sun_direction); // Directional light

  f32 sun_NoL = clamp(dot(n, l), 0.0, 1.0);

  u32 cascade_index = 0;

  float blend_factor = 0.f;
  let blend_dist = 10.f;

  for (uint i = 0; i < pc.num_cascades; i++) {
    let split_dist = pc.global_data_buffer.cascade_configs[i].split_dist;
    if (in.pos_vs.z < -split_dist) {
      cascade_index = i + 1;
      blend_factor = saturate((in.pos_vs.z + split_dist) / blend_dist);
    }
  }

  let world_to_shadow = pc.global_data_buffer.cascade_world_to_shadows[cascade_index];
  let shadow_space_pos = mul(BIAS_MAT, mul(world_to_shadow, in.pos_ws));

  let bias = pc.global_data_buffer.cascade_configs[cascade_index].bias;
  let slope_bias = pc.global_data_buffer.cascade_configs[cascade_index].slope_bias;

  Shadow_Params shadow_params;
  shadow_params.depth = pc.shadow_depth;
  shadow_params.sampler = pc.shadow_sampler;

  let shadow = filter_pcf(shadow_params, in.pos_cs.xy, shadow_space_pos, cascade_index, bias, slope_bias, sun_NoL);

  Vec3 frag_color = 0;
  frag_color = saturate( (min(sun_NoL, min(shadow, ao)) * pc.global_data_buffer.sun_color) *
      standard_bsdf(diffuse, proughness, v, l, n, f0, sun_NoL));

  for (uint i = 0; i < pc.global_data_buffer.environment.num_point_lights; i++) {
    let point_light = pc.global_data_buffer.environment.point_lights[i];

    let light_pos_ws = point_light.world_pos;
    let radius = point_light.radius;
    let lumens = point_light.lumens;
    let color = normalize(point_light.color);
    let dist = distance(pos_ws, light_pos_ws);

    if (dist <= radius) {
      let pos_to_light = light_pos_ws - pos_ws;
      let point_light_l = normalize(pos_to_light);
      let point_light_h = normalize(v + point_light_l);
      let point_light_NoL = clamp(dot(n, point_light_l), 0.0, 1.0);

      let bsdf = standard_bsdf(diffuse, proughness, v, point_light_l, n, f0,
                               point_light_NoL);
      let attenuation =
          get_square_falloff_attenuation(pos_to_light, 1.f / radius);

      frag_color +=
          (bsdf * lumens * attenuation * point_light_NoL) * color * ao;
    }
  }

  // DDGI diffuse indirect (replaces the static SH/IBL ambient).
  let dv = pc.global_data_buffer.ddgi;
  frag_color += diffuse * ao * dv.intensity * ddgi_sample(dv, pos_ws, n);

  // Specular reflections. The split-sum BRDF (DFG) weighting is shared; the reflected
  // *radiance* comes from the reflection probe (box-parallax + edge blend) where one
  // influences this pixel, else the global environment map. Diffuse comes from DDGI above.
  let env = pc.global_data_buffer.environment;
  PBR_Params ibl_params;
  ibl_params.env_map = env.env_map;
  ibl_params.dfg = env.dfg;
  ibl_params.env_sampler = env.env_sampler;
  ibl_params.default_sampler = pc.global_data_buffer.default_sampler;

  let NoV = max(dot(n, v), 0.0);
  let r = reflect(-v, n);
  let f90 = saturate(dot(f0, Vec3(50.0 * 0.33)));
  let dfg = sample_dfg(ibl_params, NoV, proughness).rg;
  let spec_brdf = f0 * dfg.r + f90 * dfg.g;

  // Blend every reflection probe that influences this pixel. Perf: the box/edge weight is a
  // cheap reject computed BEFORE any cube fetch, so cost scales with probe *overlap* at this
  // pixel, not the total probe count. Loop bound is uniform (coherent across the warp).
  Vec3 probe_sum = Vec3(0.0);
  float probe_wsum = 0.0;
  let probe_count = pc.global_data_buffer.num_reflection_probes;
  for (uint pi = 0; pi < probe_count; pi++) {
    let probe = pc.global_data_buffer.reflection_probes[pi];

    // Cheap influence test (no texture access): 1 inside, fading over blend_distance at bounds.
    let d = abs(pos_ws - probe.center) - probe.half_extents;
    let outside = max(max(d.x, d.y), d.z);
    let w = saturate(-outside / max(probe.blend_distance, 1e-4));
    if (w <= 0.0) {
      continue; // pixel not inside this probe's volume -> skip the expensive sample
    }

    // Box parallax (only for influencing probes), with the close-to-wall guard.
    let t1 = (probe.center - probe.half_extents - pos_ws) / r;
    let t2 = (probe.center + probe.half_extents - pos_ws) / r;
    let tfar = min(min(max(t1.x, t2.x), max(t1.y, t2.y)), max(t1.z, t2.z));
    let pdir = tfar > 1e-3 ? normalize(pos_ws + r * tfar - probe.center) : r;
    let lod = proughness * float(probe.mip_count - 1);

    probe_sum += probe.cube.sample_level(probe.sampler, pdir, lod).rgb * probe.intensity * w;
    probe_wsum += w;

    if (probe_wsum >= 1.0) {
      break; // fully covered -> no need to keep sampling more probes
    }
  }

  // Only fetch the distant env map where probe coverage is incomplete (saves a cube fetch on
  // fully-covered pixels). Probes are weighted-averaged; env fills the remainder.
  Vec3 refl;
  if (probe_wsum >= 1.0) {
    refl = probe_sum / probe_wsum;
  } else {
    Vec3 env_refl = pc.global_data_buffer.sky_color * evaluate_specular_ibl(ibl_params, r, proughness);
    refl = probe_wsum > 0.0 ? lerp(env_refl, probe_sum / probe_wsum, probe_wsum) : env_refl;
  }

  frag_color += spec_brdf * refl * ao;

  // DEBUG
  // frag_color = base_color;
  // frag_color = 1;
  // let r = reflect(-v, n);
  // frag_color = ENVIRONMENT_MAP_ID.sample_level(ENVIRONMENT_SAMPLER_ID, r,
  // 0).rgb; frag_color =
  // ENVIRONMENT_MAP_ID.sample_level(ENVIRONMENT_SAMPLER_ID, n, 0).rgb;
  // frag_color = evaluate_specular_ibl(r, proughness);
  // frag_color = irradiance_sh(n,
  // pc.global_data_buffer.environment.sh_volume[0]); frag_color = saturate(n);
  // frag_color = saturate(i.tbn[0]); // Tangent
  // frag_color = saturate(i.tbn[1]); // Bitangent
  // frag_color = saturate(i.tbn[2]); // Normal
  // frag_color = saturate(world_pos.xyz);
  // frag_color = Vec3(saturate(in.pos.xyz/1920.f));

  FragmentOutput output;
  output.frag_color = Vec4(frag_color, 1.0f);

  return output;
}
