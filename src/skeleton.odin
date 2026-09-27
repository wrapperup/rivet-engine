package game

import "core:math"
import "core:math/linalg"

JointId :: distinct u32
JointMatrix :: Mat4x4

// Coordinate Systems:
// Local (ls) - Parent is at origin
// Model (ms) - Model/Root joint is at origin
// Joint (js) - Joint is at origin

Skeleton :: struct {
	joint_count:           int,
	joint_tree:            [dynamic][dynamic]JointId,

	// Stores the joint's bind pose (in local space)
	bind_matrices_ls:      [dynamic]JointMatrix,

	// A matrix describing the transformation from model space to joint space.
	// Useful for transforming vertices in model space to joint space.
	inverse_bind_matrices: [dynamic]JointMatrix,

	// Base static buffers representing the skeleton on the GPU.
	buffers: GPUSkelMeshBuffers
}

JointTrack :: struct {
	keyframes_translation: [dynamic]Vec3,
	keyframes_scale:       [dynamic]Vec3,
	keyframes_rotation:    [dynamic]quaternion128,
}

sample_track :: proc(animation: ^JointTrack, key_a: u32, key_b: u32, a: f32) -> JointMatrix {
	joint: JointMatrix

	if key_a != key_b {
		translation := linalg.lerp(animation.keyframes_translation[key_a], animation.keyframes_translation[key_b], a)
		rotation := linalg.quaternion_slerp(animation.keyframes_rotation[key_a], animation.keyframes_rotation[key_b], a)
		scale := linalg.lerp(animation.keyframes_scale[key_a], animation.keyframes_scale[key_b], a)

		rotation = linalg.quaternion_normalize(rotation)

		joint = linalg.matrix4_translate(translation)
		joint *= linalg.matrix4_from_quaternion(rotation)
		joint *= linalg.matrix4_scale(scale)
	}

	return joint
}

SkeletalAnimation :: struct {
	fps:              f32,
	keyframe_count:   u32,
	joint_animations: [dynamic]JointTrack,
}

SkeletonAnimator :: struct {
	skeleton:      ^Skeleton,
	animation:     ^SkeletalAnimation,
	rate:          f32,

	// Current state
	current_frame: f32,
	calc_joints:   [dynamic]JointMatrix,
}

init_skeleton_animator :: proc(animator: ^SkeletonAnimator, skeleton: ^Skeleton, animation: ^SkeletalAnimation, rate: f32 = 1) {
	assert(skeleton != nil)
	assert(animation != nil)

	animator.skeleton = skeleton
	animator.animation = animation
	animator.rate = rate

	resize(&animator.calc_joints, skeleton.joint_count)
}

sample_animation :: proc(animator: ^SkeletonAnimator, time_s: f32) {
	assert(len(animator.animation.joint_animations) == animator.skeleton.joint_count)

	// TODO: Better solution pls?
	sampled_joints: [256]JointMatrix

	frame_idx := time_s * animator.rate * animator.animation.fps
	frame_idx = math.mod(frame_idx, f32(animator.animation.keyframe_count))

	key_a := u32(math.floor_f32(frame_idx))
	key_b := key_a + 1

	assert(key_a != key_b)

	key_a = key_a % animator.animation.keyframe_count
	key_b = key_b % animator.animation.keyframe_count

	animator.current_frame = frame_idx

	a := frame_idx - (f32(key_a))

	for &joint_anim, i in animator.animation.joint_animations {
		sampled_joints[i] = sample_track(&joint_anim, key_a, key_b, a)
	}

	calc_joint_matrices(animator.skeleton, sampled_joints[:animator.skeleton.joint_count], animator.calc_joints[:])
}

// Transforms a list of joints in local space to joint space. Usually for applying to vertices for skinning.
calc_joint_matrices :: proc(skeleton: ^Skeleton, in_joints_ls: []JointMatrix, out_joints_js: []JointMatrix) {
	// Root joint is assumed to be at the origin in model space (since... it's the root)
	calc_joint_matrix(skeleton, in_joints_ls, 0, linalg.identity_matrix(JointMatrix), out_joints_js)
}

// TODO: Make this more efficient, it's recursive.
calc_joint_matrix :: proc(
	skeleton: ^Skeleton,
	in_joints_ls: []JointMatrix,
	in_joint_id: JointId,
	parent_joint_ms: JointMatrix,
	out_joints_js: []JointMatrix,
) {
	joint_ls := in_joints_ls[in_joint_id]
	joint_ms := parent_joint_ms * joint_ls

	inverse_bind_matrix := skeleton.inverse_bind_matrices[in_joint_id]

	out_joints_js[in_joint_id] = joint_ms * inverse_bind_matrix

	for &child_joint_id in skeleton.joint_tree[in_joint_id] {
		calc_joint_matrix(skeleton, in_joints_ls, child_joint_id, joint_ms, out_joints_js)
	}
}
