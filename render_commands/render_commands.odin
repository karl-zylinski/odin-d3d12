package render_commands

import "core:slice"
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

// Public procs

begin_pass :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, BeginPass { pipeline = pipeline })
}

begin_resource_creation :: proc(cmdlist: ^CommandList) {
    append(&cmdlist.commands, BeginResourceCreation{})
}

destroy_state :: proc(s: ^State) {
    delete(s.freelist)
}

destroy_resource :: proc(cmdlist: ^CommandList, handle: Handle) {
    append(&cmdlist.commands, DestroyResource { handle = handle })
    append(&cmdlist.state.freelist, handle)
}

update_buffer :: proc(cmdlist: ^CommandList, handle: Handle, data: rawptr, size: int) {
    if data == nil {
        return
    }

    c := UpdateBuffer {
        handle = handle,
        size = size,
    }

    if data != nil {
        c.data = mem.alloc(size)
        mem.copy(c.data, data, size)
    }

    append(&cmdlist.commands, c)
}


create_buffer :: proc(cmdlist: ^CommandList, size: int, data: rawptr, data_size: int,  stride: int) -> Handle {
    h := get_handle(cmdlist.state)

    c := CreateBuffer {
        handle = h,
        size = size,
        stride = stride,
    }

    if data != nil {
        c.data = mem.alloc(size)
        c.data_size = data_size
        mem.copy(c.data, data, size)
    }

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

set_constant_buffer :: proc(cmdlist: ^CommandList, handle: Handle, offset: int) {
    append(&cmdlist.commands, SetConstantBuffer {
        handle = handle,
        offset = offset,
    })
}

set_constant :: proc(cmdlist: ^CommandList, shader: Handle, name: base.StrHash, offset: int) {
    append(&cmdlist.commands, SetConstant {
        shader = shader,
        name = name,
        offset = offset,
    })
}

create_texture :: proc(cmdlist: ^CommandList, format: render_types.TextureFormat, width: int, height: int, data: rawptr) -> Handle {
    h := get_handle(cmdlist.state)

    tx_size := render_types.texture_size(format, width, height)

    c := CreateTexture {
        handle = h,
        data = mem.alloc(tx_size),
        width = width,
        height = height,
        format = format,
    }

    mem.copy(c.data, data, tx_size)
    append(&cmdlist.commands, c)
    return h
}

set_texture :: proc(cmdlist: ^CommandList, shader: Handle, name: base.StrHash, texture: Handle) {
    append(&cmdlist.commands, SetTexture {
        shader = shader,
        name = name,
        texture = texture,
    }) 
}

set_buffer :: proc(cmdlist: ^CommandList, shader: Handle, name: base.StrHash, buffer: Handle) {
    append(&cmdlist.commands, SetBuffer {
        shader = shader,
        name = name,
        buffer = buffer,
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

set_shader :: proc(cmdlist: ^CommandList, pipeline: Handle, shader: Handle) {
    append(&cmdlist.commands, SetShader {
        handle = shader,
        pipeline = pipeline,
    })
}

set_scissor :: proc(cmdlist: ^CommandList, rect: math.Rect) {
    append(&cmdlist.commands, SetScissor {
        rect = rect,
    })
}

set_viewport :: proc(cmdlist: ^CommandList, rect: math.Rect) {
    append(&cmdlist.commands, SetViewport {
        rect = rect,
    })
}

resource_transition :: proc(cmdlist: ^CommandList, resource: Handle, before: ResourceState, after: ResourceState) {
    append(&cmdlist.commands, ResourceTransition {
        resource = resource,
        before = before,
        after = after,
    })
}

clear_render_target :: proc(cmdlist: ^CommandList, resource: Handle, color: hlsl.float4) {
    append(&cmdlist.commands, ClearRenderTarget {
        resource = resource,
        clear_color = color,
    })
}

set_render_target :: proc(cmdlist: ^CommandList, resource: Handle) {
    append(&cmdlist.commands, SetRenderTarget {
        resource = resource,
    })
}

execute :: proc(cmdlist: ^CommandList) {
    append(&cmdlist.commands, Execute{})
}

present :: proc(cmdlist: ^CommandList, pipeline: Handle) {
    append(&cmdlist.commands, Present{ handle = pipeline })
}

// Internal types

Noop :: struct {}

Present :: struct {
    handle: Handle,
}

Execute :: struct {}

CreateFence :: distinct Handle

CreateBuffer :: struct {
    handle: Handle,
    size: int,
    data: rawptr,
    data_size: int,
    stride: int,
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
    CopyDest,
    ConstantBuffer,
    VertexBuffer,
    IndexBuffer,
}

ResourceTransition :: struct {
    resource: Handle,
    before: ResourceState,
    after: ResourceState,
}

ClearRenderTarget :: struct {
    resource: Handle,
    clear_color: hlsl.float4,
}

SetRenderTarget :: struct {
    resource: Handle,
}

SetViewport :: struct {
    rect: math.Rect,
}

SetScissor :: struct {
    rect: math.Rect,
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

SetConstant :: struct {
    shader: Handle,
    name: base.StrHash,
    offset: int,
}

CreateTexture :: struct {
    handle: Handle,
    data: rawptr,
    format: render_types.TextureFormat,
    width: int,
    height: int,
}

SetTexture :: struct {
    shader: Handle,
    name: base.StrHash,
    texture: Handle,
}

SetBuffer :: struct {
    shader: Handle,
    name: base.StrHash,
    buffer: Handle,
}

BeginPass :: struct {
    pipeline: Handle,
}

BeginResourceCreation :: struct {}

SetConstantBuffer :: struct {
    handle: Handle,
    offset: int,
}

Command :: union {
    Noop,
    Present,
    Execute,
    ResourceTransition,
    CreateBuffer,
    DrawCall,
    ClearRenderTarget,
    SetRenderTarget,
    SetViewport,
    SetScissor,
    CreatePipeline,
    CreateShader,
    SetShader,
    DestroyResource,
    SetConstant,
    CreateTexture,
    SetTexture,
    SetBuffer,
    BeginPass,
    BeginResourceCreation,
    UpdateBuffer,
    SetConstantBuffer,
}

// Move this to some other file?

NamedOffset :: struct {
    name: base.StrHash,
    offset: int,
}

BufferWithNamedOffsets :: struct {
    data: [dynamic]byte,
    offsets: [dynamic]NamedOffset,
}

buffer_append :: proc(b: ^BufferWithNamedOffsets, val: ^$T, name: base.StrHash) {
    offset := len(b.data)
    append(&b.data, ..mem.ptr_to_bytes(val))
    append(&b.offsets, NamedOffset { name = name, offset = offset })
}