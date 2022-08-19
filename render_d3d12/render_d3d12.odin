package render_d3d12

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "core:strings"
import "core:os"
import "core:log"
import "core:intrinsics"

import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxc"

import rc "ze:render_commands"
import rt "ze:render_types"
import ss "ze:shader_system"
import "ze:base"

NUM_RENDERTARGETS :: 2

CBV_HEAP_SIZE :: 1000
RTV_HEAP_SIZE :: 100
DSV_HEAP_SIZE :: 10

Buffer :: struct {
    buffer: ^d3d12.IResource,
    size: int,
    stride: int,
    state: d3d12.RESOURCE_STATES,
}

Fence :: struct {
    value: u64,
    fence: ^d3d12.IFence,
    event: dxgi.HANDLE,
}

DelayedDestroy :: struct {
    res: ^d3d12.IResource,
    destroy_at_frame: u64,
}

BackbufferState :: struct {
    cmdallocator: ^d3d12.ICommandAllocator,
    cmdlist: ^d3d12.IGraphicsCommandList,
    fence_val: u64,
    render_target: ^d3d12.IResource,
}

Pipeline :: struct {
    swapchain: ^dxgi.ISwapChain3,
    depth: ^d3d12.IResource,
    backbuffer_fence: ^d3d12.IFence,
    num_backbuffer_presents: u64,

    backbuffer_states: [NUM_RENDERTARGETS]BackbufferState,
}

None :: struct {
}

ShaderConstantBuffer :: struct {
    name: base.StrHash,
}

ShaderTexture :: struct {
    name: base.StrHash,
}

VertexInput :: struct {
    name: base.StrHash,
}

Shader :: struct {
    pipeline_state: ^d3d12.IPipelineState,
    root_signature: ^d3d12.IRootSignature,
    constant_buffers: [dynamic]ShaderConstantBuffer,
    textures: [dynamic]ShaderTexture,
    vertex_inputs: [dynamic]VertexInput,
}

Texture :: struct {
    res: ^d3d12.IResource,
    desc: d3d12.RESOURCE_DESC,
}

ResourceData :: union {
    None,
    Pipeline,
    Fence,
    Buffer,
    Shader,
    Texture,
}

Resource :: struct {
    handle: rt.Handle,
    resource: ResourceData,
}

State :: struct {
    debug: ^d3d12.IDebug,
    factory: ^dxgi.IFactory4,
    adapter: ^dxgi.IAdapter1,
    device: ^d3d12.IDevice,
    info_queue: ^d3d12.IInfoQueue,

    wx: i32,
    wy: i32,

    resources: [dynamic]Resource,
    delayed_destroy: [dynamic]DelayedDestroy,

    frame_idx: u64,

    cbv_heap: ^d3d12.IDescriptorHeap,

    // This one is advanced manually since we must match the root signature, so it is managaed a bit more manually.
    cbv_heap_start: int,

    rtv_heap: ^d3d12.IDescriptorHeap,
    rtv_heap_start: int,

    dsv_heap: ^d3d12.IDescriptorHeap,
    dsv_heap_start: int,

    resource_cmdallocator: ^d3d12.ICommandAllocator,
    resource_cmdlist: ^d3d12.IGraphicsCommandList,

    queue: ^d3d12.ICommandQueue,

    dxc_library: ^dxc.ILibrary,
    dxc_compiler: ^dxc.ICompiler,
}

get_constant_buffer_handle :: proc(s: ^State, shader: ^Shader) -> Maybe(d3d12.CPU_DESCRIPTOR_HANDLE) {
    if len(shader.constant_buffers) == 0 {
        return nil
    }

    handle_index := s.cbv_heap_start

    if handle_index == CBV_HEAP_SIZE - 1 {
        handle_index = 0
    }

    handle: d3d12.CPU_DESCRIPTOR_HANDLE
    s.cbv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
    handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(handle_index))
    return handle
}

get_texture_handle :: proc(s: ^State, shader: ^Shader, name: base.StrHash) -> Maybe(d3d12.CPU_DESCRIPTOR_HANDLE) {
    if len(shader.textures) == 0 {
        return nil
    }

    handle_index := s.cbv_heap_start + (len(shader.constant_buffers) > 0 ? 1 : 0)
    found := false

    for t in shader.textures {
        if t.name == name {
            found = true
            break
        }

        handle_index += 1
    }

    if found == false {
        return nil
    }

    diff := handle_index - CBV_HEAP_SIZE

    if diff >= 0 {
        handle_index = diff
    }

    handle: d3d12.CPU_DESCRIPTOR_HANDLE
    s.cbv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
    handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(handle_index))
    return handle
}

get_vertex_buffer_handle :: proc(s: ^State, shader: ^Shader) -> Maybe(d3d12.CPU_DESCRIPTOR_HANDLE) {
    if len(shader.vertex_inputs) == 0 {
        return nil
    }

    handle_index := s.cbv_heap_start + (len(shader.constant_buffers) > 0 ? 1 : 0) + len(shader.textures)
    diff := handle_index - CBV_HEAP_SIZE

    if diff >= 0 {
        handle_index = diff
    }

    handle: d3d12.CPU_DESCRIPTOR_HANDLE
    s.cbv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
    handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(handle_index))
    return handle
}

get_total_number_of_handles :: proc(shader: ^Shader) -> int {
    return (len(shader.constant_buffers) > 0 ? 1 : 0) + len(shader.textures) + (len(shader.vertex_inputs) > 0 ? 1 : 0)
}

next_rtv_handle :: proc(s: ^State) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    s.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
    rtv_handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.RTV) * u32(s.rtv_heap_start))
    s.rtv_heap_start += 1

    if s.rtv_heap_start >= RTV_HEAP_SIZE {
        s.rtv_heap_start = 0
    }

    return rtv_handle
}

next_dsv_handle :: proc(s: ^State) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    s.dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
    dsv_handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.DSV) * u32(s.dsv_heap_start))
    s.dsv_heap_start += 1

    if s.dsv_heap_start >= DSV_HEAP_SIZE {
        s.dsv_heap_start = 0
    }

    return dsv_handle
}

create :: proc(wx: i32, wy: i32, window_handle: dxgi.HWND) -> (s: State) {
    s.wx = wx
    s.wy = wy
    hr: d3d12.HRESULT
    // Init debug layer
    when ODIN_DEBUG {
        hr = d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&s.debug))

        check(hr, s.info_queue, "Failed creating debug interface")
        s.debug->EnableDebugLayer()
    }

    // Init DXGI factory. DXGI is the link between the window and DirectX
    {
        flags: u32 = 0

        when ODIN_DEBUG {
            flags |= dxgi.CREATE_FACTORY_DEBUG
        }

        hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, (^rawptr)(&s.factory))
        check(hr, s.info_queue, "Failed creating factory")
    }

    // Find the DXGI adapter (GPU)
    error_not_found := dxgi.HRESULT(-142213123)

    for i: u32 = 0; s.factory->EnumAdapters1(i, &s.adapter) != error_not_found; i += 1 {
        if d3d12.CreateDevice((^dxgi.IUnknown)(s.adapter), ._12_0, d3d12.IDevice_UUID, nil) == 1 {
            break
        } else {
            fmt.println("Failed to create device")
        }
    }

    if s.adapter == nil {
        fmt.println("Could not find hardware adapter")
        return s
    }

    // Create D3D12 device that represents the GPU
    
    hr = d3d12.CreateDevice((^dxgi.IUnknown)(s.adapter), ._12_1, d3d12.IDevice_UUID, (^rawptr)(&s.device))
    check(hr, s.info_queue, "Failed to create device")
 
    when ODIN_DEBUG {
        hr = s.device->QueryInterface(d3d12.IInfoQueue_UUID, (^rawptr)(&s.info_queue))
        //check(hr, s.info_queue, "Failed getting info queue")
    }

    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = RTV_HEAP_SIZE,
            Type = .RTV,
            Flags = .NONE,
        };

        hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.rtv_heap))
        check(hr, s.info_queue, "Failed creating descriptor heap")
    }

    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = DSV_HEAP_SIZE,
            Type = .DSV,
        };

        hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.dsv_heap))
        check(hr, s.info_queue, "Failed creating DSV descriptor heap")
    }


    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = CBV_HEAP_SIZE,
            Type = .CBV_SRV_UAV,
            Flags = .SHADER_VISIBLE,
        };

        hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.cbv_heap))
        check(hr, s.info_queue, "Failed creating cbv descriptor heap")
    }

    {
        desc := d3d12.COMMAND_QUEUE_DESC {
            Type = .DIRECT,
        }

        hr = s.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&s.queue))
        check(hr, s.info_queue, "Failed creating command queue")
    }

    {
        hr = s.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&s.resource_cmdallocator))
        check(hr, s.info_queue, "Failed creating command allocator")

        hr = s.device->CreateCommandList(0, .DIRECT, s.resource_cmdallocator, nil, d3d12.ICommandList_UUID, (^rawptr)(&s.resource_cmdlist))
        check(hr, s.info_queue, "Failed to create command list")
        hr = s.resource_cmdlist->Close()
        check(hr, s.info_queue, "Failed to close command list")
    }

    // DXC
    {
        hr = dxc.CreateInstance(dxc.CLSID_Library, dxc.ILibrary_UUID, (^rawptr)(&s.dxc_library))
        check(hr, s.info_queue, "Failed to create DXC library")
        hr = dxc.CreateInstance(dxc.CLSID_Compiler, dxc.ICompiler_UUID, (^rawptr)(&s.dxc_compiler))
        check(hr, s.info_queue, "Failed to create DXC compiler")
    }

    return s
}

destroy :: proc(s: ^State) {
    for res in s.resources {
        if res.resource != nil {
            fmt.printf("Renderer resource leak: %v\n", res)
        }
    }

    delete(s.resources)

    if s.info_queue != nil {
        s.info_queue->Release()
    }

    if s.debug != nil {
        s.debug->Release()
    }

    s.device->Release()
    s.adapter->Release()
    s.factory->Release()
    s.rtv_heap->Release()
    s.dsv_heap->Release()
    s.cbv_heap->Release()
    s.queue->Release()

    delete(s.delayed_destroy)
}

destroy_resource :: proc(s: ^State, handle: rc.AnyHandle) {
    res := &s.resources[handle]

    switch r in res.resource {
        case None: {
            res^ = Resource{}
        }
        case Texture: {
            r.res->Release()
            res^ = Resource{}
        }
        case Buffer: {
            if r.buffer != nil {
                r.buffer->Release()
            }

            res^ = Resource{}
        }
        case Fence: {
            r.fence->Release()
            res^ = Resource{}
        }
        case Shader: {
            r.pipeline_state->Release()
            r.root_signature->Release()
            delete(r.constant_buffers)
            delete(r.textures)
            delete(r.vertex_inputs)
            res^ = Resource{}
        }
        case Pipeline: {
            r.swapchain->Release()
            r.depth->Release()

            for bs in r.backbuffer_states {
                bs.cmdallocator->Reset()
                bs.cmdlist->Release()    
            }

            res^ = Resource{}
        }
    }
}

set_resource :: proc(s: ^State, handle: $T/rt.Handle, res: ResourceData) {
    index := int(handle)

    if len(s.resources) < index + 1 {
        resize(&s.resources, index + 1)
    }

    s.resources[index] = { handle = rt.Handle(handle), resource = res }
}

constant_buffer_type_size :: proc(t: ss.ShaderType) -> int {
    switch (t) {
        case .None: return 0
        case .Float4x4: return 64
        case .Float4: return 16
        case .Float3: return 12
        case .Float2: return 8
        case .Float: return 4
    }

    return 0
}

ensure_cmdlist :: proc(cmdlist: Maybe(^d3d12.IGraphicsCommandList)) -> bool {
    c, ok := cmdlist.?

    if ok {
        return true
    }

    fmt.println("Trying to issue rendering command without BeginPass command being run first")
    return false
}

maybe_assert :: proc(m: Maybe($T), sfmt: string, args: ..any, loc := #caller_location) -> (T, bool) {
    v, ok := m.?
    fmt.assertf(condition=ok, fmt=sfmt, args=args, loc=loc)
    return v, ok
}

cmdlist_assert :: proc(m: Maybe($T), loc := #caller_location) -> (T, bool) {
    v, ok := m.?
    fmt.assertf(condition=ok, fmt="Trying to issue rendering command without BeginPass command being run first", loc=loc, args={})
    return v, ok
}

submit_command_list :: proc(s: ^State, commandlist: ^rc.CommandList) {
    hr: d3d12.HRESULT

    // Only set by BeginResourceCreation or BeginPass
    current_cmdlist: Maybe(^d3d12.IGraphicsCommandList)

    // Only set by SetShader
    current_shader: Maybe(^Shader)

    // Only be set by BeginPass
    current_pipeline: Maybe(^Pipeline)

    for command in &commandlist.commands {
        cmdswitch: switch c in &command {
            case rc.Noop: {}
            case rc.DestroyResource: {
                destroy_resource(s, c.handle)
            }
            case rc.BeginResourceCreation: {
                if current_cmdlist != nil {
                    fmt.println("Trying to run BeginResourceCreation twice, or when BeginPass has already been run!")
                    return
                }

                hr = s.resource_cmdallocator->Reset()
                check(hr, s.info_queue, "Failed resetting command allocator")

                hr = s.resource_cmdlist->Reset(s.resource_cmdallocator, nil)
                check(hr, s.info_queue, "Failed to reset command list")

                current_cmdlist = s.resource_cmdlist
            }
            case rc.BeginPass: {
                if current_cmdlist != nil {
                    fmt.println("Trying to run BeginPass twice, or when BeginResourceCreation has already been run!")
                    return
                }

                if current_pipeline != nil {
                    fmt.println("Trying to run BeginPass twice!")
                    return
                }

                if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                    frame_index := p->swapchain->GetCurrentBackBufferIndex()
                    bs := &p.backbuffer_states[frame_index]

                    completed_fence_value := p.backbuffer_fence->GetCompletedValue()
                    if completed_fence_value < bs.fence_val {
                        p.backbuffer_fence->SetEventOnCompletion(bs.fence_val, nil)
                    }

                    hr = bs.cmdallocator->Reset()
                    check(hr, s.info_queue, "Failed resetting command allocator")

                    hr = bs.cmdlist->Reset(bs.cmdallocator, nil)
                    check(hr, s.info_queue, "Failed to reset command list")

                    bs.cmdlist->SetDescriptorHeaps(1, &s.cbv_heap);
                    current_cmdlist = bs.cmdlist
                    current_pipeline = p
                }
            }
            case rc.SetTexture: {
                if shader, ok := maybe_assert(current_shader, "Shader not set"); ok {
                    if t, ok := &s.resources[c.texture].resource.(Texture); ok {
                        if handle, ok := get_texture_handle(s, shader, c.name).?; ok {
                            texture_srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
                                Format = t.desc.Format,
                                ViewDimension = .TEXTURE2D,
                                Shader4ComponentMapping = 5768,
                            }

                            texture_srv_desc.Texture2D.MipLevels = 1

                            s.device->CreateShaderResourceView(t.res, &texture_srv_desc, handle)
                        }
                    }
                }
            }
            case rc.CreateTexture: {
                t: Texture

                texture_desc := d3d12.RESOURCE_DESC {
                    Dimension = .TEXTURE2D,
                    Width = u64(c.width),
                    Height = u32(c.height),
                    Format = d3d_format(c.format),
                    DepthOrArraySize = 1,
                    MipLevels = 1,
                    SampleDesc = { Count = 1, Quality = 0, },
                }

                t.desc = texture_desc

                hr = s.device->CreateCommittedResource(&d3d12.HEAP_PROPERTIES { Type = .DEFAULT, }, .NONE, &texture_desc, .COPY_DEST, nil, d3d12.IResource_UUID, (^rawptr)(&t.res))
                check(hr, s.info_queue, "Failed creating commited resource")

                tex_size: u64
                s.device->GetCopyableFootprints(&texture_desc, 0, 1, 0, nil, nil, nil, &tex_size);

                upload_desc := d3d12.RESOURCE_DESC {
                    Dimension = .BUFFER,
                    Width = u64(tex_size),
                    Height = 1,
                    DepthOrArraySize = 1,
                    MipLevels = 1,
                    SampleDesc = { Count = 1, Quality = 0, },
                    Layout = .ROW_MAJOR,
                }

                texture_upload: ^d3d12.IResource

                hr = s.device->CreateCommittedResource(
                    &d3d12.HEAP_PROPERTIES { Type = .UPLOAD },
                    .NONE,
                    &upload_desc,
                    .GENERIC_READ,
                    nil,
                    d3d12.IResource_UUID, (^rawptr)(&texture_upload))

                delay_destruction(s, texture_upload, 2)

                check(hr, s.info_queue, "Failed creating commited resource")

                texture_upload_map: rawptr
                texture_upload->Map(0, &d3d12.RANGE{}, &texture_upload_map)
                mem.copy(texture_upload_map, c.data, rt.texture_size(c.format, c.width, c.height))
                texture_upload->Unmap(0, nil)

                copy_location := d3d12.TEXTURE_COPY_LOCATION { pResource = texture_upload, Type = .PLACED_FOOTPRINT }

                s.device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &copy_location.PlacedFootprint, nil, nil, nil);

                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    cmdlist->CopyTextureRegion(
                            &d3d12.TEXTURE_COPY_LOCATION { pResource = t.res },
                            0, 0, 0, 
                            &copy_location,
                            nil)

                    b := d3d12.RESOURCE_BARRIER {
                        Type = .TRANSITION,
                        Flags = .NONE,
                    }

                    b.Transition = {
                        pResource = t.res,
                        StateBefore = .COPY_DEST,
                        StateAfter = .PIXEL_SHADER_RESOURCE,
                        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    }

                    cmdlist->ResourceBarrier(1, &b);

                    set_resource(s, c.handle, t)
                }

                free(c.data)
            }
            case rc.SetConstantBuffer: {
                if shader, ok := maybe_assert(current_shader, "Shader not set"); ok {
                    if b, ok := &s.resources[c.handle].resource.(Buffer); ok {
                        constant_buffer_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
                            SizeInBytes = u32(b.size),
                            BufferLocation = b.buffer->GetGPUVirtualAddress(),
                        }

                        if cb_handle, ok := get_constant_buffer_handle(s, shader).?; ok {
                            s.device->CreateConstantBufferView(&constant_buffer_desc, cb_handle)    
                        }
                    }
                }
            }
            case rc.SetShader: {
                if shader, ok := &s.resources[c.handle].resource.(Shader); ok {
                    if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                        cmdlist->SetGraphicsRootSignature(shader.root_signature)
                        table_handle: d3d12.GPU_DESCRIPTOR_HANDLE
                        s.cbv_heap->GetGPUDescriptorHandleForHeapStart(&table_handle)

                        table_handle.ptr += u64(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(s.cbv_heap_start))

                        cmdlist->SetGraphicsRootDescriptorTable(0, table_handle)
                        cmdlist->SetPipelineState(shader.pipeline_state)

                        current_shader = shader
                    }
                }
            }
            case rc.SetConstant: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    if shader, ok := maybe_assert(current_shader, "Shader not set"); ok {
                        for cb, arr_idx in &shader.constant_buffers {
                            if cb.name == c.name {
                                cmdlist->SetGraphicsRoot32BitConstants(1, 1, &c.offset, u32(arr_idx))
                                break;
                            }
                        }
                    }
                }
            }
            case rc.CreatePipeline: {
                p: Pipeline
                
                // Create the swapchain, it's the thing that contains render targets that we draw into. It has 2 render targets (NUM_RENDERTARGETS), giving us double buffering.
                {
                    desc := dxgi.SWAP_CHAIN_DESC1 {
                        Width = u32(c.swapchain_x),
                        Height = u32(c.swapchain_y),
                        Format = .R8G8B8A8_UNORM,
                        SampleDesc = {
                            Count = 1,
                            Quality = 0,
                        },
                        BufferUsage = .RENDER_TARGET_OUTPUT,
                        BufferCount = NUM_RENDERTARGETS,
                        Scaling = .NONE,
                        SwapEffect = .FLIP_DISCARD,
                        AlphaMode = .UNSPECIFIED,
                    };

                    hr = s.factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(s.queue), d3d12.HWND(uintptr(c.window_handle)), &desc, nil, nil, (^^dxgi.ISwapChain1)(&p.swapchain))
                    check(hr, s.info_queue, "Failed to create swap chain")
                }

                frame_index := p.swapchain->GetCurrentBackBufferIndex()

                // Fetch the two render targets from the swapchain
                {
                    for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
                        hr = p.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&p.backbuffer_states[i].render_target))
                        check(hr, s.info_queue, "Failed getting render target")
                    }
                }

              
                {
                    heap_props := d3d12.HEAP_PROPERTIES {
                        Type = .DEFAULT,
                    }

                    ds_desc := d3d12.RESOURCE_DESC {
                        Dimension = .TEXTURE2D,
                        Width = u64(s.wx),
                        Height = u32(s.wy),
                        DepthOrArraySize = 1,
                        MipLevels = 1,
                        Format = .D32_FLOAT,
                        SampleDesc = { Count = 1, },
                        Flags = .ALLOW_DEPTH_STENCIL,
                    }

                    clear_value := d3d12.CLEAR_VALUE {
                        Format = .D32_FLOAT,
                    }

                    clear_value.DepthStencil = { Depth = 1.0, }

                    s.device->CreateCommittedResource(
                        &heap_props,
                        .NONE,
                        &ds_desc,
                        .DEPTH_WRITE,
                        &clear_value,
                        d3d12.IResource_UUID,
                        (^rawptr)(&p.depth),
                    );
                }

                for i := 0; i < NUM_RENDERTARGETS; i += 1 {
                    hr = s.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&p.backbuffer_states[i].cmdallocator))
                    check(hr, s.info_queue, "Failed creating command allocator")

                    hr = s.device->CreateCommandList(0, .DIRECT, p.backbuffer_states[i].cmdallocator, nil, d3d12.ICommandList_UUID, (^rawptr)(&p.backbuffer_states[i].cmdlist))
                    check(hr, s.info_queue, "Failed to create command list")
                    hr = p.backbuffer_states[i].cmdlist->Close()
                    check(hr, s.info_queue, "Failed to close command list")
                }

                {
                    hr = s.device->CreateFence(0, .NONE, d3d12.IFence_UUID, (^rawptr)(&p.backbuffer_fence))
                    check(hr, s.info_queue, "Failed to create fence")
                }

                set_resource(s, c.handle, p)
            }
            case rc.CreateShader: {
                rd: Shader

                compile_flags: u32 = 0
                when ODIN_DEBUG {
                    compile_flags |= u32(d3d_compiler.D3DCOMPILE.DEBUG)
                    compile_flags |= u32(d3d_compiler.D3DCOMPILE.SKIP_OPTIMIZATION)
                }

                vs: ^d3d12.IBlob = nil
                ps: ^d3d12.IBlob = nil

                vs_compiled: ^dxc.IBlob
                ps_compiled: ^dxc.IBlob

                def := c.shader

                {
                    source_blob: ^dxc.IBlobEncoding
                    hr = s.dxc_library->CreateBlobWithEncodingOnHeapCopy(def.code, u32(def.code_size), dxc.CP_UTF8, &source_blob)
                    check(hr, s.info_queue, "Failed creating shader blob")

                    errors: ^dxc.IBlobEncoding

                    vs_res: ^dxc.IOperationResult
                    hr = s.dxc_compiler->Compile(source_blob, windows.utf8_to_wstring("shader.shader"), windows.utf8_to_wstring("vertex_shader"), windows.utf8_to_wstring("vs_6_2"), nil, 0, nil, 0, nil, &vs_res)
                    check(hr, s.info_queue, "Failed compiling vertex shader")
                    vs_res->GetResult(&vs_compiled)
                    check(hr, s.info_queue, "Failed fetching compiled vertex shader")

                    vs_res->GetErrorBuffer(&errors)
                    errors_sz := errors != nil ? errors->GetBufferSize() : 0

                    if errors_sz > 0 {
                        errors_ptr := errors->GetBufferPointer()
                        error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                        fmt.println(error_str)
                    }

                    ps_res: ^dxc.IOperationResult
                    hr = s.dxc_compiler->Compile(source_blob, windows.utf8_to_wstring("shader.shader"), windows.utf8_to_wstring("pixel_shader"), windows.utf8_to_wstring("ps_6_2"), nil, 0, nil, 0, nil, &ps_res)
                    check(hr, s.info_queue, "Failed compiling pixel shader")
                    ps_res->GetResult(&ps_compiled)
                    check(hr, s.info_queue, "Failed fetching compiled pixel shader")

                    ps_res->GetErrorBuffer(&errors)
                    errors_sz = errors != nil ? errors->GetBufferSize() : 0

                    if errors_sz > 0 {
                        errors_ptr := errors->GetBufferPointer()
                        error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                        fmt.println(error_str)
                    }
                }


             /*   errors: ^d3d12.IBlob = nil

                hr = d3d_compiler.Compile(def.code, uint(def.code_size), nil, nil, nil, "vertex_shader", "vs_5_1", compile_flags, 0, &vs, &errors)
                errors_sz := errors != nil ? errors->GetBufferSize() : 0

                if errors_sz > 0 {
                    errors_ptr := errors->GetBufferPointer()
                    error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                    fmt.println(error_str)
                }

                check(hr, s.info_queue, "Failed to compile vertex shader")

                hr = d3d_compiler.Compile(def.code, uint(def.code_size), nil, nil, nil, "pixel_shader", "ps_5_1", compile_flags, 0, &ps, &errors)


                errors_sz = errors != nil ? errors->GetBufferSize() : 0

                if errors_sz > 0 {
                    errors_ptr := errors->GetBufferPointer()
                    error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                    fmt.println(error_str)
                }

                check(hr, s.info_queue, "Failed to compile pixel shader")*/

                for cb, cb_idx in def.constant_buffers {
                    append(&rd.constant_buffers, ShaderConstantBuffer{ name = base.hash(cb.name) })
                }

                for t in def.textures_2d {
                    append(&rd.textures, ShaderTexture { name = base.hash(t.name) })
                }

                for s in def.vertex_inputs {
                    append(&rd.vertex_inputs, VertexInput { name = base.hash(s.name) })   
                }

                total_num_handles := get_total_number_of_handles(&rd) 
                if total_num_handles > (CBV_HEAP_SIZE / NUM_RENDERTARGETS) {
                    fmt.printf("Shader uses too many handles, wants: %v. Avaiable: %v (calculated using %v/NUM_RENDERTARGETS, where NUM_RENDERTARGETS is %v)\n", total_num_handles, CBV_HEAP_SIZE/NUM_RENDERTARGETS, CBV_HEAP_SIZE, NUM_RENDERTARGETS)
                }

                {
                    descriptor_table_ranges := make([dynamic]d3d12.DESCRIPTOR_RANGE, context.temp_allocator)

                    if len(def.constant_buffers) > 0 {
                        append(&descriptor_table_ranges, d3d12.DESCRIPTOR_RANGE {
                            RangeType = .SRV,
                            NumDescriptors = 1,
                            BaseShaderRegister = 0,
                            RegisterSpace = 0,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        })
                    }

                    if len(def.textures_2d) > 0 {
                        append(&descriptor_table_ranges, d3d12.DESCRIPTOR_RANGE {
                            RangeType = .SRV,
                            NumDescriptors = u32(len(def.textures_2d)),
                            BaseShaderRegister = 0,
                            RegisterSpace = 1,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        })
                    }

                    if len(def.vertex_inputs) > 0 {
                        append(&descriptor_table_ranges, d3d12.DESCRIPTOR_RANGE {
                            RangeType = .SRV,
                            NumDescriptors = 1,
                            BaseShaderRegister = 0,
                            RegisterSpace = 2,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        })
                    }

                    descriptor_table: d3d12.ROOT_DESCRIPTOR_TABLE = {
                        NumDescriptorRanges = u32(len(descriptor_table_ranges)),
                        pDescriptorRanges = &descriptor_table_ranges[0],
                    }

                    vdesc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
                        Version = ._1_0,
                    };

                    root_parameters: []d3d12.ROOT_PARAMETER = {
                        {
                            ParameterType = .DESCRIPTOR_TABLE,
                            ShaderVisibility = .ALL,
                        },
                        {
                            ParameterType = ._32BIT_CONSTANTS,
                            ShaderVisibility = .ALL,
                        },
                    }

                    root_parameters[0].DescriptorTable = descriptor_table
                    root_parameters[1].Constants = {
                        ShaderRegister = 0,
                        RegisterSpace = 0, 
                        Num32BitValues = 32,
                    }

                    // create a static sampler
                    sampler := d3d12.STATIC_SAMPLER_DESC {
                        Filter = .MIN_MAG_MIP_POINT,
                        AddressU = .CLAMP,
                        AddressV = .CLAMP,
                        AddressW = .CLAMP,
                        MipLODBias = 0,
                        MaxAnisotropy = 0,
                        ComparisonFunc = .NEVER,
                        BorderColor = .TRANSPARENT_BLACK,
                        MinLOD = 0,
                        MaxLOD = d3d12.FLOAT32_MAX,
                        ShaderRegister = 0,
                        RegisterSpace = 0,
                        ShaderVisibility = .PIXEL,
                    }

                    vdesc.Desc_1_0 = {
                        NumParameters = u32(len(root_parameters)),
                        pParameters = &root_parameters[0],
                        Flags = .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
                        NumStaticSamplers = 1,
                        pStaticSamplers = &sampler,
                    }

                    serialized_desc: ^d3d12.IBlob
                    ser_error: ^d3d12.IBlob
                    hr = d3d12.SerializeVersionedRootSignature(&vdesc, &serialized_desc, &ser_error)

                    if ser_error != nil {
                        fmt.println(strings.string_from_ptr((^u8)(ser_error->GetBufferPointer()), int(ser_error->GetBufferSize())))
                    }
                    check(hr, s.info_queue, "Failed to serialize root signature")
                    hr = s.device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&rd.root_signature))
                    check(hr, s.info_queue, "Failed creating root signature")
                    serialized_desc->Release()
                }

                // This layout matches the vertices data defined further down
                vertex_format: []d3d12.INPUT_ELEMENT_DESC = {
                    { 
                        SemanticName = "POSITION", 
                        Format = .R32G32B32_FLOAT, 
                        InputSlotClass = .PER_VERTEX_DATA, 
                    },
                    {   
                        SemanticName = "NORMAL", 
                        Format = .R32G32B32_FLOAT, 
                        AlignedByteOffset = size_of(f32) * 3, 
                        InputSlotClass = .PER_VERTEX_DATA, 
                    },
                    {   
                        SemanticName = "TEXCOORD", 
                        Format = .R32G32_FLOAT, 
                        AlignedByteOffset = size_of(f32) * 6, 
                        InputSlotClass = .PER_VERTEX_DATA, 
                    },
                }

                default_blend_state := d3d12.RENDER_TARGET_BLEND_DESC {
                    BlendEnable = false,
                    LogicOpEnable = false,

                    SrcBlend = .ONE,
                    DestBlend = .ZERO,
                    BlendOp = .ADD,

                    SrcBlendAlpha = .ONE,
                    DestBlendAlpha = .ZERO,
                    BlendOpAlpha = .ADD,

                    LogicOp = .NOOP,
                    RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE.ALL),
                };

                pipeline_state_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC {
                    pRootSignature = rd.root_signature,
                    VS = {
                        pShaderBytecode = vs_compiled->GetBufferPointer(),
                        BytecodeLength = vs_compiled->GetBufferSize(),
                    },
                    PS = {
                        pShaderBytecode = ps_compiled->GetBufferPointer(),
                        BytecodeLength = ps_compiled->GetBufferSize(),
                    },
                    StreamOutput = {},
                    BlendState = {
                        AlphaToCoverageEnable = false,
                        IndependentBlendEnable = false,
                        RenderTarget = { 0 = default_blend_state, 1..=7 = {} },
                    },
                    SampleMask = 0xFFFFFFFF,
                    RasterizerState = {
                        FillMode = .SOLID,
                        CullMode = .BACK,
                        FrontCounterClockwise = false,
                        DepthBias = 0,
                        DepthBiasClamp = 0,
                        SlopeScaledDepthBias = 0,
                        DepthClipEnable = true,
                        MultisampleEnable = false,
                        AntialiasedLineEnable = false,
                        ForcedSampleCount = 0,
                        ConservativeRaster = .OFF,
                    },
                    DepthStencilState = {
                        DepthEnable = true,
                        DepthWriteMask = .ALL,
                        DepthFunc = .LESS,
                        StencilEnable = false,
                    },
                  /*  InputLayout = {
                        pInputElementDescs = &vertex_format[0],
                        NumElements = u32(len(vertex_format)),
                    },*/
                    PrimitiveTopologyType = .TRIANGLE,
                    NumRenderTargets = 1,
                    RTVFormats = { 0 = .R8G8B8A8_UNORM, 1..=7 = .UNKNOWN },
                    DSVFormat = .D32_FLOAT,
                    SampleDesc = {
                        Count = 1,
                        Quality = 0,
                    },
                };

                hr = s.device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&rd.pipeline_state))
                check(hr, s.info_queue, "Pipeline creation failed")

                /*vs->Release()
                ps->Release()*/
                ss.free_shader(&def)
                set_resource(s, c.handle, rd)
            }

            case rc.CreateBuffer: {
                upload_res: ^d3d12.IResource

                if c.data != nil {
                    upload_desc := d3d12.RESOURCE_DESC {
                        Dimension = .BUFFER,
                        Width = u64(c.data_size),
                        Height = 1,
                        DepthOrArraySize = 1,
                        MipLevels = 1,
                        SampleDesc = { Count = 1, Quality = 0, },
                        Layout = .ROW_MAJOR,
                    }

                    hr = s.device->CreateCommittedResource(
                        &d3d12.HEAP_PROPERTIES { Type = .UPLOAD },
                        .NONE,
                        &upload_desc,
                        .GENERIC_READ,
                        nil,
                        d3d12.IResource_UUID, (^rawptr)(&upload_res))

                    check(hr, s.info_queue, "Failed creating commited resource")
                    delay_destruction(s, upload_res, 2)

                    upload_map: rawptr
                    upload_res->Map(0, &d3d12.RANGE{}, &upload_map)
                    mem.copy(upload_map, c.data, c.data_size)    
                    upload_res->Unmap(0, nil)
                }

                resource_desc := d3d12.RESOURCE_DESC {
                    Dimension = .BUFFER,
                    Alignment = 0,
                    Width = u64(c.size),
                    Height = 1,
                    DepthOrArraySize = 1,
                    MipLevels = 1,
                    Format = .UNKNOWN,
                    SampleDesc = { Count = 1, Quality = 0 },
                    Layout = .ROW_MAJOR,
                    Flags = .NONE,
                }

                rd := Buffer {
                    size = c.size,
                    stride = c.stride,
                    state = .COPY_DEST,
                }

                hr = s.device->CreateCommittedResource(&d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }, .NONE, &resource_desc, .COPY_DEST, nil, d3d12.IResource_UUID, (^rawptr)(&rd.buffer))
                check(hr, s.info_queue, "Failed buffer")

                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok && upload_res != nil {
                    cmdlist->CopyBufferRegion(rd.buffer, 0, upload_res, 0, u64(c.data_size))
                }

                set_resource(s, c.handle, rd)

                if c.data != nil {
                    free(c.data)
                }
            }

            case rc.UpdateBuffer: {
                if b, ok := &s.resources[c.handle].resource.(Buffer); ok {
                    if !fmt.assertf(b.state == .COPY_DEST, "Resource not in before-state %v", d3d12.RESOURCE_STATES.COPY_DEST) {
                        return
                    }

                    if !fmt.assertf(b.size > c.size, "New buffer won't fit inside old. Old size: %v. New size: %v", b.size, c.size) {
                        return
                    }

                    upload_res: ^d3d12.IResource

                    {
                        upload_desc := d3d12.RESOURCE_DESC {
                            Dimension = .BUFFER,
                            Width = u64(c.size),
                            Height = 1,
                            DepthOrArraySize = 1,
                            MipLevels = 1,
                            SampleDesc = { Count = 1, Quality = 0, },
                            Layout = .ROW_MAJOR,
                        }

                        hr = s.device->CreateCommittedResource(
                            &d3d12.HEAP_PROPERTIES { Type = .UPLOAD },
                            .NONE,
                            &upload_desc,
                            .GENERIC_READ,
                            nil,
                            d3d12.IResource_UUID, (^rawptr)(&upload_res))

                        check(hr, s.info_queue, "Failed creating commited resource")
                        delay_destruction(s, upload_res, 2)

                        upload_map: rawptr
                        upload_res->Map(0, &d3d12.RANGE{}, &upload_map)
                        mem.copy(upload_map, c.data, c.size)
                        upload_res->Unmap(0, nil)
                    }


                    if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                        cmdlist->CopyBufferRegion(b.buffer, 0, upload_res, 0, u64(c.size))
                    }

                    free(c.data)
                }
            }

            case rc.SetScissor: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    cmdlist->RSSetScissorRects(1, &{
                        left = i32(c.rect.x),
                        top = i32(c.rect.y),
                        right = i32(c.rect.x + c.rect.w),
                        bottom = i32(c.rect.y + c.rect.h),
                    })
                }
            }

            case rc.SetViewport: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    cmdlist->RSSetViewports(1, &{
                        TopLeftX = c.rect.x,
                        TopLeftY = c.rect.y,
                        Width = c.rect.w,
                        Height = c.rect.h,
                        MinDepth = 0,
                        MaxDepth = 1,
                    })
                }
            }

            case rc.SetRenderTarget: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    rt: ^d3d12.IResource
                    depth: ^d3d12.IResource

                    if p, ok := &s.resources[c.resource].resource.(Pipeline); ok {
                        frame_index := p->swapchain->GetCurrentBackBufferIndex()   
                        rt = p.backbuffer_states[frame_index].render_target
                        depth = p.depth
                    }

                    if !fmt.assertf(rt != nil && depth != nil, "Could not resolve render target for resource %v", c.resource) {
                        return
                    }

                    rtv_handle := next_rtv_handle(s)
                    s.device->CreateRenderTargetView(rt, nil, rtv_handle);

                    dsv_handle := next_dsv_handle(s)
                    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
                        Format = .D32_FLOAT,
                        ViewDimension = .TEXTURE2D,
                    }

                    s.device->CreateDepthStencilView(depth, &dsv_desc, dsv_handle)
                    cmdlist->OMSetRenderTargets(1, &rtv_handle, false, &dsv_handle)
                }
            }

            case rc.ClearRenderTarget: 
                if p, ok := &s.resources[c.resource].resource.(Pipeline); ok {
                    if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                        rtv_handle := next_rtv_handle(s)
                        frame_index := p->swapchain->GetCurrentBackBufferIndex()
                        rt := p.backbuffer_states[frame_index].render_target
                        s.device->CreateRenderTargetView(rt, nil, rtv_handle)
                        cmdlist->ClearRenderTargetView(rtv_handle, (^[4]f32)(&c.clear_color), 0, nil)
                        
                        dsv_handle := next_dsv_handle(s)
                        dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
                            Format = .D32_FLOAT,
                            ViewDimension = .TEXTURE2D,
                        }

                        s.device->CreateDepthStencilView(p.depth, &dsv_desc, dsv_handle)
                        cmdlist->ClearDepthStencilView(dsv_handle, .DEPTH, 1.0, 0, 0, nil);
                    }
                }

            case rc.DrawCall: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    ib_view: d3d12.INDEX_BUFFER_VIEW

                    if b, ok := &s.resources[c.index_buffer].resource.(Buffer); ok {
                        ib_view = {
                            BufferLocation = b.buffer->GetGPUVirtualAddress(),
                            Format = .R32_UINT,
                            SizeInBytes = u32(b.size),
                        }
                    }

                    if shader, ok := maybe_assert(current_shader, "Shader not set"); ok {
                        if b, ok := &s.resources[c.vertex_buffer].resource.(Buffer); ok {
                            if handle, ok := get_vertex_buffer_handle(s, shader).?; ok {
                                texture_srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
                                    Format = .R32_TYPELESS,
                                    ViewDimension = .BUFFER,
                                    Shader4ComponentMapping = 5768,
                                }

                                texture_srv_desc.Buffer = {
                                    NumElements = u32(b.size) / 4,
                                }

                                texture_srv_desc.Buffer.Flags = .RAW
                                s.device->CreateShaderResourceView(b.buffer, &texture_srv_desc, handle)
                            }
                        }
                    }

                    num_indices := ib_view.SizeInBytes / 4
                    cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
                    cmdlist->IASetIndexBuffer(&ib_view)
                    cmdlist->DrawIndexedInstanced(num_indices, 1, 0, 0, 0)
                }
            }

            case rc.ResourceTransition: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    res: ^d3d12.IResource
                    before := ri_to_d3d_state(c.before)
                    after := ri_to_d3d_state(c.after)

                    #partial switch r in &s.resources[c.resource].resource {
                        case Pipeline: {
                            frame_index := r->swapchain->GetCurrentBackBufferIndex()
                            res = r.backbuffer_states[frame_index].render_target
                        }
                        case Buffer: {
                            if !fmt.assertf(r.state == before, "Resource not in before-state %v", before) {
                                return
                            }
                            res = r.buffer
                            r.state = after
                        }
                        case: {
                            fmt.printf("ResourceTransition not implemented for type %v", r)
                            return
                        }
                    }

                    if res != nil {
                        b := d3d12.RESOURCE_BARRIER {
                            Type = .TRANSITION,
                            Flags = .NONE,
                        }

                        b.Transition = {
                            pResource = res,
                            StateBefore = before,
                            StateAfter = after,
                            Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                        }

                        cmdlist->ResourceBarrier(1, &b);
                    }
                }
            }

            case rc.Execute: {
                if cmdlist, ok := cmdlist_assert(current_cmdlist); ok {
                    hr = cmdlist->Close()
                    check(hr, s.info_queue, "Failed to close command list")
                    cmdlists := [?]^d3d12.IGraphicsCommandList { cmdlist }
                    s.queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))
                }
            }
            
            case rc.Present:
                if shader, ok := maybe_assert(current_shader, "Shader not set"); ok {
                    if p, ok := maybe_assert(current_pipeline, "Pipeline not set"); ok {
                        flags: u32
                        params: dxgi.PRESENT_PARAMETERS
                        frame_index := p->swapchain->GetCurrentBackBufferIndex()
                        hr = p->swapchain->Present1(1, flags, &params)
                        check(hr, s.info_queue, "Present failed")
                        p.num_backbuffer_presents += 1
                        s.queue->Signal(p.backbuffer_fence, p.num_backbuffer_presents)
                        p.backbuffer_states[frame_index].fence_val = p.num_backbuffer_presents 
                        tot_cb_handles := get_total_number_of_handles(shader)

                        if (s.cbv_heap_start + tot_cb_handles) >= CBV_HEAP_SIZE {
                            s.cbv_heap_start = 0
                        } else {
                            s.cbv_heap_start += tot_cb_handles
                        }
                    }
                }
        }
    }

    rc.destroy_command_list(commandlist)
}

ri_to_d3d_state :: proc(ri_state: rc.ResourceState) -> d3d12.RESOURCE_STATES {
    switch ri_state {
        case .Present: return .PRESENT
        case .RenderTarget: return .RENDER_TARGET
        case .CopyDest: return .COPY_DEST
        case .ConstantBuffer: return .VERTEX_AND_CONSTANT_BUFFER
        case .VertexBuffer: return .VERTEX_AND_CONSTANT_BUFFER
        case .IndexBuffer: return .INDEX_BUFFER
    }
    return .COMMON
}

d3d_format :: proc(fmt: rt.TextureFormat) -> dxgi.FORMAT {
    switch fmt {
        case .Unknown: return .UNKNOWN
        case .R8G8B8A8_UNORM: return .R8G8B8A8_UNORM
    }
    return .UNKNOWN
}

update :: proc(s: ^State) {
    for i := 0; i < len(s.delayed_destroy); {
        if s.frame_idx >= s.delayed_destroy[i].destroy_at_frame {
            s.delayed_destroy[i].res->Release()
            s.delayed_destroy[i] = pop(&s.delayed_destroy)
            continue
        }

        i += 1
    }

    s.frame_idx += 1
}

delay_destruction :: proc(s: ^State, res: ^d3d12.IResource, num_frames: int) {
    append(&s.delayed_destroy, DelayedDestroy { destroy_at_frame = s.frame_idx + u64(num_frames), res = res })
}

check :: proc(res: d3d12.HRESULT, iq: ^d3d12.IInfoQueue, message: string) {
    if (res >= 0) {
        return;
    }

    if iq != nil {
        n := iq->GetNumStoredMessages()
        for i in 0..=n {
            msglen: d3d12.SIZE_T
            iq->GetMessageA(i, nil, &msglen)

            if msglen > 0 {
                fmt.println(msglen)

                msg := (^d3d12.MESSAGE)(mem.alloc(int(msglen)))
                iq->GetMessageA(i, msg, &msglen)
                fmt.println(msg.pDescription)
                mem.free(msg)
            }
        }
    }

    fmt.printf("%v. Error code: %0x\n", message, u32(res))
    os.exit(-1)
}
