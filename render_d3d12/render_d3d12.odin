package renderer_d3d12

import "core:fmt"
import "core:mem"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "core:math/linalg/hlsl"
import "core:math/linalg"
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

BufferView :: union {
    d3d12.VERTEX_BUFFER_VIEW,
    d3d12.INDEX_BUFFER_VIEW,
}

Buffer :: struct {
    buffer: ^d3d12.IResource,
    staging_buffer: ^d3d12.IResource,
    staging_buffer_updated: bool,
    size: int,
    view: BufferView,
}

Fence :: struct {
    value: u64,
    fence: ^d3d12.IFence,
    event: dxgi.HANDLE,
}

ConstantBufferMemory :: struct {
    offset: int,
    size: int,
}

DelayedDestroy :: struct {
    res: ^d3d12.IResource,
    destroy_at_frame: u64,
}

Pipeline :: struct {
    swapchain: ^dxgi.ISwapChain3,
    queue: ^d3d12.ICommandQueue,
    frame_index: u32,
    depth: ^d3d12.IResource,
    targets: [NUM_RENDERTARGETS]^d3d12.IResource,
    current_frame: u64,
    dsv_descriptor_heap: ^d3d12.IDescriptorHeap,
    rtv_descriptor_heap: ^d3d12.IDescriptorHeap,
    cbv_descriptor_heap: ^d3d12.IDescriptorHeap,
    constant_buffer_bindless: ^d3d12.IResource,
    constant_buffer_bindless_map: rawptr,
    constant_buffer_memory_info: map[rt.Handle]ConstantBufferMemory,
    constant_buffer_bindless_index: int,
    constant_buffers_destroyed: [dynamic]ConstantBufferMemory,
    command_allocator: ^d3d12.ICommandAllocator,
    delayed_destroy: [dynamic]DelayedDestroy,
}

None :: struct {
}

ShaderConstantBuffer :: struct {
    // This is the index in the GPU-side constant_buffers array
    index: u32,
    name: base.StrHash,
    type: ss.ConstantBufferType,
    size: int,
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
    ConstantBufferMemory,
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
    
    // TODO remove me, use some sort of pool?
    cmdlist: ^d3d12.IGraphicsCommandList,

    wx: i32,
    wy: i32,

    resources: [dynamic]Resource,
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

    return s
}

destroy :: proc(s: ^State) {
    for res in s.resources {
        if res.resource != nil {
            fmt.printf("Renderer resource leak: %v\n", res)
        }
    }

    delete(s.resources)
    
    s.cmdlist->Release()

    if s.info_queue != nil {
        s.info_queue->Release()
    }

    if s.debug != nil {
        s.debug->Release()
    }

    s.device->Release()
    s.adapter->Release()
    s.factory->Release()
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

            if r.staging_buffer != nil {
                r.staging_buffer->Release()
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
            r.queue->Release()
            r.depth->Release()
            r.targets[0]->Release()
            r.targets[1]->Release()
            r.dsv_descriptor_heap->Release()
            r.rtv_descriptor_heap->Release()
            r.cbv_descriptor_heap->Release()
            r.command_allocator->Release()
            r.constant_buffer_bindless->Release()
            delete(r.constant_buffer_memory_info)
            delete(r.constant_buffers_destroyed)
            delete(r.delayed_destroy)
            res^ = Resource{}
        }
        case ConstantBufferMemory: {
            fmt.println("ConstantBufferMemory in destroy_resource not yet implemented")
            // Todo: Should we do something here? All these die along with the pipeline anyways. What if someone calls
            // destroy_resource on a constant buffer handle. Should we maybe not use renderer handles for
            // constant buffers?
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
    }

    return 0
}

submit_command_list :: proc(s: ^State, cmdlist: ^rc.CommandList) {
    hr: d3d12.HRESULT
    for command in &cmdlist.commands {
        switch c in &command {
            case rc.Noop: {}
            case rc.DestroyResource: {
                destroy_resource(s, c.handle)
            }
            case rc.SetTexture: {
                if shader, ok := &s.resources[c.shader].resource.(Shader); ok {
                    if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                        if t, ok := &s.resources[c.texture].resource.(Texture); ok {
                           for st, arr_idx in &shader.textures {
                                if st.name == c.name {
                                    res_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                                    p.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&res_handle)
                                    res_handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) * u32((1 + arr_idx)))

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
            }
            case rc.CreateTexture: {
                if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
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

                    heap_props2 := d3d12.HEAP_PROPERTIES {
                        Type = .DEFAULT, 
                    }

                    hr = s.device->CreateCommittedResource(&heap_props2, .NONE, &texture_desc, .COPY_DEST, nil, d3d12.IResource_UUID, (^rawptr)(&t.res))
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
                        .NONE, // no flags
                        &upload_desc, // resource description for a buffer (storing the image data in this heap just to copy to the default heap)
                        .GENERIC_READ, // We will copy the contents from this heap to the default heap above
                        nil,
                        d3d12.IResource_UUID, (^rawptr)(&texture_upload))

                    delay_destruction(p, texture_upload, 2)

                    check(hr, s.info_queue, "Failed creating commited resource")

                    texture_upload_map: rawptr
                    texture_upload->Map(0, &d3d12.RANGE{}, &texture_upload_map)
                    mem.copy(texture_upload_map, c.data, rt.texture_size(c.format, c.width, c.height))
                    texture_upload->Unmap(0, nil)

                    copy_location := d3d12.TEXTURE_COPY_LOCATION { pResource = texture_upload, Type = .PLACED_FOOTPRINT }

                    s.device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &copy_location.PlacedFootprint, nil, nil, nil);

                    s.cmdlist->CopyTextureRegion(
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

                    s.cmdlist->ResourceBarrier(1, &b);

                    set_resource(s, c.handle, t)

                    free(c.data)
                }
            }
            case rc.SetShader: {
                if shader, ok := &s.resources[c.handle].resource.(Shader); ok {
                    if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                        s.cmdlist->SetGraphicsRootSignature(shader.root_signature)
                        table_handle: d3d12.GPU_DESCRIPTOR_HANDLE
                        p.cbv_descriptor_heap->GetGPUDescriptorHandleForHeapStart(&table_handle)
                        s.cmdlist->SetGraphicsRootDescriptorTable(0, table_handle)
                        s.cmdlist->SetPipelineState(shader.pipeline_state)
                    }
                }
            }
            case rc.UploadConstant: {
                if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                    h := c.constant
                    cb_info, ok := p.constant_buffer_memory_info[h]

                    if !ok {
                        cb_info = {
                            offset = p.constant_buffer_bindless_index,
                            size = c.data_size
                        }
                        p.constant_buffer_bindless_index += c.data_size
                        p.constant_buffer_memory_info[h] = cb_info
                    }

                    set_resource(s, h, cb_info)
                    mem.copy(intrinsics.ptr_offset((^u8)(p.constant_buffer_bindless_map), cb_info.offset), rawptr(&c.data[0]), c.data_size)
                }
            }
            case rc.SetConstant: {
                if shader, ok := &s.resources[c.shader].resource.(Shader); ok {
                    if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                        if cb_info, ok := p.constant_buffer_memory_info[c.constant]; ok {
                            for cb, arr_idx in &shader.constant_buffers {
                                if cb.name == c.name {
                                    s.cmdlist->SetGraphicsRoot32BitConstants(1, 1, &cb_info.offset, u32(arr_idx))
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            case rc.DestroyConstant: {
                if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                    if cb_info, ok := p.constant_buffer_memory_info[c.constant]; ok {
                        append(&p.constant_buffers_destroyed, cb_info)
                        delete_key(&p.constant_buffer_memory_info, c.constant)
                    }
                }
            }
            case rc.CreatePipeline: {
                p: Pipeline
                {
                    desc := d3d12.COMMAND_QUEUE_DESC {
                        Type = .DIRECT,
                    }

                    hr = s.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&p.queue))
                    check(hr, s.info_queue, "Failed creating command queue")
                }

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

                    hr = s.factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(p.queue), d3d12.HWND(uintptr(c.window_handle)), &desc, nil, nil, (^^dxgi.ISwapChain1)(&p.swapchain))
                    check(hr, s.info_queue, "Failed to create swap chain")
                }

                frame_index := p.swapchain->GetCurrentBackBufferIndex()

                // Descripors describe the GPU data and are allocated from a Descriptor Heap
                {
                    desc := d3d12.DESCRIPTOR_HEAP_DESC {
                        NumDescriptors = NUM_RENDERTARGETS,
                        Type = .RTV,
                        Flags = .NONE,
                    };

                    hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&p.rtv_descriptor_heap))
                    check(hr, s.info_queue, "Failed creating descriptor heap")
                }


                // Fetch the two render targets from the swapchain
                {
                    rtv_descriptor_size: u32 = s.device->GetDescriptorHandleIncrementSize(.RTV)

                    rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

                    for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
                        hr = p.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&p.targets[i]))
                        check(hr, s.info_queue, "Failed getting render target")
                        s.device->CreateRenderTargetView(p.targets[i], nil, rtv_descriptor_handle);
                        rtv_descriptor_handle.ptr += uint(rtv_descriptor_size);
                    }
                }

                {
                    desc := d3d12.DESCRIPTOR_HEAP_DESC {
                        NumDescriptors = 33,
                        Type = .CBV_SRV_UAV,
                        Flags = .SHADER_VISIBLE,
                    };

                    hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&p.cbv_descriptor_heap))
                    check(hr, s.info_queue, "Failed creating cbv descriptor heap")
                }

                res_handle: d3d12.CPU_DESCRIPTOR_HANDLE

                {
                    heap_props := d3d12.HEAP_PROPERTIES {
                        Type = .UPLOAD, 
                    }

                    resource_desc := d3d12.RESOURCE_DESC {
                        Dimension = .BUFFER,
                        Width = 10000000,
                        Height = 1,
                        DepthOrArraySize = 1,
                        MipLevels = 1,
                        SampleDesc = { Count = 1, Quality = 0, },
                        Layout = .ROW_MAJOR,
                    }

                    hr = s.device->CreateCommittedResource(&heap_props, .NONE, &resource_desc, .GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&p.constant_buffer_bindless))
                    check(hr, s.info_queue, "Failed creating commited resource")

                    r: d3d12.RANGE = {}
                    p.constant_buffer_bindless->Map(0, &r, (^rawptr)(&p.constant_buffer_bindless_map))

                    cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
                        SizeInBytes = 1024,
                        BufferLocation = p.constant_buffer_bindless->GetGPUVirtualAddress(),
                    }

                    p.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&res_handle)
                    s.device->CreateConstantBufferView(&cbv_desc, res_handle)
                }

                 // Descripors describe the GPU data and are allocated from a Descriptor Heap
                {
                    desc := d3d12.DESCRIPTOR_HEAP_DESC {
                        NumDescriptors = 1,
                        Type = .DSV,
                    };

                    hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&p.dsv_descriptor_heap))
                    check(hr, s.info_queue, "Failed creating DSV descriptor heap")
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

                    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
                        Format = .D32_FLOAT,
                        ViewDimension = .TEXTURE2D,
                    }

                    heap_handle_dsv: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.dsv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&heap_handle_dsv)
                    s.device->CreateDepthStencilView(p.depth, &dsv_desc, heap_handle_dsv);
                }

                // The command allocator is used to create the commandlist that is used to tell the GPU what to draw
                hr = s.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&p.command_allocator))
                check(hr, s.info_queue, "Failed creating command allocator")

                // Create the commandlist that is reused further down.
                hr = s.device->CreateCommandList(0, .DIRECT, p.command_allocator, nil, d3d12.ICommandList_UUID, (^rawptr)(&s.cmdlist))
                check(hr, s.info_queue, "Failed to create command list")
                hr = s.cmdlist->Close()
                check(hr, s.info_queue, "Failed to close command list")

                p.constant_buffer_memory_info = make(map[rt.Handle]ConstantBufferMemory)

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
                    append(&rd.constant_buffers, ShaderConstantBuffer{ type = cb.type, name = base.hash(cb.name), index = CONSTANT_BUFFER_UNINITIALIZED })
                }

                for t in def.textures_2d {
                    append(&rd.textures, ShaderTexture { name = base.hash(t.name) })
                }

                  /* 
                From https://docs.microsoft.com/en-us/windows/win32/direct3d12/root-signatures-overview:
                
                    A root signature is configured by the app and links command lists to the resources the shaders require.
                    The graphics command list has both a graphics and compute root signature. A compute command list will
                    simply have one compute root signature. These root signatures are independent of each other.
                */

                {
                    // create a descriptor range (descriptor table) and fill it out
                    // this is a range of descriptors inside a descriptor heap
                    descriptor_table_ranges: []d3d12.DESCRIPTOR_RANGE = {

                        {
                            RangeType = .SRV,
                            NumDescriptors = 1,
                            BaseShaderRegister = 0,
                            RegisterSpace = 0,
                            OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
                        },

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
                    root_parameters[2].Constants = {
                        ShaderRegister = 0,
                        RegisterSpace = 1, 
                        Num32BitValues = 16,
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
            case rc.CreateFence: {
                f: Fence
                hr = s.device->CreateFence(f.value, .NONE, d3d12.IFence_UUID, (^rawptr)(&f.fence))
                check(hr, s.info_queue, "Failed to create fence")
                f.value += 1
                manual_reset: dxgi.BOOL = false
                initial_state: dxgi.BOOL = false
                f.event = windows.CreateEventW(nil, manual_reset, initial_state, nil)
                if f.event == nil {
                    fmt.println("Failed to create fence event")
                }

                set_resource(s, rt.Handle(c), f)
            }
            case rc.CreateBuffer: {
                // The position and color data for the triangle's vertices go together per-vertex
                heap_props := d3d12.HEAP_PROPERTIES {
                    Type = .UPLOAD,
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
                }

                hr = s.device->CreateCommittedResource(&heap_props, .NONE, &resource_desc, .GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&rd.buffer))
                check(hr, s.info_queue, "Failed buffer")

                gpu_data: rawptr
                read_range: d3d12.RANGE
                hr = rd.buffer->Map(0, &read_range, &gpu_data)
                check(hr, s.info_queue, "Failed creating verex buffer resource")
                mem.copy(gpu_data, c.data, c.size)
                rd.buffer->Unmap(0, nil)

                switch d in c.desc {
                    case rc.VertexBufferDesc: {
                        rd.view = d3d12.VERTEX_BUFFER_VIEW {
                            BufferLocation = rd.buffer->GetGPUVirtualAddress(),
                            StrideInBytes = u32(d.stride),
                            SizeInBytes = u32(c.size),
                        }
                    }
                    case rc.IndexBufferDesc: {
                        rd.view = d3d12.INDEX_BUFFER_VIEW {
                            BufferLocation = rd.buffer->GetGPUVirtualAddress(),
                            Format = .R32_UINT,
                            SizeInBytes = u32(c.size),
                        }
                    }
                }

                set_resource(s, c.handle, rd)
                free(c.data)
            }

            case rc.SetPipeline:
                if p, ok := &s.resources[c.handle].resource.(Pipeline); ok {
                    s.cmdlist->SetDescriptorHeaps(1, &p.cbv_descriptor_heap);
                }

            case rc.SetScissor:
                s.cmdlist->RSSetScissorRects(1, &{
                    left = i32(c.rect.x),
                    top = i32(c.rect.y),
                    right = i32(c.rect.x + c.rect.w),
                    bottom = i32(c.rect.y + c.rect.h),
                })

            case rc.SetViewport:
                s.cmdlist->RSSetViewports(1, &{
                    TopLeftX = c.rect.x,
                    TopLeftY = c.rect.y,
                    Width = c.rect.w,
                    Height = c.rect.h,
                    MinDepth = 0,
                    MaxDepth = 1,
                })

            case rc.SetRenderTarget:
                if p, ok := &s.resources[c.render_target.pipeline].resource.(Pipeline); ok {
                    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

                    if (p.frame_index > 0) {
                        size := s.device->GetDescriptorHandleIncrementSize(.RTV)
                        rtv_handle.ptr += uint(p.frame_index * size)
                    }

                    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.dsv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle);
                    s.cmdlist->OMSetRenderTargets(1, &rtv_handle, false, &dsv_handle)
                }

            case rc.ClearRenderTarget: 
                if p, ok := &s.resources[c.render_target.pipeline].resource.(Pipeline); ok {
                    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

                    if (p.frame_index > 0) {
                        size := s.device->GetDescriptorHandleIncrementSize(.RTV)
                        rtv_handle.ptr += uint(p.frame_index * size)
                    }

                    cc := c.clear_color
                    s.cmdlist->ClearRenderTargetView(rtv_handle, (^[4]f32)(&cc), 0, nil)
                    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    p.dsv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle);
                    s.cmdlist->ClearDepthStencilView(dsv_handle, .DEPTH, 1.0, 0, 0, nil);
                }

            case rc.DrawCall:
                vb_view: d3d12.VERTEX_BUFFER_VIEW
                ib_view: d3d12.INDEX_BUFFER_VIEW
                if b, ok := &s.resources[c.vertex_buffer].resource.(Buffer); ok {
                    vb_view, _ = b.view.(d3d12.VERTEX_BUFFER_VIEW)
                }

                if b, ok := &s.resources[c.index_buffer].resource.(Buffer); ok {
                    ib_view, _ = b.view.(d3d12.INDEX_BUFFER_VIEW)
                }

                num_indices := ib_view.SizeInBytes / 4
                s.cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
                s.cmdlist->IASetVertexBuffers(0, 1, &vb_view)
                s.cmdlist->IASetIndexBuffer(&ib_view)
                s.cmdlist->DrawIndexedInstanced(num_indices, 1, 0, 0, 0)

            case rc.ResourceTransition:
                if p, ok := &s.resources[c.render_target.pipeline].resource.(Pipeline); ok {
                    b := d3d12.RESOURCE_BARRIER {
                        Type = .TRANSITION,
                        Flags = .NONE,
                    }

                    b.Transition = {
                        pResource = p.targets[p.frame_index],
                        StateBefore = ri_to_d3d_state(c.before),
                        StateAfter = ri_to_d3d_state(c.after),
                        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    }

                    s.cmdlist->ResourceBarrier(1, &b);
                }

            case rc.Execute:
                if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                    hr = s.cmdlist->Close()
                    check(hr, s.info_queue, "Failed to close command list")
                    cmdlists := [?]^d3d12.IGraphicsCommandList { s.cmdlist }
                    p.queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))
                }
            
            case rc.Present:
                if p, ok := &s.resources[c.handle].resource.(Pipeline); ok {
                    flags: u32
                    params: dxgi.PRESENT_PARAMETERS
                    hr = p->swapchain->Present1(1, flags, &params)
                    check(hr, s.info_queue, "Present failed")
                    p.frame_index = p->swapchain->GetCurrentBackBufferIndex()
                    p.current_frame += 1
                }

            case rc.WaitForFence:
                if f, ok := &s.resources[c.fence].resource.(Fence); ok {
                    current_fence_value := f.value

                    if p, ok := &s.resources[c.pipeline].resource.(Pipeline); ok {
                        hr = p.queue->Signal(f.fence, current_fence_value)
                        check(hr, s.info_queue, "Failed to signal fence")
                    }

                    f.value += 1
                    completed := f.fence->GetCompletedValue()

                    if completed < current_fence_value {
                        hr = f.fence->SetEventOnCompletion(current_fence_value, f.event)
                        check(hr, s.info_queue, "Failed to set event on completion flag")
                        windows.WaitForSingleObject(f.event, windows.INFINITE);
                    }
                }
        }
    }

    rc.destroy_command_list(cmdlist)
}

new_frame :: proc(s: ^State, pipeline: rt.Handle) {
    if p, ok := &s.resources[pipeline].resource.(Pipeline); ok {
        hr: d3d12.HRESULT
        hr = p.command_allocator->Reset()
        check(hr, s.info_queue, "Failed resetting command allocator")

        hr = s.cmdlist->Reset(p.command_allocator, nil)
        check(hr, s.info_queue, "Failed to reset command list")
    }
}

ri_to_d3d_state :: proc(ri_state: rc.ResourceState) -> d3d12.RESOURCE_STATES {
    switch ri_state {
        case .Present: return .PRESENT
        case .RenderTarget: return .RENDER_TARGET
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

update :: proc(s: ^State, pipeline: rt.Handle) {
    if p, ok := &s.resources[pipeline].resource.(Pipeline); ok {
        for i := 0; i < len(p.delayed_destroy); {
            if p.current_frame >= p.delayed_destroy[i].destroy_at_frame {
                p.delayed_destroy[i].res->Release()
                p.delayed_destroy[i] = pop(&p.delayed_destroy)
                fmt.println(len(p.delayed_destroy))
                continue
            }

            i += 1
        }
    }
}

delay_destruction :: proc(p: ^Pipeline, res: ^d3d12.IResource, num_frames: int) {
    append(&p.delayed_destroy, DelayedDestroy { destroy_at_frame = p.current_frame + u64(num_frames), res = res })
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
