package renderer_d3d12

import "core:fmt"
import "core:mem"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "core:sys/windows"
import "core:strings"
import "core:os"
import rc "../render_commands"
import rt "../render_types"
import ss "../shader_system"
import "core:intrinsics"
import "../base"

NUM_RENDERTARGETS :: 2
CONSTANT_BUFFER_UNINITIALIZED :: 0xFFFFFFFF

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

Shader :: struct {
    pipeline_state: ^d3d12.IPipelineState,
    root_signature: ^d3d12.IRootSignature,
    constant_buffers: [dynamic]ShaderConstantBuffer,
    textures: [dynamic]ShaderTexture,
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
}

get_cbv_handle :: proc(s: ^State, offset: int) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    cbv_handle: d3d12.CPU_DESCRIPTOR_HANDLE

    start := s.cbv_heap_start
    diff := start + offset - CBV_HEAP_SIZE

    if diff >= 0 {
        start = diff
    } else {
        start += offset
    }

    s.cbv_heap->GetCPUDescriptorHandleForHeapStart(&cbv_handle)
    cbv_handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(start))
    return cbv_handle
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

destroy_resource :: proc(s: ^State, handle: rt.Handle) {
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

set_resource :: proc(s: ^State, handle: rt.Handle, res: ResourceData) {
    index := int(handle)

    if len(s.resources) < index + 1 {
        resize(&s.resources, index + 1)
    }

    s.resources[index] = { handle = handle, resource = res }
}

constant_buffer_type_size :: proc(t: ss.ConstantBufferType) -> int {
    switch (t) {
        case .None: return 0
        case .Float4x4: return 64
        case .Float4: return 16
        case .Float3: return 12
        case .Float: return 4
    }

    return 0
}

ensure_cmdlist :: proc(cmdlist: ^d3d12.IGraphicsCommandList) -> bool {
    if cmdlist == nil {
        fmt.println("Trying to issue rendering command without BeginPass command being run first")
        return false
    }

    return true
}

submit_command_list :: proc(s: ^State, commandlist: ^rc.CommandList) {
    hr: d3d12.HRESULT

    cmdlist: ^d3d12.IGraphicsCommandList

    for command in &commandlist.commands {
        cmdswitch: switch c in &command {
            case rc.Noop: {}
            case rc.DestroyResource: {
                destroy_resource(s, c.handle)
            }
            case rc.BeginResourceCreation: {
                if cmdlist != nil {
                    fmt.println("Trying to run BeginResourceCreation twice, or when BeginPass has already been run!")
                    return
                }

                hr = s.resource_cmdallocator->Reset()
                check(hr, s.info_queue, "Failed resetting command allocator")

                hr = s.resource_cmdlist->Reset(s.resource_cmdallocator, nil)
                check(hr, s.info_queue, "Failed to reset command list")

                cmdlist = s.resource_cmdlist
            }
            case rc.BeginPass: {
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

                    cmdlist = bs.cmdlist
                    cmdlist->SetDescriptorHeaps(1, &s.cbv_heap);
                }
            }
            case rc.SetTexture: {
                if shader, ok := &s.resources[c.shader].resource.(Shader); ok {
                    if t, ok := &s.resources[c.texture].resource.(Texture); ok {
                       for st, arr_idx in &shader.textures {
                            if st.name == c.name {
                                res_handle := get_cbv_handle(s, (1 + arr_idx))

                                texture_srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
                                    Format = t.desc.Format,
                                    ViewDimension = .TEXTURE2D,
                                    Shader4ComponentMapping = 5768,
                                }

                                texture_srv_desc.Texture2D.MipLevels = 1

                                s.device->CreateShaderResourceView(t.res, &texture_srv_desc, res_handle)
                                break;
                            }
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

                if !ensure_cmdlist(cmdlist) {
                    break
                }

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

                free(c.data)
            }
            case rc.SetConstantBuffer: {
                if b, ok := &s.resources[c.handle].resource.(Buffer); ok {
                    constant_buffer_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
                        SizeInBytes = u32(b.size),
                        BufferLocation = b.buffer->GetGPUVirtualAddress(),
                    }

                    s.device->CreateConstantBufferView(&constant_buffer_desc, get_cbv_handle(s, 0))
                }
            }
            case rc.SetShader: {
                if shader, ok := &s.resources[c.handle].resource.(Shader); ok {
                    if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                        if !ensure_cmdlist(cmdlist) {
                            break
                        }

                        cmdlist->SetGraphicsRootSignature(shader.root_signature)
                        table_handle: d3d12.GPU_DESCRIPTOR_HANDLE
                        s.cbv_heap->GetGPUDescriptorHandleForHeapStart(&table_handle)

                        table_handle.ptr += u64(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32(s.cbv_heap_start))

                        cmdlist->SetGraphicsRootDescriptorTable(0, table_handle)
                        cmdlist->SetPipelineState(shader.pipeline_state)
                    }
                }
            }
            case rc.SetConstant: {
                if !ensure_cmdlist(cmdlist) {
                    break cmdswitch
                }

                if shader, ok := &s.resources[c.shader].resource.(Shader); ok {
                    for cb, arr_idx in &shader.constant_buffers {
                        if cb.name == c.name {
                            cmdlist->SetGraphicsRoot32BitConstants(1, 1, &c.offset, u32(arr_idx))
                            break;
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

                def := c.shader

                errors: ^d3d12.IBlob = nil

                hr = d3d_compiler.Compile(def.code, uint(def.code_size), nil, nil, nil, "VSMain", "vs_5_1", compile_flags, 0, &vs, &errors)
                errors_sz := errors != nil ? errors->GetBufferSize() : 0

                if errors_sz > 0 {
                    errors_ptr := errors->GetBufferPointer()
                    error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                    fmt.println(error_str)
                }

                check(hr, s.info_queue, "Failed to compile vertex shader")

                hr = d3d_compiler.Compile(def.code, uint(def.code_size), nil, nil, nil, "PSMain", "ps_5_1", compile_flags, 0, &ps, &errors)

                errors_sz = errors != nil ? errors->GetBufferSize() : 0

                if errors_sz > 0 {
                    errors_ptr := errors->GetBufferPointer()
                    error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
                    fmt.println(error_str)
                }

                check(hr, s.info_queue, "Failed to compile pixel shader")

                for cb, cb_idx in def.constant_buffers {
                    append(&rd.constant_buffers, ShaderConstantBuffer{ name = base.hash(cb.name) })
                }

                for t in def.textures_2d {
                    append(&rd.textures, ShaderTexture { name = base.hash(t.name) })
                }

                {
                    descriptor_table_ranges: []d3d12.DESCRIPTOR_RANGE = {
                        // Constant buffer blob
                        {
                            RangeType = .SRV,
                            NumDescriptors = 1,
                            BaseShaderRegister = 0,
                            RegisterSpace = 0,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        },

                        // 32 textures
                        {
                            RangeType = .SRV,
                            NumDescriptors = 32,
                            BaseShaderRegister = 0,
                            RegisterSpace = 1,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        },
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
                        AddressU = .BORDER,
                        AddressV = .BORDER,
                        AddressW = .BORDER,
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
                        pShaderBytecode = vs->GetBufferPointer(),
                        BytecodeLength = vs->GetBufferSize(),
                    },
                    PS = {
                        pShaderBytecode = ps->GetBufferPointer(),
                        BytecodeLength = ps->GetBufferSize(),
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
                    InputLayout = {
                        pInputElementDescs = &vertex_format[0],
                        NumElements = u32(len(vertex_format)),
                    },
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

                vs->Release()
                ps->Release()
                ss.free_shader(&def)
                set_resource(s, c.handle, rd)
            }

            case rc.CreateBuffer: {
                upload_res: ^d3d12.IResource

                if c.data != nil {
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

                if upload_res != nil {
                    cmdlist->CopyBufferRegion(rd.buffer, 0, upload_res, 0, u64(c.size))
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

                    cmdlist->CopyBufferRegion(b.buffer, 0, upload_res, 0, u64(c.size))
                    free(c.data)
                }
            }

            case rc.SetScissor: {
                if !ensure_cmdlist(cmdlist) {
                    break
                }

                cmdlist->RSSetScissorRects(1, &{
                    left = i32(c.rect.x),
                    top = i32(c.rect.y),
                    right = i32(c.rect.x + c.rect.w),
                    bottom = i32(c.rect.y + c.rect.h),
                })
            }

            case rc.SetViewport: {
                if !ensure_cmdlist(cmdlist) {
                    break
                }

                cmdlist->RSSetViewports(1, &{
                    TopLeftX = c.rect.x,
                    TopLeftY = c.rect.y,
                    Width = c.rect.w,
                    Height = c.rect.h,
                    MinDepth = 0,
                    MaxDepth = 1,
                })
            }

            case rc.SetRenderTarget:
                if p, ok := &s.resources[c.render_target.pipeline].resource.(Pipeline); ok {
                    if !ensure_cmdlist(cmdlist) {
                        break
                    }

                    rtv_handle := next_rtv_handle(s)
                    frame_index := p->swapchain->GetCurrentBackBufferIndex()
                    rt := p.backbuffer_states[frame_index].render_target
                    s.device->CreateRenderTargetView(rt, nil, rtv_handle);

                    dsv_handle := next_dsv_handle(s)
                    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
                        Format = .D32_FLOAT,
                        ViewDimension = .TEXTURE2D,
                    }

                    s.device->CreateDepthStencilView(p.depth, &dsv_desc, dsv_handle);
                    cmdlist->OMSetRenderTargets(1, &rtv_handle, false, &dsv_handle)
                }

            case rc.ClearRenderTarget: 
                if p, ok := &s.resources[c.render_target.pipeline].resource.(Pipeline); ok {
                    if !ensure_cmdlist(cmdlist) {
                        break
                    }

                    rtv_handle := next_rtv_handle(s)
                    frame_index := p->swapchain->GetCurrentBackBufferIndex()
                    rt := p.backbuffer_states[frame_index].render_target
                    s.device->CreateRenderTargetView(rt, nil, rtv_handle);
                    cmdlist->ClearRenderTargetView(rtv_handle, (^[4]f32)(&c.clear_color), 0, nil)
                    
                    dsv_handle := next_dsv_handle(s)
                    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
                        Format = .D32_FLOAT,
                        ViewDimension = .TEXTURE2D,
                    }

                    s.device->CreateDepthStencilView(p.depth, &dsv_desc, dsv_handle);
                    cmdlist->ClearDepthStencilView(dsv_handle, .DEPTH, 1.0, 0, 0, nil);
                }

            case rc.DrawCall: {
                if !ensure_cmdlist(cmdlist) {
                    break
                }

                vb_view: d3d12.VERTEX_BUFFER_VIEW
                ib_view: d3d12.INDEX_BUFFER_VIEW
                if b, ok := &s.resources[c.vertex_buffer].resource.(Buffer); ok {
                    vb_view = {
                        BufferLocation = b.buffer->GetGPUVirtualAddress(),
                        StrideInBytes = u32(b.stride),
                        SizeInBytes = u32(b.size),
                    }
                }

                if b, ok := &s.resources[c.index_buffer].resource.(Buffer); ok {
                    ib_view = {
                        BufferLocation = b.buffer->GetGPUVirtualAddress(),
                        Format = .R32_UINT,
                        SizeInBytes = u32(b.size),
                    }
                }

                num_indices := ib_view.SizeInBytes / 4
                cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
                cmdlist->IASetVertexBuffers(0, 1, &vb_view)
                cmdlist->IASetIndexBuffer(&ib_view)
                cmdlist->DrawIndexedInstanced(num_indices, 1, 0, 0, 0)
            }

            case rc.ResourceTransition: {
                if !ensure_cmdlist(cmdlist) {
                    break
                }

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

            case rc.Execute: {
                if !ensure_cmdlist(cmdlist) {
                    break
                }

                hr = cmdlist->Close()
                check(hr, s.info_queue, "Failed to close command list")
                cmdlists := [?]^d3d12.IGraphicsCommandList { cmdlist }
                s.queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))
            }
            
            case rc.Present:
                if p, ok := &s.resources[c.handle].resource.(Pipeline); ok {
                    flags: u32
                    params: dxgi.PRESENT_PARAMETERS
                    frame_index := p->swapchain->GetCurrentBackBufferIndex()
                    hr = p->swapchain->Present1(1, flags, &params)
                    check(hr, s.info_queue, "Present failed")
                    p.num_backbuffer_presents += 1
                    s.queue->Signal(p.backbuffer_fence, p.num_backbuffer_presents)
                    p.backbuffer_states[frame_index].fence_val = p.num_backbuffer_presents 

                    s.cbv_heap_start += 33

                    if s.cbv_heap_start > CBV_HEAP_SIZE {
                        s.cbv_heap_start = 0
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
