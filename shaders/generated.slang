//
// This is a generated file, do not modify. See src/meta.odin
//

struct DfgGeneratePassPC {
  u32 sample_count;
  RWImage2D<float2> dfg_image;
  bool multiscatter;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\dfg.odin
//
struct DDGIVolume {
  Vec3 grid_origin;
  u32 rays_per_probe;
  Vec3 probe_spacing;
  u32 grid_counts[3];
  Image2D irradiance;
  Image2D depth;
  Image2D offset;
  Sampler sampler;
  f32 hysteresis;
  f32 max_distance;
  f32 normal_bias;
  u32 frame_index;
  f32 intensity;
  f32 feedback;
  f32 depth_bias;
  f32 relocation_max;
  f32 cheb_sharpness;
  f32 ray_max;
  f32 max_radiance;
  f32 priority;
  f32 edge_fade;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_ddgi_volume.odin
//
struct PointLight {
  Vec3 color;
  f32 radius;
  Vec3 world_pos;
  f32 lumens;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_point_light.odin
//
struct ReflectionProbe {
  Vec3 center;
  f32 blend_distance;
  Vec3 half_extents;
  f32 intensity;
  ImageCube cube;
  Sampler sampler;
  u32 mip_count;
  f32 priority;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_reflection_probe.odin
//
struct Vertex {
  float3 position;
  f32 uv_x;
  float3 normal;
  f32 uv_y;
  float4 color;
  float4 tangent;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\gpu_types.odin
//
struct SkeletonVertexAttribute {
  u8 joints[4];
  f32 weights[4];
};

struct Material {
  Image2D base_color_id;
  Image2D normal_map_id;
  Image2D ao_roughness_metallic_id;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\renderer.odin
//
struct Environment {
  Slice<PointLight> point_lights;
  ImageCube env_map;
  Image2D dfg;
  Sampler env_sampler;
};

struct GlobalData {
  Mat4x4 view_to_clip;
  Mat4x4 world_to_view;
  Mat4x4 clip_to_world;
  Environment environment;
  Mat4x4* cascade_world_to_shadows;
  CascadeConfig* cascade_configs;
  Vec3 sun_color;
  Vec3 sky_color;
  Vec3 camera_pos;
  Vec3 sun_direction;
  Sampler default_sampler;
  Slice<DDGIVolume> ddgi_volumes;
  Slice<ReflectionProbe> reflection_probes;
  Atmosphere atmosphere;
  u32 mesh_debug_view;
};

struct Atmosphere {
  Image2D transmittance;
  Image2D multiple_scattering;
  Image2D sky_view;
  Image3D aerial_scattering;
  Image3D aerial_transmittance;
  Sampler sampler;
  f32 rayleigh_density;
  f32 mie_density;
  f32 ozone_density;
  f32 ground_albedo;
  f32 ground_height;
  f32 camera_height;
  f32 sun_radius;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_atmosphere.odin
//
struct AtmosphereLutPush {
  GlobalData* global;
  RWImage2D output;
};

struct AtmosphereCubePush {
  GlobalData* global;
  RWImage2DArray output;
};

struct AtmosphereAerialPush {
  GlobalData* global;
  RWImage3D scattering;
  RWImage3D transmittance;
};

struct AtmosphereDrawPush {
  GlobalData* global;
};

struct DDGITracePush {
  DDGIVolume* volume;
  Geometry* geometries;
  Material* materials;
  GlobalData* global;
  Vec4* radiance;
  AccelerationStructure tlas;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_ddgi.odin
//
struct DDGIUpdatePush {
  DDGIVolume* volume;
  Vec4* radiance;
  RWImage2D irradiance;
  RWImage2D visibility;
  RWImage2D probe_data;
};

struct DDGIRelocatePush {
  DDGIVolume* volume;
  Vec4* radiance;
  RWImage2D probe_data;
  u32 first_frame;
  u32 adjust_offsets;
};

struct DDGIDebugAtlasPush {
  DDGIVolume* volume;
  RWImage2D out_image;
};

struct DDGIProbePush {
  GlobalData* global;
  DDGIVolume* volume;
  Vertex* vertex_buffer;
  f32 probe_radius;
};

struct DebugRTPushConstants {
  GlobalData* global;
  Geometry* geometries;
  Material* materials;
  AccelerationStructure tlas;
  RWImage2D out_image;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_debug.odin
//
struct DrawPushConstants {
  GlobalData* global_data_buffer;
  Vertex* vertex_buffer;
  Mat4x4* model_matrices;
  Material* materials;
  u32 model_index;
  MaterialId material_index;
  u32 num_cascades;
  Image2DArray<f32> shadow_depth;
  SamplerComparison shadow_sampler;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_geometry.odin
//
struct PostProcessingPushConstants {
  RWImage2D resolved_image;
  Image3D<Vec3> tony_mc_mapface;
  Sampler sampler;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_post.odin
//
struct ReflectionCapturePush {
  GlobalData* global;
  Geometry* geometries;
  Material* materials;
  AccelerationStructure tlas;
  RWImage2DArray out_cube;
  Vec3 center;
  u32 face_size;
  f32 ray_max;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_reflections.odin
//
struct ReflectionProbeDebugPush {
  GlobalData* global;
  ReflectionProbe* probe;
  Vertex* vertex_buffer;
  Vec3 center;
  f32 radius;
};

struct ReflectionPrefilterPush {
  ImageCube src_cube;
  Sampler sampler;
  RWImage2DArray out_mip;
  u32 face_size;
  f32 roughness;
  u32 sample_count;
};

struct DrawShadowDepthPushConstants {
  Vertex* vertex_buffer;
  Mat4x4* model_matrices;
  GlobalData* global_data;
  u32 model_index;
  u32 cascade_index;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_shadow.odin
//
struct CascadeConfig {
  f32 split_dist;
  f32 depth_per_texel;
  f32 raster_subpixel_size;
};

struct SkinningPushConstants {
  Slice<Vertex> input_vertices;
  Slice<Vertex> output_vertices;
  Slice<Mat4x4> joint_matrices;
  Slice<SkeletonVertexAttribute> attrs;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_skinning.odin
//
struct UI_Command {
  Vec2 pos;
  Vec2 size;
  Vec4 color;
  f32 corner_radius;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_ui.odin
//
struct UI_Push {
  Slice<UI_Command> commands;
  Vec2 viewport_size;
};

struct Geometry {
  Vertex* vertex_buffer;
  u32* index_buffer;
  MaterialId material_index;
  u32 _pad[3];
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\rt_scene.odin
//