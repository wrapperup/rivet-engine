package game

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:reflect"
import "core:slice"
import "core:strings"

import im "deps:odin-imgui"
import px "deps:physx-odin"

import "gfx"

configure_im :: proc() {
	io := im.GetIO()

	font_config: im.FontConfig = {}

	font_config.FontDataOwnedByAtlas = true
	font_config.OversampleH = 6
	font_config.OversampleV = 6
	font_config.GlyphMaxAdvanceX = max(f32)
	font_config.RasterizerMultiply = 1.4
	font_config.RasterizerDensity = 1.0
	font_config.EllipsisChar = max(u16)

	font_config.PixelSnapH = false
	font_config.GlyphOffset = {0.0, -1.0}

	segoe_ui := asset_content(.f_segoeui)
	im.FontAtlas_AddFontFromMemoryTTF(io.Fonts, raw_data(segoe_ui), cast(i32)len(segoe_ui), 18.0, &font_config)

	font_config.MergeMode = true

	ICON_MIN_FA: u16 : 0xe005
	ICON_MAX_FA: u16 : 0xf8ff

	@(static) FA_RANGES: [3]u16 = {ICON_MIN_FA, ICON_MAX_FA, 0}

	font_config.RasterizerMultiply = 1.0
	font_config.GlyphOffset = {0.0, -1.0}

	fa_regular := asset_content(.f_fa_regular_400)
	im.FontAtlas_AddFontFromMemoryTTF(
		io.Fonts,
		raw_data(fa_regular),
		cast(i32)len(fa_regular),
		14.0,
		&font_config,
		slice.as_ptr(FA_RANGES[:]),
	)

	font_config.MergeMode = false

	style := im.GetStyle()

	tone_text_1: im.Vec4 : {0.69, 0.69, 0.69, 1.0}
	tone_text_2: im.Vec4 : {0.69, 0.69, 0.69, 0.8}

	tone_1: im.Vec4 : {0.16, 0.16, 0.18, 1.0}
	// tone_1_b := tone_1 * 1.2
	tone_1_e := tone_1 * 1.2
	tone_1_e_a := tone_1_e
	tone_3: im.Vec4 : {0.11, 0.11, 0.12, 1.0}
	//tone_2: im.Vec4 : {0.12, 0.12, 0.13, 1.0}
	tone_2 := tone_3
	tone_2_b: im.Vec4 = tone_2

	style.Colors[im.Col.Text] = tone_text_1
	style.Colors[im.Col.TextDisabled] = tone_text_2
	style.Colors[im.Col.WindowBg] = tone_1
	style.Colors[im.Col.ChildBg] = tone_2
	style.Colors[im.Col.PopupBg] = tone_2_b
	style.Colors[im.Col.Border] = tone_2
	style.Colors[im.Col.BorderShadow] = {0.0, 0.0, 0.0, 0.0}
	style.Colors[im.Col.FrameBg] = tone_3
	style.Colors[im.Col.FrameBgHovered] = tone_3
	style.Colors[im.Col.FrameBgActive] = tone_3
	style.Colors[im.Col.TitleBg] = tone_2
	style.Colors[im.Col.TitleBgActive] = tone_2
	style.Colors[im.Col.TitleBgCollapsed] = tone_2
	style.Colors[im.Col.MenuBarBg] = tone_2
	style.Colors[im.Col.ScrollbarBg] = tone_3
	style.Colors[im.Col.ScrollbarGrab] = tone_1_e
	style.Colors[im.Col.ScrollbarGrabHovered] = tone_1_e
	style.Colors[im.Col.ScrollbarGrabActive] = tone_1_e_a
	style.Colors[im.Col.CheckMark] = tone_1_e
	style.Colors[im.Col.SliderGrab] = tone_1_e
	style.Colors[im.Col.SliderGrabActive] = tone_1_e_a
	style.Colors[im.Col.Button] = tone_2
	style.Colors[im.Col.ButtonHovered] = tone_2
	style.Colors[im.Col.ButtonActive] = tone_3
	style.Colors[im.Col.Header] = tone_2
	style.Colors[im.Col.HeaderHovered] = tone_2
	style.Colors[im.Col.HeaderActive] = tone_2
	style.Colors[im.Col.Separator] = tone_2
	style.Colors[im.Col.SeparatorHovered] = tone_2
	style.Colors[im.Col.SeparatorActive] = tone_2
	style.Colors[im.Col.ResizeGrip] = {0.0, 0.0, 0.0, 0.0}
	style.Colors[im.Col.ResizeGripHovered] = {0.0, 0.0, 0.0, 0.0}
	style.Colors[im.Col.ResizeGripActive] = {0.0, 0.0, 0.0, 0.0}
	style.Colors[im.Col.Tab] = tone_2
	style.Colors[im.Col.TabHovered] = tone_1
	style.Colors[im.Col.TabActive] = tone_1
	style.Colors[im.Col.TabUnfocused] = tone_1
	style.Colors[im.Col.TabUnfocusedActive] = tone_1
	style.Colors[im.Col.PlotLines] = tone_1_e
	style.Colors[im.Col.PlotLinesHovered] = tone_2
	style.Colors[im.Col.PlotHistogram] = tone_1_e
	style.Colors[im.Col.PlotHistogramHovered] = tone_2
	style.Colors[im.Col.TableHeaderBg] = tone_2
	style.Colors[im.Col.TableBorderStrong] = tone_2
	style.Colors[im.Col.TableBorderLight] = tone_2
	style.Colors[im.Col.TableRowBg] = tone_2
	style.Colors[im.Col.TableRowBgAlt] = tone_1
	style.Colors[im.Col.TextSelectedBg] = tone_1_e
	style.Colors[im.Col.DragDropTarget] = tone_2
	style.Colors[im.Col.NavHighlight] = tone_2
	style.Colors[im.Col.NavWindowingHighlight] = tone_2
	style.Colors[im.Col.NavWindowingDimBg] = tone_2_b
	style.Colors[im.Col.ModalWindowDimBg] = tone_2_b * 0.5

	style.Colors[im.Col.DockingPreview] = {1.0, 1.0, 1.0, 0.5}
	style.Colors[im.Col.DockingEmptyBg] = {0.0, 0.0, 0.0, 0.0}

	style.WindowPadding = {10.00, 10.00}
	style.FramePadding = {5.00, 5.00}
	style.CellPadding = {2.50, 2.50}
	style.ItemSpacing = {5.00, 5.00}
	style.ItemInnerSpacing = {5.00, 5.00}
	style.TouchExtraPadding = {5.00, 5.00}
	style.IndentSpacing = 10
	style.ScrollbarSize = 15
	style.GrabMinSize = 10
	style.WindowBorderSize = 0
	style.ChildBorderSize = 0
	style.PopupBorderSize = 0
	style.FrameBorderSize = 0
	style.TabBorderSize = 0
	style.WindowRounding = 10
	style.ChildRounding = 5
	style.FrameRounding = 5
	style.PopupRounding = 5
	style.GrabRounding = 5
	style.ScrollbarRounding = 10
	style.LogSliderDeadzone = 5
	style.TabRounding = 5
	style.DockingSeparatorSize = 5
}

update_imgui :: proc() {
	scope_stat_time(.Imgui)

	view_projection := get_current_projection_view_matrix()

	bl := im.GetBackgroundDrawList()

	rb := px.scene_get_render_buffer_mut(game.phys.scene)
	for i in 0 ..< px.render_buffer_get_nb_lines(rb) {
		line := px.render_buffer_get_lines(rb)[i]

		line0, ok := world_space_to_clip_space(view_projection, transmute(Vec3)line.pos0)
		line1, ok2 := world_space_to_clip_space(view_projection, transmute(Vec3)line.pos1)

		if !ok && !ok2 do continue

		im.DrawList_AddLine(bl, line0, line1, line.color0, 1.0)
	}

	if action_just_pressed(.ShowDebug) {
		game.show_imgui = !game.show_imgui
	}

	if !game.show_imgui do return

	editor_draw_imgui()

	dl := im.GetForegroundDrawList()
	red := im.GetColorU32ImVec4({1.0, 0.0, 0.0, 1.0})
	green := im.GetColorU32ImVec4({0.0, 1.0, 0.0, 1.0})
	blue := im.GetColorU32ImVec4({0.0, 0.0, 1.0, 1.0})

	player := get_entity(game.state.player_id)
	{
		view_matrix := linalg.matrix4_from_quaternion(player != nil ? player.rotation : {})

		projection_matrix := gfx.matrix_ortho3d_z0_f32(-1, 1, -1, 1, 0.1, 1)
		projection_matrix[1][1] *= -1.0

		view_projection_matrix := view_matrix * projection_matrix

		origin_ws := hlsl.float4{0, 0, 0, 1}

		x_pos_ws := hlsl.float4{1, 0, 0, 1} * 20
		y_pos_ws := hlsl.float4{0, 1, 0, 1} * 20
		z_pos_ws := hlsl.float4{0, 0, 1, 1} * 20

		offset_vs := hlsl.float2{f32(gfx.r_ctx.draw_extent.width) - 30, f32(gfx.r_ctx.draw_extent.height) - 30}

		origin := (origin_ws * view_projection_matrix).xy + offset_vs
		x_pos := (x_pos_ws * view_projection_matrix).xy + offset_vs
		y_pos := (y_pos_ws * view_projection_matrix).xy + offset_vs
		z_pos := (z_pos_ws * view_projection_matrix).xy + offset_vs

		im.DrawList_AddLine(dl, origin, x_pos, red, 2)
		im.DrawList_AddLine(dl, origin, y_pos, green, 2)
		im.DrawList_AddLine(dl, origin, z_pos, blue, 2)

	}

	if im.Begin("Physics") {
		enabled := px.scene_get_visualization_parameter(game.phys.scene, .Scale) > 0.0
		if im.Checkbox("Enable debug view", &enabled) {
			min := player.translation - 50
			max := player.translation + 50
			px.scene_set_visualization_culling_box_mut(game.phys.scene, px.bounds3_new_1(transmute(px.Vec3)min, transmute(px.Vec3)max))
			px.scene_set_visualization_parameter_mut(game.phys.scene, .Scale, enabled ? 1.0 : 0.0)
			px.scene_set_visualization_parameter_mut(game.phys.scene, .CollisionShapes, enabled ? 1.0 : 0.0)
			px.scene_set_visualization_parameter_mut(game.phys.scene, .CollisionCompounds, enabled ? 1.0 : 0.0)
			px.scene_set_visualization_parameter_mut(game.phys.scene, .SimulationMesh, enabled ? 1.0 : 0.0)
			px.scene_set_visualization_parameter_mut(game.phys.scene, .WorldAxes, enabled ? 1.0 : 0.0)

		}
	}
	im.End()

	if im.Begin("Entities") {
		if im.CollapsingHeader("Raw Entities") {
			clipper: im.ListClipper
			im.ListClipper_Begin(&clipper, i32(game.entity_system.num_entities))

			for im.ListClipper_Step(&clipper) {
				for i in clipper.DisplayStart ..< clipper.DisplayEnd {
					entity := game.entity_system.entities[i]
					im.Text("entity")
					im.BulletText("id %d", entity.id.index)
					im.BulletText("gen %d", entity.id.generation)
				}
			}
		}

		imgui_draw_type :: proc(info_base: runtime.Type_Info, data: rawptr = nil) {
			info_named: runtime.Type_Info_Named
			info_struct: runtime.Type_Info_Struct

			#partial switch info in info_base.variant {
			case runtime.Type_Info_Pointer:
				info_ptr := info_base.variant.(runtime.Type_Info_Pointer)
				info_named = info_ptr.elem.variant.(runtime.Type_Info_Named)
				info_struct = info_named.base.variant.(runtime.Type_Info_Struct)
			case runtime.Type_Info_Named:
				info_named = info_base.variant.(runtime.Type_Info_Named)
				info_struct = info_named.base.variant.(runtime.Type_Info_Struct)
			case:
				return // we don't support this case.
			}

			display_string: cstring

			if data == nil {
				display_string = strings.clone_to_cstring(info_named.name, context.temp_allocator)
			} else {
				display_string = fmt.ctprintf("%s %p", info_named.name, data)
			}

			im.Text(display_string)
			for i in 0 ..< info_struct.field_count {
				name := info_struct.names[i]
				ty := info_struct.types[i]
				offset := info_struct.offsets[i]

				if data == nil {
					im.Text(strings.clone_to_cstring(name, context.temp_allocator))
				} else {
					data_ptr := (cast([^]u8)data)[offset:]

					#partial switch info in ty.variant {
					case runtime.Type_Info_Integer:
						if info.signed {
							im.InputInt(strings.clone_to_cstring(name, context.temp_allocator), (cast(^i32)data_ptr))
						} else {
							im.Text("%s %u", (cast(^uint)data_ptr)^)
						}
					case runtime.Type_Info_Pointer, runtime.Type_Info_Struct:
						imgui_draw_type(ty^, data_ptr)
						continue
					}
				}
			}
			im.Text("")
		}

		for key, subtype_ptr in game.entity_system.subtype_storage {
			storage_raw := subtype_ptr.ptr
			size_t := subtype_ptr.type_info.size

			if im.SmallButton(fmt.ctprintf("Clear All %s", key)) {
				runtime.map_clear_dynamic(&storage_raw.sparse, &storage_raw.sparse_map_info)
				storage_raw.dense.len = 0
			}

			im.SameLine()

			if im.TreeNode(
				fmt.ctprintf("%s Entities (num: %d)", subtype_ptr.type_info.variant.(runtime.Type_Info_Named).name, storage_raw.dense.len),
			) {
				clipper: im.ListClipper
				im.ListClipper_Begin(&clipper, i32(storage_raw.dense.len))

				for im.ListClipper_Step(&clipper) {
					for i in clipper.DisplayStart ..< clipper.DisplayEnd {
						data_ptr := (cast([^]u8)storage_raw.dense.data)[int(i) * size_t:]
						imgui_draw_type(subtype_ptr.type_info, data_ptr)
					}
				}
				im.TreePop()
			}
		}
	}
	im.End()

	if player != nil {
		if im.Begin("Camera") {
			im.InputFloat3("pos", &player.translation)
			im.InputFloat3("vel", &player.velocity)
			im.InputFloat3("pitch yaw", &player.camera_rot)
			im.InputFloat("fov", &player.camera_fov_deg)
			items := [len(ViewState)]cstring{"SceneColor", "SceneDepth", "ShadowDepth", "Raytracing", "DDGIAtlas"}
			im.ComboChar("view", cast(^i32)(&game.view_state), raw_data(&items), len(items))
			im.Checkbox("DDGI update", &game.state.update_ddgi)
			im.Checkbox("DDGI probes", &game.render_state.draw_ddgi_probes)
			im.SliderFloat("DDGI intensity", &game.render_state.ddgi_volume.gpu.intensity, 0.0, 4.0)
			im.SliderFloat("DDGI feedback", &game.render_state.ddgi_volume.gpu.feedback, 0.0, 50.0)
			im.SliderFloat("DDGI depth bias", &game.render_state.ddgi_volume.gpu.depth_bias, -2.0, 4.0)
			im.SliderFloat("DDGI reloc max", &game.render_state.ddgi_volume.gpu.relocation_max, 0.0, 1.5)
			im.SliderFloat("DDGI hysteresis", &game.render_state.ddgi_volume.gpu.hysteresis, 0.9, 0.999)
			im.SliderFloat("DDGI normal bias", &game.render_state.ddgi_volume.gpu.normal_bias, 0.0, 2.0)
			im.SliderFloat("DDGI cheb sharpness", &game.render_state.ddgi_volume.gpu.cheb_sharpness, 1.0, 16.0)
			im.SliderFloat("DDGI ray max", &game.render_state.ddgi_volume.gpu.ray_max, 10.0, 500.0)
			im.SliderFloat("DDGI max radiance", &game.render_state.ddgi_volume.gpu.max_radiance, 0.0, 50.0)
		}
		im.End()
	}

	if im.Begin("Reflection Probes") {
		im.Checkbox("Draw volumes", &game.render_state.draw_reflection_probes)
		// PushID per probe so widgets don't collide on shared labels when there are multiple.
		for &probe, i in get_entities(ReflectionProbe) {
			im.PushIDInt(i32(i))
			im.SeparatorText(fmt.ctprintf("Probe %d", i))
			if im.Button("Recapture") {
				probe.wants_recapture = true // captures next frame, bypassing the auto gate
			}
			im.SliderFloat("Intensity", &probe.intensity, 0.0, 16.0)
			im.SliderFloat("Blend distance", &probe.blend_distance, 0.01, 8.0)
			im.SliderFloat("Debug ball radius", &probe.debug_radius, 0.05, 3.0)
			im.InputFloat3("Position", &probe.translation)
			im.InputFloat3("Half extents", &probe.half_extents)
			im.PopID()
		}
		im.End()
	}

	// Box volume overlay (drawn unconditionally on the flag, regardless of panel state).
	if game.render_state.draw_reflection_probes {
		for &probe in get_entities(ReflectionProbe) {
			reflection_probe_debug_draw_box(&probe)
		}
	}

	if im.Begin("Environment") {
		im.Checkbox("Draw skybox", &game.render_state.draw_skybox)
		dir_vec := game.state.environment.sun_direction
		im.InputFloat3("direction", &dir_vec)
		game.state.environment.sun_direction = dir_vec
		im.ColorEdit3("sun_color", &game.state.environment.sun_color)
		im.ColorEdit3("sky_color", &game.state.environment.sky_color)

		for i in 0 ..< NUM_CASCADES {
			bias := &game.config.shadow_map_biases[i]
			slope_bias := &game.config.shadow_map_slope_biases[i]

			im.InputFloat(fmt.ctprintf("bias %v", i), bias, format = "%.5f")
			im.InputFloat(fmt.ctprintf("slope_bias %v", i), slope_bias, format = "%.5f")
		}

	}
	im.End()

	if (im.Begin("Stats")) {
		smooth_alpha: f32 = 0.99

		if game.frame_times_smooth[0] == 0 {
			game.frame_times_smooth = game.frame_times
		} else {
			game.frame_times_smooth = math.lerp(game.frame_times, game.frame_times_smooth, smooth_alpha)
		}

		fields := reflect.enum_field_names(FrameTimeStats)

		im.Text("%4.f FPS", (1 / game.frame_times_smooth[0]) * 1000)
		for ms, i in game.frame_times_smooth {
			text_proc := i == 0 ? im.Text : im.BulletText // kinda cursed but ok
			text_proc("%s %2.2f ms", fmt.ctprint(fields[i]), ms)
		}
	}
	im.End()

	// if (im.Begin("Skeletal Animation")) {
	// 	im.SliderFloat("sample time", &game.skel_mesh_instance.sample_time, 0.0, 5.0)
	// 	im.SliderFloat("sample rate", &game.skel_mesh_instance.skel_animator.rate, 0.1, 10.0)
	//
	// 	im.Checkbox("Use game time", &game.skel_mesh_instance.use_game_time)
	// 	if game.skel_mesh_instance.use_game_time {
	// 		game.skel_mesh_instance.sample_time = f32(game.live_time)
	// 	}
	//
	// 	im.Text("sample time %f s", game.skel_mesh_instance.sample_time)
	// 	for joint, i in game.skel_mesh_instance.skel_animator.calc_joints {
	// 		if im.CollapsingHeader(fmt.ctprint("Joint", i)) {
	// 			im.InputFloat4("", &[4]f32{joint[0, 0], joint[1, 0], joint[2, 0], joint[3, 0]})
	// 			im.InputFloat4("", &[4]f32{joint[0, 1], joint[1, 1], joint[2, 1], joint[3, 1]})
	// 			im.InputFloat4("", &[4]f32{joint[0, 2], joint[1, 2], joint[2, 2], joint[3, 2]})
	// 			im.InputFloat4("", &[4]f32{joint[0, 3], joint[1, 3], joint[2, 3], joint[3, 3]})
	// 		}
	// 	}
	// }
	// im.End()
}
