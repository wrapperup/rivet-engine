package game

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"

RawSparseSet :: struct {
	sparse:          runtime.Raw_Map,
	dense:           runtime.Raw_Dynamic_Array,
	sparse_map_info: runtime.Map_Info,
}

SparseSet :: struct($T: typeid) {
	sparse:          map[EntityId]int, // id -> index in dense
	dense:           [dynamic]T,
	sparse_map_info: runtime.Map_Info,
}

assign_at_sparse_set :: proc(set: ^SparseSet($T), id: EntityId, data: T) -> ^T {
	index := len(set.dense)
	append(&set.dense, data)

	set.sparse[id] = index
	return &set.dense[index]
}

get_elem_sparse_set :: proc(set: ^SparseSet($T), id: EntityId) -> (data: ^T, ok: bool) {
	index := set.sparse[id] or_return
	return &set.dense[index], true
}

remove_elem_sparse_set :: proc(set: ^SparseSet($T), id: EntityId) -> (ok: bool) {
	assert(len(set.dense) > 0)

	deleted_index := set.sparse[id] or_return
	delete_key(&set.sparse, id)

	// Swaps last with index
	unordered_remove(&set.dense, deleted_index)
	old_index := len(set.dense)

	// Fix affected mapping that was moved
	for k, &v in set.sparse {
		if old_index == v {
			set.sparse[k] = deleted_index
		}
	}

	return true
}

// Entity System
// Works very similar to a ECS, except that "components" are just
// a subtype of an Entity. It's not as efficient as a normal ECS, but it's
// a lot faster than a classic OOP entity system.

// Querying subtypes is efficient, it works using an entity ID and a
// sparse set (like an ECS), and keeping subtype data dense for cache-locality.

// EntityId is a 64-bit generational handle containing a 32-bit stable slot
// index and a 32-bit generation. Destroying an entity advances the slot's
// generation so stale handles cannot resolve after that slot is reused.
EntityId :: struct {
	generation: u32,
	index:      u32,
}

#assert(size_of(EntityId) == 8)
#assert(size_of(EntityId) == size_of(rawptr))

entity_id_to_rawptr :: proc(id: EntityId) -> rawptr {
	return transmute(rawptr)id
}

entity_id_from_rawptr :: proc(ptr: rawptr) -> EntityId {
	id := transmute(EntityId)ptr
	return id
}

// Strongly typed ID, brings some checks back to compile-time to ensure
// the entity you queried is the correct type.
TypedEntityId :: struct($T: typeid) {
	using id: EntityId,
}

// The entity struct contains very common components
// that every entity needs. The core struct is designed
// to be reasonably cache-friendly, so keep it small when
// possible.
Entity :: struct {
	id:          EntityId,
	subtype:     typeid,
	translation: Vec3,
	velocity:    Vec3,
	rotation:    Quat,
}

ENTITY_PAGE_SIZE        :: 1024
ENTITY_FIRST_GENERATION :: 1

EntitySlot :: struct {
	entity: Entity,
	alive:  bool,
}

EntityPage :: [ENTITY_PAGE_SIZE]EntitySlot

// Core entities live in arena-backed pages so their addresses remain stable.
// Freed slot indices are recycled; slot_count is the high-water mark while
// live_count tracks entities that currently resolve.
EntitySystem :: struct {
	initialized:  bool,
	arena:        virtual.Arena,
	pages:        [dynamic]^EntityPage,
	free_indices: [dynamic]u32,
	slot_count:   u32,
	live_count:   u32,

	// Maps typeid of T to SparseSet(T).
	//
	// Safety: NEVER use this raw, use `new_or_get_entity_subtype_system`
	// or `get_entity_subtype_system to get the correct typing.
	subtype_storage: map[string]SubtypeStorage,
}

init_entity_system_storage :: proc(system: ^EntitySystem) -> bool {
	assert(!system.initialized)

	if virtual.arena_init_growing(&system.arena) != nil {
		return false
	}

	allocator := virtual.arena_allocator(&system.arena)
	system.pages = make([dynamic]^EntityPage, allocator)
	system.free_indices = make([dynamic]u32, allocator)
	system.initialized = true
	return true
}

init_entity_system :: proc() -> bool {
	return init_entity_system_storage(&game.entity_system)
}

entity_slot_at_index :: proc(system: ^EntitySystem, index: u32) -> ^EntitySlot {
	if !system.initialized || index >= system.slot_count {
		return nil
	}

	page_index := int(index / ENTITY_PAGE_SIZE)
	slot_index := int(index % ENTITY_PAGE_SIZE)
	assert(page_index < len(system.pages))
	return &system.pages[page_index][slot_index]
}

live_entity_at_index :: proc(system: ^EntitySystem, index: u32) -> ^Entity {
	slot := entity_slot_at_index(system, index)
	if slot == nil || !slot.alive {
		return nil
	}
	return &slot.entity
}

entity_slot_from_id :: proc(system: ^EntitySystem, id: EntityId) -> ^EntitySlot {
	slot := entity_slot_at_index(system, id.index)
	if slot == nil || !slot.alive || slot.entity.id != id {
		return nil
	}
	return slot
}

allocate_entity_slot :: proc(system: ^EntitySystem) -> ^EntitySlot {
	assert(system.initialized)

	index: u32
	generation := u32(ENTITY_FIRST_GENERATION)
	if len(system.free_indices) > 0 {
		index = pop(&system.free_indices)
		slot := entity_slot_at_index(system, index)
		assert(slot != nil && !slot.alive)
		generation = slot.entity.id.generation
	} else {
		assert(system.slot_count < max(u32), "Entity slot index exhausted.")
		index = system.slot_count
		if index % ENTITY_PAGE_SIZE == 0 {
			page := new(EntityPage, virtual.arena_allocator(&system.arena))
			append(&system.pages, page)
		}
		system.slot_count += 1
	}

	slot := entity_slot_at_index(system, index)
	slot^ = {
		entity = {
			id      = {generation = generation, index = index},
			subtype = Entity,
		},
		alive = true,
	}
	system.live_count += 1
	return slot
}

release_entity_slot :: proc(system: ^EntitySystem, id: EntityId) -> bool {
	slot := entity_slot_from_id(system, id)
	if slot == nil {
		return false
	}

	next_generation := u32(ENTITY_FIRST_GENERATION)
	if slot.entity.id.generation != max(u32) {
		next_generation = slot.entity.id.generation + 1
	}

	slot^ = {
		entity = {id = {generation = next_generation, index = id.index}},
	}
	append(&system.free_indices, id.index)
	system.live_count -= 1
	return true
}

DestroyProc :: #type proc(entity: rawptr)

SubtypeStorage :: struct {
	ptr:       ^RawSparseSet,
	type_info: runtime.Type_Info,
	destroy:   DestroyProc,
	shutdown:  proc(storage: rawptr, destroy: DestroyProc),
}

register_entity_subtype_no_destroy :: proc($T: typeid) -> ^SparseSet(T) {
	return register_entity_subtype_with_destroy(T, nil)
}

register_entity_subtype_with_destroy :: proc($T: typeid, destroy_proc: proc(_: ^T)) -> ^SparseSet(T) {
	ty_info := type_info_of(T).variant.(runtime.Type_Info_Named)
	name := ty_info.name

	_, ok := game.entity_system.subtype_storage[name]
	assert(!ok, "Entity subtype already registered.")

	sparse_set := new(SparseSet(T))

	subtype_storage := SubtypeStorage {
		ptr       = cast(^RawSparseSet)sparse_set,
		type_info = type_info_of(T)^,
		destroy   = cast(DestroyProc)destroy_proc,
		shutdown  = proc(storage_raw: rawptr, destroy: DestroyProc) {
			storage := cast(^SparseSet(T))storage_raw
			if destroy != nil {
				for &entity in storage.dense {
					destroy(&entity)
				}
			}
			delete(storage.sparse)
			delete(storage.dense)
			free(storage)
		},
	}

	subtype_storage.ptr.sparse_map_info = runtime.map_info(type_of(sparse_set.sparse))^

	game.entity_system.subtype_storage[name] = subtype_storage

	return sparse_set
}

register_entity_subtype :: proc {
	register_entity_subtype_no_destroy,
	register_entity_subtype_with_destroy,
}

get_entity_subtype_system :: proc($T: typeid) -> ^SparseSet(T) {
	ty_info := type_info_of(T).variant.(runtime.Type_Info_Named)
	name := ty_info.name

	storage, ok := game.entity_system.subtype_storage[name]
	assert(ok, "Entity subtype was not registered.")

	return cast(^SparseSet(T))(storage.ptr)
}

new_entity_subtype :: proc($T: typeid) -> ^T where intrinsics.type_is_subtype_of(T, ^Entity) {
	data := T{}
	data.entity = new_entity_raw()
	data.entity.subtype = T

	storage := get_entity_subtype_system(T)

	return assign_at_sparse_set(storage, data.entity.id, data)
}

#assert(size_of(typeid) == 8)

new_entity_subtype_id :: proc($T: typeid) -> (^T, TypedEntityId(T)) where intrinsics.type_is_subtype_of(T, ^Entity) {
	subtype := new_entity_subtype(T)

	return subtype, TypedEntityId(T){id = subtype.entity.id}
}

new_entity_raw_from_storage :: proc(system: ^EntitySystem) -> ^Entity {
	return &allocate_entity_slot(system).entity
}

new_entity_raw :: proc() -> ^Entity {
	return new_entity_raw_from_storage(&game.entity_system)
}

new_entity :: proc {
	new_entity_raw,
	new_entity_subtype,
}

// Resolve a live entity handle. The returned address remains stable until the
// entity is destroyed, but callers should retain the handle rather than it.
get_entity_raw_from_storage :: proc(system: ^EntitySystem, id: EntityId) -> ^Entity {
	slot := entity_slot_from_id(system, id)
	if slot == nil do return nil
	return &slot.entity
}

get_entity_raw :: proc(id: EntityId) -> ^Entity {
	return get_entity_raw_from_storage(&game.entity_system, id)
}

get_entity_subtype :: proc($T: typeid, id: EntityId) -> ^T where intrinsics.type_is_subtype_of(T, ^Entity) {
	if get_entity_raw(id) == nil do return nil

	storage := get_entity_subtype_system(T)
	if storage == nil do return nil

	type_t, ok := get_elem_sparse_set(storage, id)
	if !ok do return nil

	return type_t
}

get_entity_subtype_typed :: proc(id: TypedEntityId($T)) -> ^T {
	return get_entity_subtype(T, id.id)
}

// Get entity. Generational index ensures that the entity
// you get is a valid entity, don't persist the pointer. Can return nil.
get_entity :: proc {
	get_entity_raw,
	get_entity_subtype,
	get_entity_subtype_typed,
}

remove_entity_raw :: proc(id: EntityId) -> bool {
	return release_entity_slot(&game.entity_system, id)
}

remove_elem_raw_sparse_set :: proc(set: ^RawSparseSet, id: EntityId, elem_size: int) -> bool {
	sparse := cast(^map[EntityId]int)(&set.sparse)
	deleted_index, ok := sparse^[id]
	if !ok {
		return false
	}
	delete_key(sparse, id)

	last := set.dense.len - 1
	if deleted_index != last {
		dst := rawptr(uintptr(set.dense.data) + uintptr(deleted_index * elem_size))
		src := rawptr(uintptr(set.dense.data) + uintptr(last * elem_size))
		intrinsics.mem_copy(dst, src, elem_size) // swap last -> hole (unordered remove)
		// The element formerly at `last` now lives at deleted_index; fix its sparse entry.
		for k, v in sparse^ {
			if v == last {
				sparse^[k] = deleted_index
				break
			}
		}
	}
	set.dense.len = last
	return true
}

get_elem_raw_sparse_set :: proc(set: ^RawSparseSet, id: EntityId, elem_size: int) -> (rawptr, bool) {
	sparse := cast(^map[EntityId]int)(&set.sparse)
	index, ok := sparse^[id]
	if !ok {
		return nil, false
	}
	return rawptr(uintptr(set.dense.data) + uintptr(index * elem_size)), true
}

_remove_entity :: proc(id: EntityId) -> bool {
	entity := get_entity_raw(id)
	if entity == nil do return false

	name := type_info_of(entity.subtype).variant.(runtime.Type_Info_Named).name
	if storage, ok := game.entity_system.subtype_storage[name]; ok {
		remove_elem_raw_sparse_set(storage.ptr, id, storage.type_info.size)
	}
	return remove_entity_raw(id)
}

destroy_entity :: proc(id: EntityId) -> bool {
	entity := get_entity_raw(id)
	if entity == nil do return false

	name := type_info_of(entity.subtype).variant.(runtime.Type_Info_Named).name
	if storage, ok := game.entity_system.subtype_storage[name]; ok {
		if storage.destroy != nil {
			if elem, eok := get_elem_raw_sparse_set(storage.ptr, id, storage.type_info.size); eok {
				storage.destroy(elem)
			}
		}
	}

	return _remove_entity(id)
}

entity_id_of :: proc(subtype_entity: ^$T) -> TypedEntityId(T) where intrinsics.type_is_subtype_of(T, ^Entity) {
	return TypedEntityId(T){id = subtype_entity.entity.id}
}

get_entities :: proc($T: typeid) -> []T {
	storage := get_entity_subtype_system(T)
	if storage != nil {
		return storage.dense[:]
	} else {
		return {}
	}
}

len_entities :: proc($T: typeid) -> int {
	storage := get_entity_subtype_system(T)
	if storage != nil {
		return len(storage.dense)
	} else {
		return 0
	}
}


parallel_for_entities_data :: proc(
	procedure: proc(entity: ^$T, index: int, data: rawptr = nil),
	data: rawptr = nil,
) where intrinsics.type_is_subtype_of(T, ^Entity) {
	storage := get_entity_subtype_system(T)

	Parallel_For_Entity_Data :: struct {
		storage:   rawptr,
		data:      rawptr,
		procedure: proc(entity: ^T, index: int, data: rawptr),
	}

	parallel_for_entity_data := Parallel_For_Entity_Data {
		storage   = storage,
		data      = data,
		procedure = procedure,
	}

	parallel_for(len(storage.dense), proc(index: int, data: rawptr) {
			entity_data := cast(^Parallel_For_Entity_Data)data
			storage := cast(^SparseSet(T))entity_data.storage
			entity_data.procedure(&storage.dense[index], index, entity_data.data)
		}, &parallel_for_entity_data)
}

parallel_for_entities_no_data :: proc(procedure: proc(entity: ^$T, index: int)) where intrinsics.type_is_subtype_of(T, ^Entity) {
	storage := get_entity_subtype_system(T)

	Parallel_For_Entity_Data :: struct {
		storage:   rawptr,
		procedure: proc(entity: ^T, index: int),
	}

	parallel_for_entity_data := Parallel_For_Entity_Data {
		storage   = storage,
		procedure = procedure,
	}

	parallel_for(len(storage.dense), proc(index: int, data: rawptr) {
			entity_data := cast(^Parallel_For_Entity_Data)data
			storage := cast(^SparseSet(T))entity_data.storage
			entity_data.procedure(&storage.dense[index], index)
		}, &parallel_for_entity_data)
}

parallel_for_entities :: proc {
	parallel_for_entities_data,
	parallel_for_entities_no_data,
}

shutdown_entity_system_storage :: proc(system: ^EntitySystem) {
	if !system.initialized do return

	for _, storage in system.subtype_storage {
		storage.shutdown(storage.ptr, storage.destroy)
	}
	delete(system.subtype_storage)
	virtual.arena_destroy(&system.arena)
	system^ = {}
}

shutdown_entity_system :: proc() {
	shutdown_entity_system_storage(&game.entity_system)
}
