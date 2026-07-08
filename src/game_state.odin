package game

import "base:intrinsics"
import "core:time"

import glfw "vendor:glfw"

import b3 "vendor:box3d"

import gfx "gfx"

NUM_FRAME_AVG_COUNT :: 10

PhysicsContext :: struct {
	world: b3.WorldId,
}

ViewState :: enum {
	SceneColor,
	SceneDepth,
	ShadowDepth,
	Raytracing,
	DDGIAtlas,
}

SkeletalMeshInstance :: struct {
	preskinned_vertex_buffers: [gfx.FRAME_OVERLAP]gfx.GPUBuffer(Vertex),
	joint_matrices_buffers:    [gfx.FRAME_OVERLAP]gfx.GPUBuffer(Mat4x4),
	skel:                      ^Skeleton,
}

init_skeletal_mesh_instance :: proc(skel: ^Skeleton, anim: ^SkeletalAnimation) -> SkeletalMeshInstance {
	instance := SkeletalMeshInstance {
		skel = skel,
	}

	for i in 0 ..< gfx.FRAME_OVERLAP {
		instance.joint_matrices_buffers[i] = gfx.create_buffer(
			Mat4x4,
			instance.skel.joint_count,
			.DynUniform, // TODO: This doesn't make any sense. We use this buffer through BDA...
		)
		instance.preskinned_vertex_buffers[i] = gfx.create_buffer(Vertex, instance.skel.buffers.vertex_count, .DynUniform)

		gfx.defer_destroy_buffer(&gfx.r_ctx.global_arena, instance.joint_matrices_buffers[i])
		gfx.defer_destroy_buffer(&gfx.r_ctx.global_arena, instance.preskinned_vertex_buffers[i])
	}

	return instance
}

Game :: struct {
	window:             glfw.WindowHandle,
	window_state:       struct {
		is_fullscreen: bool,
		windowed_pos:  [2]i32,
		windowed_size: [2]i32,
	},
	config:             GameConfig,
	state:              GameState,
	editor:             Editor_State,
	renderer:           ^gfx.Renderer,

	// Systems
	entity_system:      EntitySystem,
	input_system:       InputSystem,
	sound_system:       SoundSystem,
	//asset_system:       AssetSystem,
	view_state:         ViewState,
	render_state:       RenderState,

	// Physics
	phys:               PhysicsContext,

	// Stats
	frame_times:        [len(FrameTimeStats)]f32,
	frame_times_smooth: [len(FrameTimeStats)]f32,
	frame_times_start:  [len(FrameTimeStats)]time.Tick,
	frame_time_start:   time.Tick,
	delta_time:         f64,
	live_time:          f64,

	// Debug
	show_imgui:         bool,

    // TEMP storage
    ball_mesh: GPUMeshBuffers,
    update_physics: bool,
}

FrameTimeStats :: enum {
	Total,
	GameState,
	Imgui,
	Physics,
	Render,
}

@(deferred_in = end_scope_stat_time)
scope_stat_time :: proc(stat_type: FrameTimeStats) {
	start_scope_stat_time(stat_type)
}

start_scope_stat_time :: proc(stat_type: FrameTimeStats) {
	game.frame_times_start[stat_type] = time.tick_now()
}

end_scope_stat_time :: proc(stat_type: FrameTimeStats) {
	game.frame_times[stat_type] = f32(time.tick_since(game.frame_times_start[stat_type])) / f32(time.Millisecond)
}

GameState :: struct {
	current_scene: Scene,
	environment:   Environment,
	player_id:     TypedEntityId(Player),
	update_ddgi:   bool,
	update_reflections: bool,
}

Environment :: struct {
	sun_color:     Vec3,
	sky_color:     Vec3,
	sun_direction: Vec3,
}

PlayerController :: struct {
	input: struct {
		forward: bool,
		back:    bool,
		left:    bool,
		right:   bool,
		jump:    bool,
		crouch:  bool,
	},
}
