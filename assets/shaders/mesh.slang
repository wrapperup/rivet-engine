import bindless;
import atmosphere_common;
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

[vk_push_constant]
DrawPushConstants pc;

struct VertexInput {
  u32 vertex_index : SV_VertexID;
};

[shader("vertex")]
FragmentInput vertex_main(VertexInput input) {
  let global = pc.global_data_buffer;
  let instance = pc.instances[pc.instance_index];
  let vertex = instance.vertex_buffer[input.vertex_index];
  let material = pc.materials[instance.material_index];

  let model_to_world = (Mat3x3)instance.model_to_world;
  let pos_ws = mul(instance.model_to_world, Vec4(vertex.position, 1.0));
  let pos_vs = mul(global.world_to_view, pos_ws);
  let normal_ws = transform_normal(model_to_world, vertex.normal);

  Vec4 tangent_ws;
  if (material.flags & Material_Flags.Temp_World_Space) {
    tangent_ws = world_space_tangent(normal_ws);
  } else {
    tangent_ws = Vec4(normalize(mul(model_to_world, vertex.tangent.xyz)), vertex.tangent.w);
  }

  FragmentInput output;
  output.color = vertex.color.rgb;
  output.pos_cs = mul(global.view_to_clip, pos_vs);
  output.uv = Vec2(vertex.uv_x, vertex.uv_y);
  output.pos_ws = pos_ws.xyz;
  output.view_depth = pos_vs.z;
  output.normal_ws = normal_ws;
  output.tangent_ws = tangent_ws;
  return output;
}

struct FragmentInput {
  Vec4 pos_cs : SV_Position;
  Vec3 color : COLOR0;
  Vec2 uv : TEXCOORD0;
  Vec3 pos_ws;
  f32 view_depth;
  Vec3 normal_ws;
  Vec4 tangent_ws;
};

struct FragmentOutput {
  [vk_location(0)]
  Vec4 frag_color : COLOR0;
};

PBR_Surface pbr_surface_from_material(FragmentInput in, Material material, GlobalData* global) {
  PBR_Surface surface;
  surface.pos_ws = in.pos_ws;
  surface.view_dir = normalize(global.camera_pos - in.pos_ws);
  surface.geometric_normal = normalize(in.normal_ws);
  surface.tangent = in.tangent_ws.xyz;
  surface.bitangent = cross(surface.geometric_normal, surface.tangent) * in.tangent_ws.w;

  var uv = in.uv;
  if (material.flags & Material_Flags.Temp_World_Space) {
    uv = world_space_uv(in.pos_ws, surface.geometric_normal) * material.world_space_uv_scale;
  }

  let sampler = global.default_sampler;
  let normal_ts = decode_normal_map(material.normal_map_id.sample(sampler, uv).rg);
  surface.normal = normalize(tangent_to_world(normal_ts, surface.tangent, surface.bitangent, surface.geometric_normal));

  surface.base_color = material.base_color_id.sample(sampler, uv).rgb * in.color;

  let ao_roughness_metallic = material.ao_roughness_metallic_id.sample(sampler, uv).rgb;
  surface.ao = ao_roughness_metallic.r;
  surface.perceptual_roughness = ao_roughness_metallic.g;
  let metallic = ao_roughness_metallic.b;

  surface.diffuse_color = (1.0 - metallic) * surface.base_color;
  surface.f0 = fresnel_0(surface.base_color, metallic, DEFAULT_REFLECTANCE);
  return surface;
}

[shader("fragment")]
FragmentOutput fragment_main(FragmentInput in) {
  let global = pc.global_data_buffer;
  let instance = pc.instances[pc.instance_index];
  let material = pc.materials[instance.material_index];
  let debug_view = global.mesh_debug_view;

  let surface = pbr_surface_from_material(in, material, global);

  f32 shadow = 1.0;
  if (debug_view != GeometryDebugView.No_Shadow) {
    shadow = sample_shadow_cascades(global, pc.shadow_depth, pc.shadow_sampler, pc.num_cascades,
                                    surface.pos_ws, surface.geometric_normal, in.view_depth, in.pos_cs.xy);
  }

  var color = shade_sun(surface, global, shadow);
  color += shade_point_lights(surface, global.environment.point_lights);
  color += shade_indirect_diffuse(surface, global);
  color += shade_indirect_specular(surface, global);
  color = atmosphere_aerial(global, surface.pos_ws, color);

  switch (debug_view) {
  case GeometryDebugView.Shadow:
    color = Vec3(shadow);
    break;
  case GeometryDebugView.Base_Color:
    color = surface.base_color;
    break;
  case GeometryDebugView.Normal:
    color = surface.normal * 0.5 + 0.5;
    break;
  case GeometryDebugView.Tangent:
    color = surface.tangent * 0.5 + 0.5;
    break;
  case GeometryDebugView.Bitangent:
    color = surface.bitangent * 0.5 + 0.5;
    break;
  case GeometryDebugView.Irradiance:
    color = ddgi_sample_volumes(global.ddgi_volumes, surface.pos_ws, surface.normal, surface.geometric_normal, global.camera_pos);
    break;
  case GeometryDebugView.Specular:
    color = shade_indirect_specular(surface, global);
    break;
  default:
    break;
  }

  FragmentOutput output;
  output.frag_color = Vec4(color, 1.0);
  return output;
}
