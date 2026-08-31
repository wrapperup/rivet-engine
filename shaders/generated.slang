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
// Generated from C:\Repos\odin\vulkan-playground\src\entity_point_light.odin
//
struct PointLight {
  Vec3 color;
  f32 radius;
  Vec3 world_pos;
  f32 lumens;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\entity_reflection_probe.odin
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
struct Material {
  Image2D base_color_id;
  Image2D normal_map_id;
  Image2D ao_roughness_metallic_id;
};

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
  u32 mesh_debug_view;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_ddgi.odin
//
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
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_debug.odin
//
struct DebugRTPushConstants {
  GlobalData* global;
  Geometry* geometries;
  Material* materials;
  AccelerationStructure tlas;
  RWImage2D out_image;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_geometry.odin
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

struct SkyboxPushConstants {
  Vertex* vertex_buffer;
  GlobalData* global_data_buffer;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_post.odin
//
struct PostProcessingPushConstants {
  RWImage2D resolved_image;
  Image3D<Vec3> tony_mc_mapface;
  Sampler sampler;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_reflections.odin
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



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_shadow.odin
//
struct DrawShadowDepthPushConstants {
  Vertex* vertex_buffer;
  Mat4x4* model_matrices;
  GlobalData* global_data;
  u32 model_index;
  u32 cascade_index;
};

struct CascadeConfig {
  f32 split_dist;
  f32 depth_per_texel;
  f32 raster_subpixel_size;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\render_pass_skinning.odin
//
struct SkinningPushConstants {
  Slice<Vertex> input_vertices;
  Slice<Vertex> output_vertices;
  Slice<Mat4x4> joint_matrices;
  Slice<SkeletonVertexAttribute> attrs;
};



//
// Generated from C:\Repos\odin\vulkan-playground\src\rt_scene.odin
//
struct Geometry {
  Vertex* vertex_buffer;
  u32* index_buffer;
  MaterialId material_index;
  u32 _pad[3];
};