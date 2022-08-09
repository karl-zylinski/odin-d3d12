package render_commands

import "core:mem"
import "../render_types"
import "core:math/linalg/hlsl"
import "../zg_math"
import "../shader_system"
import "../base"

Handle :: render_types.Handle

Noop :: struct {}

Present :: struct {
    handle: Handle,
}

Execute :: struct {
    pipeline: Handle,
}

CreateFence :: distinct Handle

WaitForFence :: struct {
    fence: Handle,
    pipeline: Handle,
}

VertexBufferDesc :: struct {
    stride: u32,
}

IndexBufferDesc :: struct {
    stride: u32,
}

BufferDesc :: union {
    VertexBufferDesc,
    IndexBufferDesc,
}

BufferType :: enum {
    Static,
    Dynamic,
}

CreateBuffer :: struct {
    handle: Handle,
    data: rawptr,
    size: int,
    desc: BufferDesc,
    type: BufferType,
}

UpdateBuffer :: struct {
    handle: Handle,
    data: rawptr,
    size: int,
}

DrawCall :: struct {
    vertex_buffer: Handle,
    index_buffer: Handle,
}

ResourceState :: enum {
    Present,
    RenderTarget,
}

RenderTarget :: struct {
    pipeline: Handle,
}

ResourceTransition :: struct {
    render_target: RenderTarget,
    before: ResourceState,
    after: ResourceState,
}

ClearRenderTarget :: struct {
    render_target: RenderTarget,
    clear_color: hlsl.float4,
}

SetRenderTarget :: struct {
    render_target: RenderTarget,
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

CreateShader :: struct {
    handle: Handle,
    pipeline: Handle,
    shader: shader_system.Shader,
}

SetShader :: struct {
    handle: Handle,
    pipeline: Handle,
}

DestroyResource :: struct {
    handle: Handle,
}

UploadConstant :: struct {
    data: [256]u8,
    data_size: int,
    pipeline: Handle,
    constant: Handle,
}

SetConstant :: struct {
    pipeline: Handle,
    shader: Handle,
    name: base.StrHash,
    constant: Handle,
}

DestroyConstant :: struct {
    constant: Handle,
    pipeline: Handle,
}

CreateTexture :: struct {
    handle: Handle,
    data: rawptr,
    format: render_types.TextureFormat,
    width: int,
    height: int,
    pipeline: Handle,
}

SetTexture :: struct {
    pipeline: Handle,
    shader: Handle,
    name: base.StrHash,
    texture: Handle,
}

Command :: union {
    Noop,
    Present,
    CreateFence,
    WaitForFence,
    Execute,
    ResourceTransition,
    CreateBuffer,
    UpdateBuffer,
    DrawCall,
    ClearRenderTarget,
    SetRenderTarget,
    SetViewport,
    SetScissor,
    SetPipeline,
    CreatePipeline,
    CreateShader,
    SetShader,
    DestroyResource,
    UploadConstant,
    SetConstant,
    DestroyConstant,
    CreateTexture,
    SetTexture,
}

CommandList :: distinct [dynamic]Command

get_handle :: proc(s: ^State) -> Handle {
    if len(s.freelist) > 0 {
        return pop(&s.freelist)
    }
    s.max_handle += 1
    return s.max_handle
}

destroy_state :: proc(s: ^State) {
    delete(s.freelist)
}

destroy_resource :: proc(s: ^State, command_list: ^CommandList, handle: Handle) {
    append(command_list, DestroyResource { handle = handle })
    append(&s.freelist, handle)
}

create_fence :: proc(s: ^State, command_list: ^CommandList) -> Handle {
    h := get_handle(s)
    c: Command = CreateFence(h)
    append(command_list, c)
    return h
}

create_buffer :: proc(s: ^State, command_list: ^CommandList, desc: BufferDesc, data: rawptr, size: int, type: BufferType) -> Handle {
    h := get_handle(s)

    c := CreateBuffer {
        handle = h,
        desc = desc,
        data = mem.alloc(size),
        size = size,
        type = type,
    }

    mem.copy(c.data, data, size)
    append(command_list, c)
    return h
}

update_buffer :: proc(command_list: ^CommandList, handle: Handle, data: rawptr, size: int) {
    c := UpdateBuffer {
        handle = handle,
        data = mem.alloc(size),
        size = size,
    }

    mem.copy(c.data, data, size)
    append(command_list, c)
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

create_shader :: proc(s: ^State, command_list: ^CommandList, shader: shader_system.Shader) -> Handle {
    h := get_handle(s)

    c := CreateShader {
        handle = h,
        shader = shader,
    }

    append(command_list, c)
    return h
}

create_constant :: proc(s: ^State) -> Handle {
    h := get_handle(s)
    return h
}

upload_constant :: proc(s: ^State, command_list: ^CommandList, pipeline: Handle, constant: Handle, data: ^$T) {
    c := UploadConstant {
        constant = constant,
        pipeline = pipeline,
        data_size = size_of(data^),
    }

    mem.copy(rawptr(&c.data[0]), data, size_of(data^))
    append(command_list, c)
}

destroy_constant :: proc(s: ^State, command_list: ^CommandList, pipeline: Handle, constant: Handle) {
    append(command_list, DestroyConstant { constant = constant, pipeline = pipeline })
}

create_texture :: proc(s: ^State, command_list: ^CommandList, pipeline: Handle, format: render_types.TextureFormat, width: int, height: int, data: rawptr) -> Handle {
    h := get_handle(s)

    tx_size := render_types.texture_size(format, width, height)

    c := CreateTexture {
        handle = h,
        data = mem.alloc(tx_size),
        width = width,
        height = height,
        format = format,
        pipeline = pipeline,
    }

    mem.copy(c.data, data, tx_size)
    append(command_list, c)
    return h
}

State :: struct {
    max_handle: Handle,
    freelist: [dynamic]Handle,
}