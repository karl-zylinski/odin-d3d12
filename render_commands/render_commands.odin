package render_commands

import "core:slice"
import "core:mem"
import "core:math/linalg/hlsl"

import rt "ze:render_types"
import "ze:math"
import ss "ze:shader_system"
import "ze:base"

// Public types

// We define these different handle to have some sort of type safety. They are still casted internally in the render backend,
// but for the user using this API, handles should be quite type safe.
AnyHandle :: distinct rt.Handle
TextureHandle :: distinct rt.Handle
BufferHandle :: distinct rt.Handle
PipelineHandle :: distinct rt.Handle
ShaderHandle :: distinct rt.Handle

State :: struct {
    max_handle: rt.Handle,
    freelist: [dynamic]rt.Handle,
}

CommandList :: struct {
    commands: [dynamic]Command,
    state: ^State,
}

// Public procs

begin_pass :: proc(cmdlist: ^CommandList, pipeline: PipelineHandle) {
    append(&cmdlist.commands, BeginPass { pipeline = pipeline })
}

begin_resource_creation :: proc(cmdlist: ^CommandList) {
    append(&cmdlist.commands, BeginResourceCreation{})
}

destroy_state :: proc(s: ^State) {
    delete(s.freelist)
}

destroy_resource :: proc(cmdlist: ^CommandList, handle: $T/rt.Handle) {
    append(&cmdlist.commands, DestroyResource { handle = AnyHandle(handle) })
    append(&cmdlist.state.freelist, rt.Handle(handle))
}

update_buffer :: proc(cmdlist: ^CommandList, handle: BufferHandle, data: rawptr, size: int) {
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


create_buffer :: proc(cmdlist: ^CommandList, size: int, data: rawptr, data_size: int,  stride: int) -> BufferHandle {
    h := BufferHandle(get_handle(cmdlist.state))

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

create_pipeline :: proc(cmdlist: ^CommandList, x: f32, y: f32, window_handle: rt.WindowHandle) -> PipelineHandle {
    h := PipelineHandle(get_handle(cmdlist.state))

    c := CreatePipeline {
        handle = h,
        swapchain_x = x,
        swapchain_y = y,
        window_handle = window_handle,
    }

    append(&cmdlist.commands, c)
    return h
}

create_shader :: proc(cmdlist: ^CommandList, shader: ss.Shader) -> ShaderHandle {
    h := ShaderHandle(get_handle(cmdlist.state))

    c := CreateShader {
        handle = h,
        shader = shader,
    }

    append(&cmdlist.commands, c)
    return h
}

set_constant_buffer :: proc(cmdlist: ^CommandList, handle: BufferHandle) {
    append(&cmdlist.commands, SetConstantBuffer {
        handle = handle,
    })
}

set_constant :: proc(cmdlist: ^CommandList, name: base.StrHash, offset: int) {
    append(&cmdlist.commands, SetConstant {
        name = name,
        offset = offset,
    })
}

create_texture :: proc(cmdlist: ^CommandList, format: rt.TextureFormat, width: int, height: int, data: rawptr) -> TextureHandle {
    h := TextureHandle(get_handle(cmdlist.state))

    c := CreateTexture {
        handle = h,
        width = width,
        height = height,
        format = format,
    }

    if data != nil {
        tx_size := rt.texture_size(format, width, height)
        c.data = mem.alloc(tx_size)
        mem.copy(c.data, data, tx_size)
    }
    
    append(&cmdlist.commands, c)
    return h
}

set_texture :: proc(cmdlist: ^CommandList, name: base.StrHash, texture: TextureHandle) {
    append(&cmdlist.commands, SetTexture {
        name = name,
        texture = texture,
    }) 
}

draw_call :: proc(cmdlist: ^CommandList, vertex_buffer: BufferHandle, index_buffer: BufferHandle) {
    append(&cmdlist.commands, DrawCall {
        vertex_buffer = vertex_buffer,
        index_buffer = index_buffer,
    })
}

get_handle :: proc(s: ^State) -> rt.Handle {
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

set_shader :: proc(cmdlist: ^CommandList, shader: ShaderHandle) {
    append(&cmdlist.commands, SetShader {
        handle = shader,
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

resource_transition :: proc(cmdlist: ^CommandList, handle: $T/rt.Handle, before: ResourceState, after: ResourceState) {
    append(&cmdlist.commands, ResourceTransition {
        resource = AnyHandle(handle),
        before = before,
        after = after,
    })
}

clear_render_target_handle :: proc(cmdlist: ^CommandList, resource: AnyHandle, color: hlsl.float4) {
    append(&cmdlist.commands, ClearRenderTarget {
        resource = resource,
        clear_color = color,
    })
}

clear_render_target_pipeline :: proc(cmdlist: ^CommandList, pipeline: PipelineHandle, color: hlsl.float4) {
    clear_render_target_handle(cmdlist, AnyHandle(pipeline), color)
}

clear_render_target_texture :: proc(cmdlist: ^CommandList, texture: TextureHandle, color: hlsl.float4) {
    clear_render_target_handle(cmdlist, AnyHandle(texture), color)
}

clear_render_target :: proc{clear_render_target_handle, clear_render_target_pipeline, clear_render_target_texture}

set_render_target_handle :: proc(cmdlist: ^CommandList, resource: AnyHandle) {
    append(&cmdlist.commands, SetRenderTarget {
        resource = resource,
    })
}

set_render_target_pipeline :: proc(cmdlist: ^CommandList, pipeline: PipelineHandle) {
    set_render_target_handle(cmdlist, AnyHandle(pipeline))
}

set_render_target_texture :: proc(cmdlist: ^CommandList, texture: TextureHandle) {
    set_render_target_handle(cmdlist, AnyHandle(texture))
}

set_render_target :: proc{set_render_target_handle, set_render_target_pipeline, set_render_target_texture}

execute :: proc(cmdlist: ^CommandList) {
    append(&cmdlist.commands, Execute{})
}

present :: proc(cmdlist: ^CommandList) {
    append(&cmdlist.commands, Present{})
}

// Internal types

Noop :: struct {}

Present :: struct {}

Execute :: struct {}

CreateBuffer :: struct {
    handle: BufferHandle,
    size: int,
    data: rawptr,
    data_size: int,
    stride: int,
}

UpdateBuffer :: struct {
    handle: BufferHandle,
    data: rawptr,
    size: int,
}

DrawCall :: struct {
    vertex_buffer: BufferHandle,
    index_buffer: BufferHandle,
}

ResourceState :: enum {
    Present,
    RenderTarget,
    CopyDest,
    ConstantBuffer,
    VertexBuffer,
    IndexBuffer,
    PixelShaderResource,
}

ResourceTransition :: struct {
    resource: AnyHandle,
    before: ResourceState,
    after: ResourceState,
}

ClearRenderTarget :: struct {
    resource: AnyHandle,
    clear_color: hlsl.float4,
}

SetRenderTarget :: struct {
    resource: AnyHandle,
}

SetViewport :: struct {
    rect: math.Rect,
}

SetScissor :: struct {
    rect: math.Rect,
}

CreatePipeline :: struct {
    handle: PipelineHandle,
    swapchain_x, swapchain_y: f32,
    window_handle: rt.WindowHandle,
}

CreateShader :: struct {
    handle: ShaderHandle,
    shader: ss.Shader,
}

SetShader :: struct {
    handle: ShaderHandle,
}

DestroyResource :: struct {
    handle: AnyHandle,
}

SetConstant :: struct {
    name: base.StrHash,
    offset: int,
}

CreateTexture :: struct {
    handle: TextureHandle,
    data: rawptr,
    format: rt.TextureFormat,
    width: int,
    height: int,
}

SetTexture :: struct {
    name: base.StrHash,
    texture: TextureHandle,
}

BeginPass :: struct {
    pipeline: PipelineHandle,
}

BeginResourceCreation :: struct {}


SetConstantBuffer :: struct {
    handle: BufferHandle,
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