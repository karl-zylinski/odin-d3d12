package render_commands

import "core:mem"
import "../render_types"
import "core:math/linalg/hlsl"
import "../zg_math"

Noop :: struct {}
Present :: struct {}
Execute :: struct {}
CreateFence :: distinct render_types.Handle
WaitForFence :: distinct render_types.Handle

VertexBufferDesc :: struct {
    stride: u32,
}

BufferDesc :: union {
    VertexBufferDesc,
}

CreateBuffer :: struct {
    handle: render_types.Handle,
    data: rawptr,
    size: int,
    desc: BufferDesc,
}

DrawCall :: struct {
    vertex_buffer: render_types.Handle,
}

ResourceState :: enum {
    Present,
    RenderTarget,
}

ResourceTransition :: struct {
    before: ResourceState,
    after: ResourceState,
}

ClearRenderTarget :: struct {
    clear_color: hlsl.float4,
}

SetRenderTarget :: struct {

}

SetViewport :: struct {
    rect: zg_math.Rect,
}

SetScissor :: struct {
    rect: zg_math.Rect,
}

SetPipeline :: struct {
}

Command :: union {
    Noop,
    Present,
    CreateFence,
    WaitForFence,
    Execute,
    ResourceTransition,
    CreateBuffer,
    DrawCall,
    ClearRenderTarget,
    SetRenderTarget,
    SetViewport,
    SetScissor,
    SetPipeline,
}

CommandList :: distinct [dynamic]Command

get_handle :: proc(s: ^State) -> render_types.Handle {
    s.max_handle += 1
    return s.max_handle
}

create_fence :: proc(s: ^State, command_list: ^CommandList) -> render_types.Handle {
    h := get_handle(s)
    c: Command = CreateFence(h)
    append(command_list, c)
    return h
}

create_buffer :: proc(s: ^State, command_list: ^CommandList, desc: BufferDesc, data: rawptr, size: int) -> render_types.Handle {
    h := get_handle(s)

    c := CreateBuffer {
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
    max_handle: render_types.Handle,
}