package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:sys/info"
import "core:sys/windows"
import "core:time"

import glfw "vendor:glfw"
import ma "vendor:miniaudio"

import im "deps:odin-imgui"
import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import im_gfx "gfx/imgui_backend"

import "gfx"

// When compiling a hotreload DLL, enable this.
HOTRELOADABLE :: #config(HOTRELOADABLE, false)

main :: proc() {
	when ODIN_OS == .Windows {
		// Use UTF-8 for console output (fixes emojis/unicode/utf-8 shenanigans)
		windows.SetConsoleOutputCP(.UTF8)
	}

	LOG_OPTIONS :: log.Options{.Level}

	context.logger = log.create_console_logger(opt = LOG_OPTIONS)

	when HOTRELOADABLE {
		main_game()
	}
}

DEBUG :: ODIN_DEBUG

start_live_time := time.tick_now()

game: ^Game

@(export)
game_init :: proc() {
	reserved_threads := 4
	physical, logical, ok := info.cpu_core_count()
	worker_threads := math.max(physical - reserved_threads, 1)

	if !load_generated_assets() {
		fmt.eprintln("Failed to load assets!")
	}

	glfw.Init()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.SwapInterval(1)

	window := glfw.CreateWindow(1920, 1080, "Vulkan", nil, nil)

	game = new(Game)
	game.config = default_game_config()
	glfw.Init()

	game.window = window

	game.renderer = gfx.init({window = game.window, msaa_samples = ._4, enable_validation_layers = true, enable_logs = true})
	if game.renderer == nil {
		log.error("Graphics could not be initialized.")
		return
	}

	// init_entity_system()
	init_input_system()
	init_sound_system()
	// init_asset_system()

	// Physics
	physics_init()

	// Rendering
	{
		init_game_renderer()
		configure_im()
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
        register_entity_subtype(StaticMesh, static_mesh_destroy)
        register_entity_subtype(ReflectionProbe, reflection_probe_destroy)
        register_entity_subtype(DDGIVolume, ddgi_volume_destroy)
        register_entity_subtype(SoundSource, destroy_sound_source)
        register_entity_subtype(PointLight)
        register_entity_subtype(Player)
        register_entity_subtype(Ball)
    }

	// Scene
	{
		game.render_state.draw_skybox = true

		player := new_entity(Player)
		init_player(player)
		player.translation = {3, 3.7, 5}
		player.camera_rot = {-0.4, -0.6, 0}
		player.camera_fov_deg = 65

		grid_size: f32 = 3.0

		sound_source := new_entity(SoundSource)
		init_sound_source(sound_source, .a_outdoors_birds, true, 0.1, false, 0.5)

        game.update_physics = false
		game.state = GameState {
			player_id = entity_id_of(player),
			environment = Environment{sun_direction = linalg.normalize(Vec3{12, 15, 10}), sun_color = 2.0, sky_color = 1.0},
			update_ddgi = true, // DDGI must run for reflection capture (and GI) to populate
		}

        game.ball_mesh, _ = load_gpu_mesh_from_file(asset_path(.demo_ball))

        for i in 0 ..< 256 {
		ball := new_entity(Ball)
        init_ball(ball, {
			(rand.float32() - 0.5) * 0.01 * f32(i) + 2,
			5.0 * f32(i),
			(rand.float32() - 0.5) * 0.01 * f32(i),
        }, 0)
	}

		// Load AFTER `game.state = GameState{...}` — that assignment replaces the whole struct,
		// so setting current_scene before it just gets wiped (source -> "", arenas -> zero).
		load_scene_from_file(&game.state.current_scene, asset_path(.scene_map_test))
	}

	game.frame_time_start = time.tick_now()

	glfw.ShowWindow(window)
}

@(export)
game_memory :: proc() -> rawptr {
	return game
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(game)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	glfw.Init()

	game = cast(^Game)mem
	glfw.MakeContextCurrent(game.window)
	gfx.set_renderer(game.renderer)
	lock_mouse(game.input_system.mouse_locked)

	gfx.load_vulkan_addresses()

	im.SetCurrentContext(game.render_state.imgui_ctx)

	fmt.println("Hot reloaded!")
    glfw.SetWindowAttrib(game.window, glfw.FLOATING, 1)
    glfw.SetWindowAttrib(game.window, glfw.FLOATING, 0)
    glfw.FocusWindow(game.window)
}

@(export)
game_update :: proc() -> bool {
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

	if action_just_pressed(.Fullscreen) {
		//
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

@(export)
game_shutdown :: proc() {
	physics_shutdown()

	renderer_shutdown()
}
