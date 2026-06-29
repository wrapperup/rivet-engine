package game

import "core:math/linalg/hlsl"

import "gfx"

@shader_shared
Vertex :: struct #max_field_align(16) {
	position: hlsl.float3,
	uv_x:     f32,
	normal:   hlsl.float3,
	uv_y:     f32,
	color:    hlsl.float4,
	tangent:  hlsl.float4,
}

@shader_shared
SkeletonVertexAttribute :: struct #max_field_align(16) {
	joints:  [4]u8,
	weights: [4]f32,
}

GPUMeshBuffers :: struct {
	index_buffer:  gfx.GPUBuffer(u32),
	index_count:   u32,
	vertex_buffer: gfx.GPUBuffer(Vertex),
	vertex_count:  u32,
	blas:          gfx.Raytracing_Accel,
}

GPUSkelMeshBuffers :: struct {
	using mesh_buffers:     GPUMeshBuffers,

	// Array of SkeletonVertexAttribute
	skel_vert_attrs_buffer: gfx.GPUBuffer(SkeletonVertexAttribute),
	attrs_count:            u32,
}
