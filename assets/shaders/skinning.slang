import common;
import types;

struct SkelVertexAttribute {
  uint8_t joints[4];
  float weights[4];
};

[vk_push_constant]
SkinningPushConstants pc;

[numthreads(64, 1, 1)]
[shader("compute")]
void compute_main(uint3 dispatch_thread_id: SV_DispatchThreadID) {
  let vertex_index = dispatch_thread_id.x;
  
  if (vertex_index >= pc.output_vertices.count) {
      return;
  }

  let in_vertex = pc.input_vertices[vertex_index];
  let attrs = pc.attrs[vertex_index];

  let skin_mat = attrs.weights[0] * pc.joint_matrices[attrs.joints[0]] +
                 attrs.weights[1] * pc.joint_matrices[attrs.joints[1]] +
                 attrs.weights[2] * pc.joint_matrices[attrs.joints[2]] +
                 attrs.weights[3] * pc.joint_matrices[attrs.joints[3]];

  Vertex v;

  v.position =    mul(skin_mat, Vec4(in_vertex.position, 1.0)).xyz;
  v.normal =      mul(skin_mat, float4(in_vertex.normal, 0.0)).xyz;
  v.color =       in_vertex.color;
  v.tangent =     mul(skin_mat, float4(in_vertex.tangent.xyz, 0.0));
  v.uv_x =        in_vertex.uv_x;
  v.uv_y =        in_vertex.uv_y;

  var output_vertices = pc.output_vertices;
  output_vertices[vertex_index] = v;
}
