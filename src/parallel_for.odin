package game

import "core:thread"

POOL: thread.Pool
THREAD_COUNT: int = 0

Parallel_For_Procedure :: proc(index: int, data: rawptr = nil)

Parallel_For_Data :: struct {
	data:          rawptr,
	procedure:     Parallel_For_Procedure,
	iter_per_task: int,
	remainder:     int,
}

PARALLEL_FOR_DATA_PTR: ^Parallel_For_Data = nil

parallel_for_proc :: proc(t: thread.Task) {
	for i in 0 ..< PARALLEL_FOR_DATA_PTR.iter_per_task {
		PARALLEL_FOR_DATA_PTR.procedure(i + t.user_index, PARALLEL_FOR_DATA_PTR.data)
	}
}

parallel_for_proc_rem :: proc(t: thread.Task) {
	for i in 0 ..< PARALLEL_FOR_DATA_PTR.remainder {
		PARALLEL_FOR_DATA_PTR.procedure(i + t.user_index, PARALLEL_FOR_DATA_PTR.data)
	}
}

parallel_for :: proc(length: int, procedure: Parallel_For_Procedure, data: rawptr = nil) {
	iter_per_task := length / THREAD_COUNT
	remainder := length % THREAD_COUNT

	parallel_for_data := Parallel_For_Data {
		data          = data,
		procedure     = procedure,
		iter_per_task = iter_per_task,
		remainder     = remainder,
	}

	assert(PARALLEL_FOR_DATA_PTR == nil)

	PARALLEL_FOR_DATA_PTR = &parallel_for_data

	// Not even
	if remainder > 0 {
		for i in 0 ..< THREAD_COUNT - 1 {
			// be mindful of the allocator used for tasks. The allocator needs to be thread safe, or be owned by the task for exclusive use 
			thread.pool_add_task(
				&POOL,
				allocator = context.allocator,
				procedure = parallel_for_proc,
				data = nil,
				user_index = i * iter_per_task,
			)
		}

		// Add a task for the remainder.
		thread.pool_add_task(
			&POOL,
			allocator = context.allocator,
			procedure = parallel_for_proc_rem,
			data = nil,
			user_index = (THREAD_COUNT - 1) * iter_per_task,
		)
	} else {
		// Evenly cut between all threads
		for i in 0 ..< THREAD_COUNT {
			// be mindful of the allocator used for tasks. The allocator needs to be thread safe, or be owned by the task for exclusive use 
			thread.pool_add_task(
				&POOL,
				allocator = context.allocator,
				procedure = parallel_for_proc,
				data = nil,
				user_index = i,
			)
		}
	}

	thread.pool_start(&POOL)
	thread.pool_finish(&POOL)

	PARALLEL_FOR_DATA_PTR = nil
}


init_parallel_for_thread_pool :: proc(thread_count: int) {
	assert(!POOL.is_running)

	THREAD_COUNT = thread_count
	thread.pool_init(&POOL, allocator = context.allocator, thread_count = thread_count)
}

destroy_parallel_for_thread_pool :: proc() {
	thread.pool_destroy(&POOL)
}
