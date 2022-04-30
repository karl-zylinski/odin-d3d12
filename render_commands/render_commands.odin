package render_commands

import "core:mem"
import "../render_types"
import "core:math/linalg/hlsl"
import "../zg_math"

Handle :: render_types.Handle

Noop :: struct {}

Present :: struct {
    handle: Handle,
}

Execute :: struct {}
CreateFence :: distinct Handle
WaitForFence :: struct {
    fence: Handle,
    pipeline: Handle,
}

VertexBufferDesc :: struct {
    stride: u32,
}

BufferDesc :: union {
    VertexBufferDesc,
}

CreateBuffer :: struct {
    handle: Handle,
    data: rawptr,
    size: int,
    desc: BufferDesc,
}

DrawCall :: struct {
    vertex_buffer: Handle,
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
    handle: Handle,
}

CreatePipeline :: struct {
    handle: Handle,
    swapchain_x, swapchain_y: f32,
    window_handle: render_types.WindowHandle,
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
    CreatePipeline,
}

CommandList :: distinct [dynamic]Command

get_handle :: proc(s: ^State) -> Handle {
    s.max_handle += 1
    return s.max_handle
}

create_fence :: proc(s: ^State, command_list: ^CommandList) -> Handle {
    h := get_handle(s)
    c: Command = CreateFence(h)
    append(command_list, c)
    return h
}

create_buffer :: proc(s: ^State, command_list: ^CommandList, desc: BufferDesc, data: rawptr, size: int) -> Handle {
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

create_pipeline :: proc(s: ^State, command_list: ^CommandList, x: f32, y: f32, window_handle: render_types.WindowHandle) -> Handle {
    h := get_handle(s)

    c := CreatePipeline {
        handle = h,
        swapchain_x = x,
        swapchain_y = y,
        window_handle = window_handle,
    }

    append(command_list, c)
    return h
}

State :: struct {
    max_handle: Handle,
}