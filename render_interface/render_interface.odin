package render_interface

import "core:mem"

Handle :: distinct u64

Command_Noop :: struct {}
Command_Present :: struct {}
Command_Execute :: struct {}
Command_Create_Fence :: distinct Handle
Command_Wait_For_Fence :: distinct Handle

Buffer_Desc_Vertex_Buffer :: struct {
    stride: u32,
}

Buffer_Desc :: union {
    Buffer_Desc_Vertex_Buffer,
}

Command_Create_Buffer :: struct {
    handle: Handle,
    data: rawptr,
    size: int,
    desc: Buffer_Desc,
}

Command_Draw_Call :: struct {
    vertex_buffer: Handle,
}

Resource_State :: enum {
    Present,
    Render_Target,
}

Command_Resource_Transition :: struct {
    before: Resource_State,
    after: Resource_State,
}

Command :: union {
    Command_Noop,
    Command_Present,
    Command_Create_Fence,
    Command_Wait_For_Fence,
    Command_Execute,
    Command_Resource_Transition,
    Command_Create_Buffer,
    Command_Draw_Call,
}

Command_List :: distinct [dynamic]Command

get_handle :: proc(s: ^State) -> Handle {
    s.max_handle += 1
    return s.max_handle
}

create_fence :: proc(s: ^State, command_list: ^Command_List) -> Handle {
    h := get_handle(s)
    c: Command = Command_Create_Fence(h)
    append(command_list, c)
    return h
}

create_buffer :: proc(s: ^State, command_list: ^Command_List, desc: Buffer_Desc, data: rawptr, size: int) -> Handle {
    h := get_handle(s)

    c := Command_Create_Buffer {
        handle = h,
        desc = desc,
        data = mem.alloc(size),
        size = size,
    }

    mem.copy(c.data, data, size)
    append(command_list, c)
    return h
}

State :: struct {
    max_handle: Handle,
}