package base

import "core:runtime"
import "core:mem/virtual"

delete_temp_arena :: proc(a: runtime.Allocator) {
    free_all(a)
}

@(deferred_out = delete_temp_arena)
make_temp_arena :: proc() -> runtime.Allocator {
    ga, _ := new(virtual.Growing_Arena, context.temp_allocator)
    return virtual.growing_arena_allocator(ga)
}