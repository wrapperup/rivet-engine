//
// This is a generated file, do not modify. See src/meta.odin
//

//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_ddgi_volume.odin
//
struct DDGIVolume {
  Vec3 grid_origin;
  u32 rays_per_probe;
  Vec3 probe_spacing;
  u32 _pad0;
  u32 grid_counts[3];
  u32 _pad1;
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
};

struct DDGITracePush {
  DDGIVolume* volume;
  Geometry* geometries;
  Material* materials;
  GlobalData* global;
  Vec4* radiance;
  AccelerationStructure tlas;
};

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



//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_point_light.odin
//
struct PointLight {
  Vec3 color;
  f32 radius;
  Vec3 world_pos;
  f32 lumens;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\gpu_types.odin
//
struct Vertex {
  float3 position;
  f32 uv_x;
  float3 normal;
  f32 uv_y;
  float4 color;
  float4 tangent;
};

struct SkeletonVertexAttribute {
  u8 joints[4];
  f32 weights[4];
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\renderer.odin
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

struct DrawShadowDepthPushConstants {
  Vertex* vertex_buffer;
  Mat4x4* model_matrices;
  GlobalData* global_data;
  u32 model_index;
  u32 cascade_index;
};

struct SkinningPushConstants {
  Vertex* input_vertex_buffer;
  Vertex* output_vertex_buffer;
  Mat4x4* joint_matrices;
  SkeletonVertexAttribute* attrs;
  u32 vertex_count;
};

struct SkyboxPushConstants {
  Vertex* vertex_buffer;
  GlobalData* global_data_buffer;
};

struct DebugRTPushConstants {
  GlobalData* global;
  Geometry* geometries;
  Material* materials;
  AccelerationStructure tlas;
  RWImage2D out_image;
};

struct PostProcessingPushConstants {
  RWImage2D resolved_image;
  Image3D<Vec3> tony_mc_mapface;
  Sampler sampler;
};

struct Material {
  Image2D base_color_id;
  Image2D normal_map_id;
  Image2D ao_roughness_metallic_id;
};

struct Environment {
  Sh_Coefficients* sh_coeffs;
  PointLight* point_lights;
  u32 num_point_lights;
  ImageCube env_map;
  Image2D dfg;
  Sampler env_sampler;
};

struct CascadeConfig {
  f32 split_dist;
  f32 bias;
  f32 slope_bias;
};

struct GlobalData {
  Environment environment;
  Mat4x4* cascade_world_to_shadows;
  CascadeConfig* cascade_configs;
  Mat4x4 view_to_clip;
  Mat4x4 world_to_view;
  Mat4x4 clip_to_world;
  Vec3 sun_color;
  Vec3 sky_color;
  Vec3 camera_pos;
  Vec3 sun_direction;
  Sampler default_sampler;
  DDGIVolume* ddgi;
};

struct Geometry {
  Vertex* vertex_buffer;
  u32* index_buffer;
  MaterialId material_index;
  u32 _pad[3];
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\spherical_harmonics.odin
//
struct Sh_Coefficients {
  Vec4 coeffs[9];
};