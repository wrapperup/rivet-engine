package game

import "core:slice"

import vk "vendor:vulkan"

import "gfx"

@(shader_shared)
GPUReflectionCapturePush :: struct #max_field_align(16) {
	global:     gfx.Ptr(GPUGlobalData),
	instances: gfx.Ptr(GPURenderInstance),
	materials:  gfx.Ptr(GPUMaterial),
	tlas:       vk.DeviceAddress `AccelerationStructure`,
	out_cube:   gfx.ImageId `RWImage2DArray`,
	center:     Vec3,
	face_size:  u32,
	ray_max:    f32,
}

@(shader_shared)
GPUReflectionProbeDebugPush :: struct #max_field_align(16) {
	global:        gfx.Ptr(GPUGlobalData),
	probe:         gfx.Ptr(GPUReflectionProbe),
	vertex_buffer: gfx.Ptr(Vertex),
	center:        Vec3,
	radius:        f32,
}

@(shader_shared)
GPUReflectionPrefilterPush :: struct #max_field_align(16) {
	src_cube:     gfx.ImageId `ImageCube`,
	sampler:      gfx.SamplerId `Sampler`,
	out_mip:      gfx.ImageId `RWImage2DArray`,
	face_size:    u32,
	roughness:    f32,
	sample_count: u32,
}

REFLECTION_AUTO_CAPTURE_FRAME :: 200

init_reflection_probe_rp :: proc() {
	game.render_state.reflection_capture_pipeline = add_compute_shader(
		"shaders/reflection_capture.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Reflection_Capture", module, GPUReflectionCapturePush)
		},
	)
	game.render_state.reflection_prefilter_pipeline = add_compute_shader(
		"shaders/reflection_prefilter.slang",
		proc(module: vk.ShaderModule) -> gfx.ComputePipeline {
			return gfx.create_compute_pipeline("Reflection_Prefilter", module, GPUReflectionPrefilterPush)
		},
	)
	for &probes_buffer in game.render_state.reflection_probes_buffers {
		probes_buffer = gfx.create_buffer(GPUReflectionProbe, MAX_REFLECTION_PROBES, .DynUniform)
		gfx.defer_destroy(&gfx.r_ctx.global_arena, probes_buffer)
	}
	game.render_state.reflection_probe_debug_pipeline = add_graphics_shader(
		"shaders/reflection_probe_debug.slang",
		proc(module: vk.ShaderModule) -> gfx.GraphicsPipeline {
			return gfx.create_graphics_pipeline(
				name = "Reflection_Probe_Debug",
				shader = module,
				input_topology = .TRIANGLE_LIST,
				polygon_mode = .FILL,
				cull_mode = {},
				front_face = .COUNTER_CLOCKWISE,
				depth = {format = gfx.image_meta(gfx.r_ctx.depth_image).format, compare_op = .GREATER_OR_EQUAL, write_enabled = true},
				color_format = gfx.image_meta(gfx.r_ctx.draw_image).format,
				multisampling_samples = gfx.msaa_samples(),
				push_constants = GPUReflectionProbeDebugPush,
			)
		},
	)
}

reflection_probe_prepare :: proc(probes: []ReflectionProbe) {
	frame_index := gfx.current_frame_index()
	packed: [MAX_REFLECTION_PROBES]GPUReflectionProbe
	count: u32

	for &probe in probes {
		reflection_probe_write_config(&probe)
		if int(count) < MAX_REFLECTION_PROBES {
			packed[count] = reflection_probe_to_gpu(&probe)
			count += 1
		}
	}

	slice.sort_by(packed[:count], proc(a, b: GPUReflectionProbe) -> bool {
		return a.priority > b.priority
	})
	if count > 0 {
		gfx.write_buffer_slice(&game.render_state.reflection_probes_buffers[frame_index], packed[:count])
	}

	game.render_state.global_data.reflection_probes = gfx.slice(
		game.render_state.reflection_probes_buffers[frame_index],
		count = u64(count),
	)
}

record_reflection_probe_pass :: proc(cmd: gfx.CommandBuffer, probes: []ReflectionProbe, volumes: []DDGIVolume) {
	if current_frame_game().rt.tlas.address == 0 do return

	converged := true
	for &volume in volumes {
		if volume.gpu.frame_index <= REFLECTION_AUTO_CAPTURE_FRAME {
			converged = false
			break
		}
	}

	for &probe in probes {
		auto := !probe.captured && converged
		live := game.state.update_reflections && converged
		if probe.wants_recapture || auto || live {
			record_reflection_probe_capture(cmd, &probe)
			probe.wants_recapture = false
		}
	}
}

record_reflection_probe_debug_pass :: proc(cmd: gfx.CommandBuffer, probes: []ReflectionProbe) {
    if .Reflection_Probes not_in editor.settings.vis_flags {
        return
    }

	rp := &game.render_state.ddgi_rp
	gfx.cmd_begin_rendering(
		cmd,
		area = gfx.r_ctx.draw_extent,
		color_attachment = &{view = gfx.r_ctx.draw_image, layout = .COLOR_ATTACHMENT_OPTIMAL},
		depth_attachment = &{view = gfx.r_ctx.depth_image, layout = .DEPTH_ATTACHMENT_OPTIMAL},
	)
	gfx.set_viewport_and_scissor(cmd, gfx.r_ctx.draw_extent)
	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_probe_debug_pipeline)
	gfx.cmd_bind_index_buffer(cmd, rp.probe_ibuf.buffer)

	for &probe in probes {
		gfx.cmd_push_constants(
			cmd,
			GPUReflectionProbeDebugPush {
				global = current_frame_game().global_buffer.ptr,
				probe = probe.configs[gfx.current_frame_index()].ptr,
				vertex_buffer = rp.probe_vbuf.ptr,
				center = probe.translation,
				radius = probe.debug_radius,
			},
		)
		gfx.cmd_draw_indexed(cmd, rp.probe_index_count, instance_count = 1)
	}
	gfx.cmd_end_rendering(cmd)
}

reflection_probe_debug_draw_box :: proc(probe: ^ReflectionProbe) {
	c := probe.translation
	h := probe.half_extents

	corners: [8]Vec3
	for i in 0 ..< 8 {
		sx := f32(int(i & 1) * 2 - 1)
		sy := f32(int((i >> 1) & 1) * 2 - 1)
		sz := f32(int((i >> 2) & 1) * 2 - 1)
		corners[i] = c + Vec3{sx * h.x, sy * h.y, sz * h.z}
	}

	// 12 edges = corner pairs differing in exactly one axis bit.
	edges := [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
	for e in edges {
		debug_draw_line(corners[e[0]], corners[e[1]], 1.5, DEBUG_COLOR_GOOD)
	}
}

@(private = "file")
record_reflection_probe_capture :: proc(cmd: gfx.CommandBuffer, probe: ^ReflectionProbe) {
	gfx.image_barrier(
		cmd,
		probe.cube_image_id,
		src_access = .AllReadsWrites,
		dst_access = .ComputeShaderWrite,
	)

	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_capture_pipeline)
	gfx.cmd_push_constants(
		cmd,
		GPUReflectionCapturePush {
			global = current_frame_game().global_buffer.ptr,
			instances = current_frame_game().instances_buffer.ptr,
			materials = game.render_state.material_store.materials_buffer.ptr,
			tlas = current_frame_game().rt.tlas.address,
			out_cube = probe.cube_mip_storage_ids[0],
			center = probe.translation,
			face_size = probe.face_size,
			ray_max = 200.0,
		},
	)
	groups := (probe.face_size + 7) / 8
	vk.CmdDispatch(cmd, groups, groups, 6)

	gfx.image_barrier(
		cmd,
		probe.cube_image_id,
		src_access = .ComputeShaderWrite,
		dst_access = .ComputeShaderRead,
	)

	gfx.cmd_bind_pipeline(cmd, game.render_state.reflection_prefilter_pipeline)
	for mip in u32(1) ..< probe.mip_count {
		mip_size := max(probe.face_size >> mip, 1)
		roughness := f32(mip) / f32(probe.mip_count - 1)
		gfx.cmd_push_constants(
			cmd,
			GPUReflectionPrefilterPush {
				src_cube = probe.cube_image_id,
				sampler = probe.gpu_sampler_id,
				out_mip = probe.cube_mip_storage_ids[mip],
				face_size = mip_size,
				roughness = roughness,
				sample_count = 128,
			},
		)
		g := (mip_size + 7) / 8
		vk.CmdDispatch(cmd, g, g, 6)
	}

	gfx.image_barrier(
		cmd,
		probe.cube_image_id,
		src_access = .ComputeShaderWrite,
		dst_access = .ComputeFragmentShaderRead,
	)
	probe.captured = true
}
