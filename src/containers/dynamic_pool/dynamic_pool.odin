package containers

import "core:mem"

Dynamic_Pool :: struct($T: typeid, $Handle_Type: typeid) {
    elements:  [dynamic]T,
    free_list: [dynamic]Handle_Type,

    allocator: mem.Allocator,
}

init :: proc(pool: ^Dynamic_Pool($T, $Handle_Type), allocator := context.allocator) {
    pool.allocator = allocator
    pool.elements = make([dynamic]T, allocator)
    pool.free_list = make([dynamic]Handle_Type, allocator)
}

destroy :: proc(pool: Dynamic_Pool($T, $Handle_Type)) {
    delete(pool.elements)
    delete(pool.free_list)
}

// never hold this pointer.
get :: proc(pool: Dynamic_Pool($T, $Handle_Type), handle: Handle_Type) -> ^T {
    if len(pool.elements) > int(handle) {
        return &pool.elements[handle]
    }

    return nil
}

append :: proc(pool: ^Dynamic_Pool($T, $Handle_Type), element: T) -> Handle_Type {
    if len(pool.free_list) > 0 {
        handle := pop(&pool.free_list)
        pool.elements[handle] = element

        return handle
    }

    index := len(pool.elements)
    append_elem(&pool.elements, element)

    return Handle_Type(index)
}

remove :: proc(pool: ^Dynamic_Pool($T, $Handle_Type), handle: Handle_Type) -> bool {
    if len(pool.elements) > int(handle) {
        append_elem(&pool.free_list, handle)
        return true
    }

    return false
}
