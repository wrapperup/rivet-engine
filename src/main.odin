package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:path/filepath"
import "core:sys/info"
import "core:sys/windows"
import "core:time"

import glfw "vendor:glfw"
import ma "vendor:miniaudio"
import vk "vendor:vulkan"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import livepatch "deps:odin_livepatch/livepatch"

import im_gfx "gfx/imgui_backend"

import "gfx"

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1

DEBUG :: ODIN_DEBUG

start_live_time := time.tick_now()
game: ^Game

main :: proc() {
	when ODIN_OS == .Windows {
		// Use UTF-8 for console output (fixes emojis/unicode/utf-8 shenanigans)
		windows.SetConsoleOutputCP(.UTF8)
	}

	// init
	{
		reserved_threads := 4
		physical, logical, ok := info.cpu_core_count()
		worker_threads := math.max(physical - reserved_threads, 1)

		game = new(Game)
		game.config = default_game_config()

		if !init_asset_system() {
			fmt.eprintln("Failed to load assets!")
			free(game)
			game = nil
			return
		}

		if !glfw.Init() {
			log.error("GLFW could not be initialized.")
			shutdown_asset_system()
			free(game)
			game = nil
			return
		}

		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.SwapInterval(1)

		window := glfw.CreateWindow(1920, 1080, "Vulkan", nil, nil)
		if window == nil {
			log.error("The game window could not be created.")
			glfw.Terminate()
			shutdown_asset_system()
			free(game)
			game = nil
			return
		}

		game.window = window

		game.renderer = gfx.init({window = game.window, msaa_samples = ._4, enable_validation_layers = true, enable_logs = true})
		if game.renderer == nil {
			log.error("Graphics could not be initialized.")
			return
		}

		init_input_system()
		init_sound_system()

		// Physics
		physics_init()

		// Rendering
		{
			init_game_renderer()
			configure_im()
		}

		if !init_entity_system() {
			log.error("Entity storage could not be initialized.")
			return
		}

		// Input
		{
			add_action_key_mapping(.Jump, glfw.KEY_SPACE)
			add_action_key_mapping(.Sprint, glfw.KEY_LEFT_SHIFT)
			add_action_key_mapping(.ToggleNoclip, glfw.KEY_V)
			add_action_key_mapping(.LockCamera, glfw.KEY_M)
			add_action_key_mapping(.ShowDebug, glfw.KEY_N)
			add_action_key_mapping(.Fullscreen, glfw.KEY_F10)
			add_action_key_mapping(.ExitGame, glfw.KEY_ESCAPE)
			add_action_key_mapping(.ReloadScene, glfw.KEY_R)
			add_action_key_mapping(.Livepatch, glfw.KEY_F5)

			add_action_mouse_mapping(.Fire, glfw.MOUSE_BUTTON_LEFT)
			add_action_mouse_mapping(.AltFire, glfw.MOUSE_BUTTON_RIGHT)

			add_axis_key_mapping(.MoveForward, glfw.KEY_W, 1.0)
			add_axis_key_mapping(.MoveForward, glfw.KEY_S, -1.0)
			add_axis_key_mapping(.MoveRight, glfw.KEY_D, 1.0)
			add_axis_key_mapping(.MoveRight, glfw.KEY_A, -1.0)

			add_axis_mouse_axis(.LookRight, mouse_x = true)
			add_axis_mouse_axis(.LookUp, mouse_y = true)
		}

		// TODO: TEMP: Register entity types automatically from metaprogram.
		{
			register_entity_subtypes()
		}

		// Scene
		{
			game.render_state.draw_sky = true

			player := new_entity(Player)
			init_player(player)
			player.translation = {3, 3.7, 5}
			player.camera_rot = {-0.4, -0.6, 0}
			player.camera_fov_deg = 65

			grid_size: f32 = 3.0

			sound_source := new_entity(SoundSource)
			init_sound_source(sound_source, "assets/audio/ambient/a_outdoors_birds.wav", true, 0.1, false, 0.5)

			game.update_physics = false
			game.state = GameState {
				player_id = entity_id_of(player),
				environment = Environment {
					sun_direction = linalg.normalize(Vec3{12, 15, 10}),
					sun_color = 2.0,
					sky_color = 1.0,
					atmosphere = default_atmosphere_settings(),
				},
				update_ddgi = true, // DDGI must run for reflection capture (and GI) to populate
			}

			game.ball_mesh, _ = load_gpu_mesh_from_file("assets/meshes/static/demo_ball.glb", context.temp_allocator)
			defer_destroy_gpu_mesh(&gfx.r_ctx.global_arena, game.ball_mesh)

			for i in 0 ..< 256 {
				ball := new_entity(Ball)
				init_ball(ball, {(rand.float32() - 0.5) * 0.01 * f32(i) + 2, 5.0 * f32(i), (rand.float32() - 0.5) * 0.01 * f32(i)}, 0)
			}

			load_scene_from_file(&game.state.current_scene, "assets/meshes/static/scene_map_test.glb")
		}

		game.frame_time_start = time.tick_now()
		game.initialized = true

		glfw.ShowWindow(window)
	}

	source_root, source_path_error := filepath.abs("src", context.temp_allocator)
	assert(source_path_error == nil)
	source_watcher, watch_error := livepatch.watch_start(source_root)
	if watch_error != nil {
		fmt.eprintln("Livepatch watcher failed to start:", watch_error)
	}
	defer livepatch.watch_stop(&source_watcher)

	// game loop
	for {
		if game == nil || !game.initialized {
			break
		}

		patch_requested := action_just_pressed(.Livepatch)
		if changed, poll_error := livepatch.watch_poll(&source_watcher); poll_error != nil {
			fmt.eprintln("Livepatch watcher failed:", poll_error)
			livepatch.watch_stop(&source_watcher)
		} else if changed {
			patch_requested = true
		}
		if patch_requested {
			path, err := filepath.abs("build_livepatch.bat", context.temp_allocator)
			assert(err == nil)
			if patch_error := livepatch.patch(path); patch_error != nil {
				fmt.eprintln("Livepatch failed:", patch_error)
				livepatch.error_delete(patch_error)
			} else {
				fmt.println("Patched.")
			}
		}

		if !update() do break

		update :: proc() -> bool {
			scope_stat_time(.Total)

			if glfw.GetWindowAttrib(game.window, glfw.FOCUSED) > 0 {
				ma.engine_set_volume(&game.sound_system.sound_engine, 1.0)
			} else {
				ma.engine_set_volume(&game.sound_system.sound_engine, 0.0)
			}

			game.live_time = f64(time.tick_since(start_live_time)) / f64(time.Second)

			game.delta_time = f64(time.tick_since(game.frame_time_start)) / f64(time.Second)
			game.frame_time_start = time.tick_now()

			dt := game.delta_time

			if glfw.WindowShouldClose(game.window) {
				return false
			}

			glfw.PollEvents()

			if glfw.GetWindowAttrib(game.window, glfw.ICONIFIED) == 0 {
				im_glfw.NewFrame()
				im_gfx.gfx_imgui_new_frame()
				im.NewFrame()
			}

			simulate_input()
			if action_just_pressed(.ExitGame) {
				return false
			}

			if action_just_pressed(.ReloadScene) {
				reload_scene(&game.state.current_scene)
			}

			when ODIN_DEBUG {
				check_scene_hotreload(&game.state.current_scene)
			}

			// Update Game State
			{
				scope_stat_time(.GameState)

				player := get_entity(game.state.player_id)

				for &ball in get_entities(Ball) {
					update_ball_fixed(&ball)
				}

				update_player(player, dt)
			}

			// Update Physics
			{
				scope_stat_time(.Physics)

				if game.update_physics {
					physics_step(f32(dt))
				}
			}

			if glfw.GetWindowAttrib(game.window, glfw.ICONIFIED) == 0 {
				update_imgui()
				draw()
			}

			// UI
			{
				ui_text("N: Debug   M: Lock Mouse", pos = {40, 70}, size = 48, anchor = 0, outline_width = 4, align = .Left)

                text := "Livepatched"
				text_size := measure_text(text, size = 64)
				ui_rect(0, {text_size.x + 12 + 32, text_size.y + 12 + 16}, 1, 16)
				ui_text(text, pos = {0, 16 + 6}, size = 64, anchor = .5, outline_width = 8, align = .Center)
			}

			if action_just_pressed(.Fullscreen) {
				game.window_state.is_fullscreen = !game.window_state.is_fullscreen

				monitor := glfw.GetPrimaryMonitor()
				mode := glfw.GetVideoMode(monitor)

				if game.window_state.is_fullscreen {
					x, y := glfw.GetWindowPos(game.window)
					w, h := glfw.GetWindowSize(game.window)

					game.window_state.windowed_pos = {x, y}
					game.window_state.windowed_size = {w, h}

					glfw.SetWindowMonitor(game.window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
				} else {
					glfw.SetWindowMonitor(
						game.window,
						nil,
						game.window_state.windowed_pos.x,
						game.window_state.windowed_pos.y,
						game.window_state.windowed_size.x,
						game.window_state.windowed_size.y,
						mode.refresh_rate,
					)
				}
			}

			return true
		}

		free_all(context.temp_allocator)
	}

	// shutdown
	{
		if game == nil do return

		if game.renderer != nil {
			gfx.vk_check(vk.DeviceWaitIdle(gfx.r_ctx.device))
			scene_shutdown(&game.state.current_scene)
		}

		shutdown_entity_system()
		physics_shutdown()
		shutdown_sound_system()

		if game.renderer != nil {
			renderer_shutdown()
			gfx.shutdown()
			game.renderer = nil
		}

		shutdown_asset_system()
		if game.window != nil {
			glfw.DestroyWindow(game.window)
		}
		glfw.Terminate()

		game = nil
		free(game)
	}
}
