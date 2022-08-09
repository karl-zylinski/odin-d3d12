package render_commands

import "core:mem"
import "../render_types"
import "core:math/linalg/hlsl"
import "../math"
import "../shader_system"
import "../base"

// Public types

Handle :: render_types.Handle

State :: struct {
    max_handle: Handle,
    freelist: [dynamic]Handle,
}

CommandList :: struct {
    commands: [dynamic]Command,
    state: ^State,
}

// Public interface

destroy_state :: proc(s: ^State) {
    delete(s.freelist)
}

destroy_resource :: proc(cmdlist: ^CommandList, handle: Handle) {
    append(&cmdlist.commands, DestroyResource { handle = handle })
    append(&cmdlist.state.freelist, handle)
}

create_fence :: proc(cmdlist: ^CommandList) -> Handle {
    h := get_handle(cmdlist.state)
    c: Command = CreateFence(h)
    append(&cmdlist.commands, c)
    return h
}

create_buffer :: proc(cmdlist: ^CommandList, desc: BufferDesc, data: rawptr, size: int) -> Handle {
    h := get_handle(cmdlist.state)

    c := CreateBuffer {
        handle = h,
        desc = desc,
        data = mem.alloc(size),
        size = size,
    }

    mem.copy(c.data, data, size)
    append(&cmdlist.commands, c)
    return h
}

create_pipeline :: proc(cmdlist: ^CommandList, x: f32, y: f32, window_handle: render_types.WindowHandle) -> Handle {
    h := get_handle(cmdlist.state)

    c := CreatePipeline {
        handle = h,
        swapchain_x = x,
        swapchain_y = y,
        window_handle = window_handle,
    }

    append(&cmdlist.commands, c)
    return h
}

create_shader :: proc(cmdlist: ^CommandList, shader: shader_system.Shader) -> Handle {
    h := get_handle(cmdlist.state)

    c := CreateShader {
        handle = h,
        shader = shader,
    }

    append(&cmdlist.commands, c)
    return h
}

create_constant :: proc(s: ^State) -> Handle {
    h := get_handle(s)
    return h
}

upload_constant :: proc(cmdlist: ^CommandList, pipeline: Handle, constant: Handle, data: ^$T) {
    c := UploadConstant {
        constant = constant,
        pipeline = pipeline,
        data_size = size_of(data^),
    }

    mem.copy(rawptr(&c.data[0]), data, size_of(data^))
    append(&cmdlist.commands, c)
}

set_constant :: proc(cmdlist: ^CommandList, pipeline: Handle, shader: Handle, name: base.StrHash, constant: Handle) {
    append(&cmdlist.commands, SetConstant {
        pipeline = pipeline,
        shader = shader,
        name = name,
        constant = constant,
    })
}

destroy_constant :: proc(cmdlist: ^CommandList, pipeline: Handle, constant: Handle) {
    append(&cmdlist.commands, DestroyConstant { constant = constant, pipeline = pipeline })
}

create_texture :: proc(cmdlist: ^CommandList, pipeline: Handle, format: render_types.TextureFormat, width: int, height: int, data: rawptr) -> Handle {
    h := get_handle(cmdlist.state)

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
    append(&cmdlist.commands, c)
    return h
}

set_texture :: proc(cmdlist: ^CommandList, pipeline: Handle, shader: Handle, name: base.StrHash, texture: Handle) {
    append(&cmdlist.commands, SetTexture {
        pipeline = pipeline,
        shader = shader,
        name = name,
        texture = texture,
    }) 
}

draw_call :: proc(cmdlist: ^CommandList, vertex_buffer: Handle, index_buffer: Handle) {
    append(&cmdlist.commands, DrawCall {
        vertex_buffer = vertex_buffer,
        index_buffer = index_buffer,
    })
}

get_handle :: proc(s: ^State) -> Handle {
    if len(s.freelist) > 0 {
        return pop(&s.freelist)
    }
    s.max_handle += 1
    return s.max_handle
}

create_command_list :: proc(s: ^State) -> CommandList {
    return {
        state = s,
    }
}

destroy_command_list :: proc(cmdlist: ^CommandList) {
    delete(cmdlist.commands)
}

set_pipeline :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, SetPipeline {
        handle = pipeline,
    })
}

set_shader :: proc(cmdlist: ^CommandList, pipeline: Handle, shader: Handle) {
    append(&cmdlist.commands, SetShader {
        handle = shader,
        pipeline = pipeline,
    })
}

set_scissor :: proc(cmdlist: ^CommandList, rect: math.Rect) {
    append(&cmdlist.commands, SetScissor {
        rect = rect
    })
}

set_viewport :: proc(cmdlist: ^CommandList, rect: math.Rect) {
    append(&cmdlist.commands, SetViewport {
        rect = rect
    })
}

resource_transition :: proc(cmdlist: ^CommandList, before: ResourceState, after: ResourceState) {
    append(&cmdlist.commands, ResourceTransition {
        before = before,
        after = after,
    })
}

clear_render_target :: proc(cmdlist: ^CommandList, pipeline: Handle, color: hlsl.float4) {
    append(&cmdlist.commands, ClearRenderTarget {
        render_target = { pipeline = pipeline, },
        clear_color = color,
    })
}

set_render_target :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, SetRenderTarget {
        render_target = { pipeline = pipeline, },
    })
}

execute :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, Execute{ pipeline = pipeline, })
}

present :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, Present{ handle = pipeline })
}

wait_for_fence :: proc(cmdlist: ^CommandList, pipeline: Handle, fence: Handle) {
    append(&cmdlist.commands, WaitForFence { fence = fence, pipeline = pipeline, })
}

// Internal types

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

CreateBuffer :: struct {
    handle: Handle,
    data: rawptr,
    size: int,
    desc: BufferDesc,
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
    rect: math.Rect,
}

SetScissor :: struct {
    rect: math.Rect,
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