package game

import sm "core:container/small_array"
import "core:math/linalg"
import "vendor:glfw"

Action :: enum {
	Jump,
	Fire,
	AltFire,
	Sprint,
	ToggleNoclip,
	LockCamera,
	Fullscreen,
	ExitGame,
    ShowDebug,
	ToggleDoor,
    ReloadScene,
}

Axis :: enum {
	LookUp,
	LookRight,
	MoveForward,
	MoveRight,
	MoveUp,
}

InputSystem :: struct {
	initialized:  bool,
	actions:      [Action]ActionState,
	axes:         [Axis]AxisState, // Yes, I looked it up. Plural of axis is axes. Yargh!!!!
	mouse_locked: bool,
}

init_input_system :: proc(mouse_locked := false) {
	game.input_system.initialized = true
	lock_mouse(mouse_locked)
}

lock_mouse :: proc(lock: bool) {
	assert(game.input_system.initialized)

	game.input_system.mouse_locked = lock
	if lock {
		glfw.SetCursorPos(game.window, 0, 0)

		glfw.SetInputMode(game.window, glfw.RAW_MOUSE_MOTION, 1)
		glfw.SetInputMode(game.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	} else {
		glfw.SetInputMode(game.window, glfw.RAW_MOUSE_MOTION, 0)
		glfw.SetInputMode(game.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
}

toggle_lock_mouse :: proc() {
	assert(game.input_system.initialized)
	lock_mouse(!game.input_system.mouse_locked)
}

MAX_ACTION_STATE_KEYS :: 2
MAX_ACTION_STATE_MOUSE :: 2
MAX_ACTION_STATE_JOYSTICK :: 2

ActionState :: struct {
	key_codes:      sm.Small_Array(MAX_ACTION_STATE_KEYS, i32),
	mouse_codes:    sm.Small_Array(MAX_ACTION_STATE_KEYS, i32),
	previous_state: bool,
	current_state:  bool,
}

add_action_key_mapping :: proc(action: Action, glfw_key_code: i32) {
	assert(game.input_system.initialized)
	sm.append(&game.input_system.actions[action].key_codes, glfw_key_code)
}

add_action_mouse_mapping :: proc(action: Action, glfw_key_code: i32) {
	assert(game.input_system.initialized)
	sm.append(&game.input_system.actions[action].mouse_codes, glfw_key_code)
}

// Returns true if the action is pressed, false if released.
// If you want to detect when an input is pressed and released in an immediate-mode style,
// use action_just_pressed and action_just_released.
action_is_pressed :: proc(action: Action) -> bool {
	assert(game.input_system.initialized)
	state := game.input_system.actions[action]
	return state.current_state
}

// This is an immediate-mode style interface, this returns true if the
// action state from the previous frame doesn't match, and if the action is pressed.
action_just_pressed :: proc(action: Action) -> bool {
	assert(game.input_system.initialized)
	state := game.input_system.actions[action]

	return state.current_state && (state.current_state != state.previous_state)
}

// This is an immediate-mode style interface, this returns true if the
// action state from the previous frame doesn't match, and if the action is released.
action_just_released :: proc(action: Action) -> bool {
	assert(game.input_system.initialized)
	state := game.input_system.actions[action]

	return !state.current_state && (state.current_state != state.previous_state)
}


MAX_AXIS_STATE_KEYS :: 4
MAX_AXIS_STATE_MOUSE :: 2
MAX_AXIS_STATE_JOYSTICK :: 2

AxisCodeValue :: struct {
	key_code: i32,
	value:    f64,
}

AxisState :: struct {
	keys:         sm.Small_Array(MAX_ACTION_STATE_KEYS, AxisCodeValue),
	read_mouse_x: bool,
	read_mouse_y: bool,
	value:        f64,
}

add_axis_key_mapping :: proc(axis: Axis, glfw_key_code: i32, value: f64) {
	assert(game.input_system.initialized)
	code_value := AxisCodeValue {
		key_code = glfw_key_code,
		value    = value,
	}

	sm.append(&game.input_system.axes[axis].keys, code_value)
}

add_axis_mouse_axis :: proc(axis: Axis, mouse_x: bool = false, mouse_y: bool = false) {
	assert(game.input_system.initialized)
	game.input_system.axes[axis].read_mouse_x = mouse_x
	game.input_system.axes[axis].read_mouse_y = mouse_y
}

axis_get_value :: proc(axis: Axis) -> f64 {
	assert(game.input_system.initialized)
	return game.input_system.axes[axis].value
}

axis_get_2d_normalized :: proc(axis_x, axis_y: Axis) -> (f64, f64) {
	assert(game.input_system.initialized)
	a := game.input_system.axes[axis_x].value
	b := game.input_system.axes[axis_y].value

	normalized := linalg.normalize0([2]f64{a, b})
	return normalized[0], normalized[1]
}

simulate_input :: proc() {
	assert(game.input_system.initialized)
	mouse_x, mouse_y := glfw.GetCursorPos(game.window)

	for &action_state in game.input_system.actions {
		pressed := false

		for i in 0 ..< action_state.key_codes.len {
			code := action_state.key_codes.data[i]
			pressed = pressed || glfw.PRESS == glfw.GetKey(game.window, code)
		}

		if game.input_system.mouse_locked {
			for i in 0 ..< action_state.mouse_codes.len {
				code := action_state.mouse_codes.data[i]
				pressed = pressed || glfw.PRESS == glfw.GetMouseButton(game.window, code)
			}
		}

		action_state.previous_state = action_state.current_state
		action_state.current_state = pressed
	}

	for &axis_state in game.input_system.axes {
		value: f64 = 0.0

		for i in 0 ..< axis_state.keys.len {
			axis_key := axis_state.keys.data[i]
			value += glfw.GetKey(game.window, axis_key.key_code) == glfw.PRESS ? axis_key.value : 0.0
		}

		for i in 0 ..< axis_state.keys.len {
			axis_key := axis_state.keys.data[i]
			value += glfw.GetKey(game.window, axis_key.key_code) == glfw.PRESS ? axis_key.value : 0.0
		}

		// Only read input if the mouse is locked, for reasons...
		if game.input_system.mouse_locked {
			if axis_state.read_mouse_x {
				value += mouse_x
			}

			if axis_state.read_mouse_y {
				value += mouse_y
			}
		}

		axis_state.value = value
	}

	// Reset mouse position for next frame.
	if game.input_system.mouse_locked {
		glfw.SetCursorPos(game.window, 0, 0)
	}
}

// TODO: Localization?
get_name_for_code :: proc(glfw_code: int) -> string {
	switch glfw_code {
	/** Printable keys **/

	/* Named printable keys */
	case glfw.KEY_SPACE:
		return "Space"
	case glfw.KEY_APOSTROPHE:
		return "Apostrophe"
	case glfw.KEY_COMMA:
		return "Comma"
	case glfw.KEY_MINUS:
		return "Minus"
	case glfw.KEY_PERIOD:
		return "Period"
	case glfw.KEY_SLASH:
		return "Slash"
	case glfw.KEY_SEMICOLON:
		return "Semicolon"
	case glfw.KEY_EQUAL:
		return "Equal"
	case glfw.KEY_LEFT_BRACKET:
		return "Left Bracket"
	case glfw.KEY_BACKSLASH:
		return "Backslash"
	case glfw.KEY_RIGHT_BRACKET:
		return "Right Bracket"
	case glfw.KEY_GRAVE_ACCENT:
		return "Grave Accent"
	case glfw.KEY_WORLD_1:
		return "World 1"
	case glfw.KEY_WORLD_2:
		return "World 2"

	/* Alphanumeric characters */
	case glfw.KEY_0:
		return "0"
	case glfw.KEY_1:
		return "1"
	case glfw.KEY_2:
		return "2"
	case glfw.KEY_3:
		return "3"
	case glfw.KEY_4:
		return "4"
	case glfw.KEY_5:
		return "5"
	case glfw.KEY_6:
		return "6"
	case glfw.KEY_7:
		return "7"
	case glfw.KEY_8:
		return "8"
	case glfw.KEY_9:
		return "9"

	case glfw.KEY_A:
		return "A"
	case glfw.KEY_B:
		return "B"
	case glfw.KEY_C:
		return "C"
	case glfw.KEY_D:
		return "D"
	case glfw.KEY_E:
		return "E"
	case glfw.KEY_F:
		return "F"
	case glfw.KEY_G:
		return "G"
	case glfw.KEY_H:
		return "H"
	case glfw.KEY_I:
		return "I"
	case glfw.KEY_J:
		return "J"
	case glfw.KEY_K:
		return "K"
	case glfw.KEY_L:
		return "L"
	case glfw.KEY_M:
		return "M"
	case glfw.KEY_N:
		return "N"
	case glfw.KEY_O:
		return "O"
	case glfw.KEY_P:
		return "P"
	case glfw.KEY_Q:
		return "Q"
	case glfw.KEY_R:
		return "R"
	case glfw.KEY_S:
		return "S"
	case glfw.KEY_T:
		return "T"
	case glfw.KEY_U:
		return "U"
	case glfw.KEY_V:
		return "V"
	case glfw.KEY_W:
		return "W"
	case glfw.KEY_X:
		return "X"
	case glfw.KEY_Y:
		return "Y"
	case glfw.KEY_Z:
		return "Z"


	/** Function keys **/

	/* Named non-printable keys */
	case glfw.KEY_ESCAPE:
		return "Escape"
	case glfw.KEY_ENTER:
		return "Enter"
	case glfw.KEY_TAB:
		return "Tab"
	case glfw.KEY_BACKSPACE:
		return "Backspace"
	case glfw.KEY_INSERT:
		return "Insert"
	case glfw.KEY_DELETE:
		return "Delete"
	case glfw.KEY_RIGHT:
		return "Right"
	case glfw.KEY_LEFT:
		return "Left"
	case glfw.KEY_DOWN:
		return "Down"
	case glfw.KEY_UP:
		return "Up"
	case glfw.KEY_PAGE_UP:
		return "Page Up"
	case glfw.KEY_PAGE_DOWN:
		return "Page Down"
	case glfw.KEY_HOME:
		return "Home"
	case glfw.KEY_END:
		return "End"
	case glfw.KEY_CAPS_LOCK:
		return "Caps Lock"
	case glfw.KEY_SCROLL_LOCK:
		return "Scroll Lock"
	case glfw.KEY_NUM_LOCK:
		return "Num Lock"
	case glfw.KEY_PRINT_SCREEN:
		return "Print Screen"
	case glfw.KEY_PAUSE:
		return "Pause"

	/* Function keys */
	case glfw.KEY_F1:
		return "F1"
	case glfw.KEY_F2:
		return "F2"
	case glfw.KEY_F3:
		return "F3"
	case glfw.KEY_F4:
		return "F4"
	case glfw.KEY_F5:
		return "F5"
	case glfw.KEY_F6:
		return "F6"
	case glfw.KEY_F7:
		return "F7"
	case glfw.KEY_F8:
		return "F8"
	case glfw.KEY_F9:
		return "F9"
	case glfw.KEY_F10:
		return "F10"
	case glfw.KEY_F11:
		return "F11"
	case glfw.KEY_F12:
		return "F12"
	case glfw.KEY_F13:
		return "F13"
	case glfw.KEY_F14:
		return "F14"
	case glfw.KEY_F15:
		return "F15"
	case glfw.KEY_F16:
		return "F16"
	case glfw.KEY_F17:
		return "F17"
	case glfw.KEY_F18:
		return "F18"
	case glfw.KEY_F19:
		return "F19"
	case glfw.KEY_F20:
		return "F20"
	case glfw.KEY_F21:
		return "F21"
	case glfw.KEY_F22:
		return "F22"
	case glfw.KEY_F23:
		return "F23"
	case glfw.KEY_F24:
		return "F24"
	case glfw.KEY_F25:
		return "F25"

	/* Keypad numbers */
	case glfw.KEY_KP_0:
		return "Keypad 0"
	case glfw.KEY_KP_1:
		return "Keypad 1"
	case glfw.KEY_KP_2:
		return "Keypad 2"
	case glfw.KEY_KP_3:
		return "Keypad 3"
	case glfw.KEY_KP_4:
		return "Keypad 4"
	case glfw.KEY_KP_5:
		return "Keypad 5"
	case glfw.KEY_KP_6:
		return "Keypad 6"
	case glfw.KEY_KP_7:
		return "Keypad 7"
	case glfw.KEY_KP_8:
		return "Keypad 8"
	case glfw.KEY_KP_9:
		return "Keypad 9"

	/* Keypad named function keys */
	case glfw.KEY_KP_DECIMAL:
		return "Keypad Decimal"
	case glfw.KEY_KP_DIVIDE:
		return "Keypad Divide"
	case glfw.KEY_KP_MULTIPLY:
		return "Keypad Multiply"
	case glfw.KEY_KP_SUBTRACT:
		return "Keypad Subtract"
	case glfw.KEY_KP_ADD:
		return "Keypad Add"
	case glfw.KEY_KP_ENTER:
		return "Keypad Enter"
	case glfw.KEY_KP_EQUAL:
		return "Keypad Equal"

	/* Modifier keys */
	case glfw.KEY_LEFT_SHIFT:
		return "Left Shift"
	case glfw.KEY_LEFT_CONTROL:
		return "Left Control"
	case glfw.KEY_LEFT_ALT:
		return "Left Alt"
	case glfw.KEY_LEFT_SUPER:
		return "Left Super"
	case glfw.KEY_RIGHT_SHIFT:
		return "Right Shift"
	case glfw.KEY_RIGHT_CONTROL:
		return "Right Control"
	case glfw.KEY_RIGHT_ALT:
		return "Right Alt"
	case glfw.KEY_RIGHT_SUPER:
		return "Right Super"
	case glfw.KEY_MENU:
		return "Menu"
	case:
		return "Uknown"
	}
}
