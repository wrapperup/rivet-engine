package game

import "core:math"
import "core:slice"

import vk "vendor:vulkan"

import "gfx"

@(private = "file")
ImageId :: gfx.ImageId

@(shader_shared)
GPUDDGITracePush :: struct #max_field_align(16) {
	volume:     gfx.Ptr(GPUDDGIVolume),
	geometries: gfx.Ptr(GPUGeometry),
	materials:  gfx.Ptr(GPUMaterial),
	global:     gfx.Ptr(GPUGlobalData),
	radiance:   gfx.Ptr(Vec4),
	tlas:       vk.DeviceAddress `AccelerationStructure`,
}

@(shader_shared)
GPUDDGIUpdatePush :: struct #max_field_align(16) {
	volume:     gfx.Ptr(GPUDDGIVolume),
	radiance:   gfx.Ptr(Vec4),
	irradiance: ImageId `RWImage2D`,
	visibility: ImageId `RWImage2D`,
	probe_data: ImageId `RWImage2D`,
}

@(shader_shared)
GPUDDGIRelocatePush :: struct #max_field_align(16) {
	volume:         gfx.Ptr(GPUDDGIVolume),
	radiance:       gfx.Ptr(Vec4),
	probe_data:     ImageId `RWImage2D`,
	first_frame:    u32,
	adjust_offsets: u32,
}

@(shader_shared)
GPUDDGIDebugAtlasPush :: struct #max_field_align(16) {
	volume:    gfx.Ptr(GPUDDGIVolume),
	out_image: ImageId `RWImage2D`,
}

@(shader_shared)
GPUDDGIProbePush :: struct #max_field_align(16) {
	global:        gfx.Ptr(GPUGlobalData),
	volume:        gfx.Ptr(GPUDDGIVolume),
	vertex_buffer: gfx.Ptr(Vertex),
	probe_radius:  f32,
}

DDGI_UPDATE_BLOCKS_PER_PROBE :: (DDGI_PROBE_IRR_TEXELS * DDGI_PROBE_IRR_TEXELS + 63) / 64 + (DDGI_PROBE_DEPTH_TEXELS * DDGI_PROBE_DEPTH_TEXELS + 63) / 64

DDGIRenderPass :: struct {
	trace_pipeline:         ^gfx.ComputePipeline,
	update_pipeline:        ^gfx.ComputePipeline,
	border_pipeline:        ^gfx.ComputePipeline,
	relocate_pipeline:      ^gfx.ComputePipeline,
	debug_pipeline:         ^gfx.ComputePipeline,
	probe_pipeline:         ^gfx.GraphicsPipeline,
	volumes_buffers:        [gfx.FRAME_OVERLAP]gfx.Buffer(GPUDDGIVolume),
	debug_volume:           i32,
	probe_vbuf:             gfx.Buffer(Vertex),
	probe_ibuf:             gfx.Buffer(u32),
	probe_index_count:      u32,
	draw_probes:            bool,
	draw_reflection_probes: bool,
}

init_ddgi_rp :: proc() {
	ddgi_rp := &game.render_state.ddgi_rp

	ddgi_rp.trace_pipeline = add_compute_shader("shaders/ddgi_trace.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("DDGI_Trace", module, GPUDDGITracePush)
	})
	ddgi_rp.update_pipeline = add_compute_shader("shaders/ddgi_update.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("DDGI_Update", module, GPUDDGIUpdatePush)
	})
	ddgi_rp.border_pipeline = add_compute_shader("shaders/ddgi_border.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("DDGI_Border", module, GPUDDGIUpdatePush)
	})
	ddgi_rp.relocate_pipeline = add_compute_shader("shaders/ddgi_relocate.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("DDGI_Relocate", module, GPUDDGIRelocatePush)
	})
	ddgi_rp.debug_pipeline = add_compute_shader("shaders/ddgi_debug_atlas.slang", proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
		return gfx.create_compute_pipeline("DDGI_Debug_Atlas", module, GPUDDGIDebugAtlasPush)
	})
	ddgi_rp.probe_pipeline = add_graphics_shader("shaders/ddgi_debug_probes.slang", proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
		return gfx.create_graphics_pipeline(
			name = "DDGI_Debug_Probes",
			shader = module,
			input_topology = .TRIANGLE_LIST,
			polygon_mode = .FILL,
			cull_mode = {},
			front_face = .COUNTER_CLOCKWISE,
			depth = {format = gfx.r_ctx.depth_image.format, compare_op = .LESS_OR_EQUAL, write_enabled = true},
			color_format = gfx.r_ctx.draw_image.format,
			multisampling_samples = gfx.msaa_samples(),
			push_constants = GPUDDGIProbePush,
		)
	})

	for &volumes_buffer in ddgi_rp.volumes_buffers {
		volumes_buffer = gfx.create_buffer(GPUDDGIVolume, MAX_DDGI_VOLUMES, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, volumes_buffer)
	}
	ddgi_init_debug_sphere()
}

// Generates a UV sphere (positions == normals, unit radius).
@(private = "file")
ddgi_make_sphere :: proc(rings, sectors: int) -> ([]Vertex, []u32) {
	verts := make([dynamic]Vertex)
	indices := make([dynamic]u32)
	for r in 0 ..= rings {
		theta := f32(r) / f32(rings) * math.PI
		st := math.sin(theta)
		ct := math.cos(theta)
		for s in 0 ..= sectors {
			phi := f32(s) / f32(sectors) * 2.0 * math.PI
			n := Vec3{st * math.cos(phi), ct, st * math.sin(phi)}
			append(&verts, Vertex{position = {n.x, n.y, n.z}, normal = {n.x, n.y, n.z}})
		}
	}
	for r in 0 ..< rings {
		for s in 0 ..< sectors {
			i0 := u32(r * (sectors + 1) + s)
			i1 := u32(r * (sectors + 1) + s + 1)
			i2 := u32((r + 1) * (sectors + 1) + s)
			i3 := u32((r + 1) * (sectors + 1) + s + 1)
			append(&indices, i0, i2, i1, i1, i2, i3)
		}
	}
	return verts[:], indices[:]
}

ddgi_init_debug_sphere :: proc() {
	rp := &game.render_state.ddgi_rp
	verts, indices := ddgi_make_sphere(12, 16)
	defer delete(verts)
	defer delete(indices)

	rp.probe_vbuf = gfx.create_buffer(Vertex, len(verts))
	rp.probe_ibuf = gfx.create_buffer(u32, len(indices), .Index)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.probe_vbuf)
	gfx.defer_destroy(&gfx.r_ctx.global_arena, rp.probe_ibuf)
	gfx.staging_write_buffer_slice(&rp.probe_vbuf, verts)
	gfx.staging_write_buffer_slice(&rp.probe_ibuf, indices)
	rp.probe_index_count = u32(len(indices))
}

ddgi_prepare :: proc(volumes: []DDGIVolume, advance_frame: bool) {
	rp := &game.render_state.ddgi_rp
	frame_index := gfx.current_frame_index()
	packed: [MAX_DDGI_VOLUMES]GPUDDGIVolume
	count: u32

	for &volume in volumes {
		if advance_frame {
			volume.gpu.frame_index += 1
		}
		gfx.write_buffer(&volume.config_buffers[frame_index], &volume.gpu)
		if int(count) < MAX_DDGI_VOLUMES {
			packed[count] = volume.gpu
			count += 1
		}
	}

	slice.sort_by(packed[:count], proc(a, b: GPUDDGIVolume) -> bool {
		return a.priority > b.priority
	})
	if count > 0 {
		gfx.write_buffer_slice(&rp.volumes_buffers[frame_index], packed[:count])
	}

	game.render_state.global_data.ddgi_volumes = gfx.slice(
		rp.volumes_buffers[frame_index],
		count = u64(count),
	)
}

@(private = "file")
ddgi_current_config :: proc(volume: ^DDGI_Volume_Resources) -> ^gfx.Buffer(GPUDDGIVolume) {
	return &volume.config_buffers[gfx.current_frame_index()]
}

record_ddgi_pass :: proc(cmd: vk.CommandBuffer, volumes: []DDGIVolume) {
	if current_frame_game().rt.tlas.address == 0 || !game.state.update_ddgi do return

	for &volume in volumes {
		record_ddgi_volume(cmd, &volume.volume)
	}
}

// Overlay: draws an instanced sphere per probe into the HDR scene, each shaded
// by its own irradiance. Depth-tested against the scene.
record_ddgi_debug_probes_pass :: proc(cmd: vk.CommandBuffer, volumes: []DDGIVolume) {
	if !game.render_state.ddgi_rp.draw_probes do return

	for &volume in volumes {
		record_ddgi_debug_volume(cmd, &volume.volume)
	}
}

@(private = "file")
record_ddgi_debug_volume :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	rp := &game.render_state.ddgi_rp
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image.image_view, layout = .COLOR_ATTACHMENT_OPTIMAL},
		depth_attachment = &{view = gfx.r_ctx.depth_image.image_view, layout = .DEPTH_ATTACHMENT_OPTIMAL},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)
	gfx.cmd_bind_pipeline(cmd, rp.probe_pipeline)
	gfx.cmd_bind_index_buffer(cmd, rp.probe_ibuf.buffer)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGIProbePush {
			global = current_frame_game().global_buffer.ptr,
			volume = ddgi_current_config(volume).ptr,
			vertex_buffer = rp.probe_vbuf.ptr,
			probe_radius = 0.3,
		},
	)
	counts := volume.gpu.grid_counts
	gfx.cmd_draw_indexed(cmd, rp.probe_index_count, instance_count = counts[0] * counts[1] * counts[2])
	gfx.cmd_end_rendering(cmd)
}

// Trace + update for the volume, recorded into `cmd`. Uses the per-frame scene TLAS.
@(private = "file")
record_ddgi_volume :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	counts := volume.gpu.grid_counts
	num_probes := counts[0] * counts[1] * counts[2]

	update_push := GPUDDGIUpdatePush {
		volume     = ddgi_current_config(volume).ptr,
		radiance   = volume.radiance_buffer.ptr,
		irradiance = volume.gpu.irradiance,
		visibility = volume.gpu.depth,
		probe_data = volume.gpu.offset,
	}

	gfx.buffer_barrier(
		cmd,
		volume.radiance_buffer,
		src_access = .AllReadsWrites,
		dst_access = .ComputeShaderWrite,
	)
	gfx.image_barrier(
		cmd,
		&volume.irradiance,
		src_access = .AllReadsWrites,
		dst_access = .ComputeShaderReadWrite,
	)
	gfx.image_barrier(
		cmd,
		&volume.depth,
		src_access = .AllReadsWrites,
		dst_access = .ComputeShaderReadWrite,
	)
	gfx.image_barrier(
		cmd,
		&volume.offset,
		src_access = .AllReadsWrites,
		dst_access = .ComputeShaderReadWrite,
	)

	// raytrace
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_rp.trace_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGITracePush {
			volume = ddgi_current_config(volume).ptr,
			geometries = current_frame_game().rt.geometries_buffer.ptr,
			materials = game.render_state.scene_resources.materials_buffer.ptr,
			global = current_frame_game().global_buffer.ptr,
			radiance = volume.radiance_buffer.ptr,
			tlas = current_frame_game().rt.tlas.address,
		},
	)
	vk.CmdDispatch(cmd, num_probes, 1, 1)

	// radiance write
	gfx.buffer_barrier(
		cmd,
		volume.radiance_buffer,
		src_access = .ComputeShaderWrite,
		dst_access = .ComputeShaderRead,
	)

	init_iteration := volume.gpu.frame_index
	if init_iteration >= 1 && init_iteration <= 6 {
		gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_rp.relocate_pipeline)
		gfx.cmd_push_constants(
			cmd,
			GPUDDGIRelocatePush {
				volume = ddgi_current_config(volume).ptr,
				radiance = volume.radiance_buffer.ptr,
				probe_data = volume.gpu.offset,
				first_frame = u32(init_iteration == 1),
				adjust_offsets = u32(init_iteration <= 5),
			},
		)
		vk.CmdDispatch(cmd, (num_probes + 63) / 64, 1, 1)
		gfx.image_barrier(
			cmd,
			&volume.offset,
			src_access = .ComputeShaderWrite,
			dst_access = .ComputeShaderReadWrite,
		)
	}

	// update irradiance and visibility
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_rp.update_pipeline)
	gfx.cmd_push_constants(cmd, update_push)
	vk.CmdDispatch(cmd, num_probes, 1, DDGI_UPDATE_BLOCKS_PER_PROBE)
	gfx.image_barrier(
		cmd,
		&volume.irradiance,
		src_access = .ComputeShaderWrite,
		dst_access = .ComputeShaderReadWrite,
	)
	gfx.image_barrier(
		cmd,
		&volume.depth,
		src_access = .ComputeShaderWrite,
		dst_access = .ComputeShaderReadWrite,
	)

	// border copy
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_rp.border_pipeline)
	gfx.cmd_push_constants(cmd, update_push)
	vk.CmdDispatch(cmd, num_probes, 1, 1)

	gfx.image_barrier(
		cmd,
		&volume.irradiance,
		src_access = .ComputeShaderWrite,
		dst_access = .AllShaderRead,
	)
	gfx.image_barrier(
		cmd,
		&volume.depth,
		src_access = .ComputeShaderWrite,
		dst_access = .AllShaderRead,
	)
	gfx.image_barrier(
		cmd,
		&volume.offset,
		src_access = .ComputeShaderWrite,
		dst_access = .AllShaderRead,
	)
}

record_ddgi_debug_atlas_pass :: proc(cmd: vk.CommandBuffer, volume: ^DDGI_Volume_Resources) {
	gfx.transition_image(cmd, &gfx.r_ctx.resolve_image, .GENERAL)
	gfx.cmd_bind_pipeline(cmd, game.render_state.ddgi_rp.debug_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUDDGIDebugAtlasPush{volume = ddgi_current_config(volume).ptr, out_image = game.render_state.temp_resources.resolved_image_id},
	)
	vk.CmdDispatch(cmd, u32(gfx.r_ctx.draw_extent.width + 15) / 16, u32(gfx.r_ctx.draw_extent.height + 15) / 16, 1)
}
