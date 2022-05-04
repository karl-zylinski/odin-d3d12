package renderer_d3d12

import "core:fmt"
import "core:mem"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "core:math/linalg/hlsl"
import "core:math/linalg"
import "core:sys/windows"
import "core:os"
import rc "../render_commands"
import "../render_types"

NUM_RENDERTARGETS :: 2

BufferView :: union {
    d3d12.VERTEX_BUFFER_VIEW,
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

Pipeline :: struct {
    swapchain: ^dxgi.ISwapChain3,
    queue: ^d3d12.ICommandQueue,
}

None :: struct {
}

ResourceData :: union {
    None,
    Pipeline,
    Fence,
    Buffer,
}

Resource :: struct {
    handle: render_types.Handle,
    resource: ResourceData,
}

State :: struct {
    debug: ^d3d12.IDebug,
    factory: ^dxgi.IFactory4,
    adapter: ^dxgi.IAdapter1,
    device: ^d3d12.IDevice,
    info_queue: ^d3d12.IInfoQueue,
    frame_index: u32,
    rtv_descriptor_heap: ^d3d12.IDescriptorHeap,
    targets: [NUM_RENDERTARGETS]^d3d12.IResource,
    cbv_descriptor_heaps: [NUM_RENDERTARGETS]^d3d12.IDescriptorHeap,
    mvp: hlsl.float4x4,
    mat: [NUM_RENDERTARGETS]^d3d12.IResource,
    mat_ptr: [NUM_RENDERTARGETS]^hlsl.float4x4,
    command_allocator: ^d3d12.ICommandAllocator,
    root_signature: ^d3d12.IRootSignature,
    pipeline: ^d3d12.IPipelineState,
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

        hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, &s.factory)
        check(hr, s.info_queue, "Failed creating factory")
    }

    // Find the DXGI adapter (GPU)
    error_not_found := dxgi.HRESULT(-142213123)

    for i: u32 = 0; s.factory->EnumAdapters1(i, &s.adapter) != error_not_found; i += 1 {
        desc: dxgi.ADAPTER_DESC1
        s.adapter->GetDesc1(&desc)
        if desc.Flags & u32(dxgi.ADAPTER_FLAG.SOFTWARE) != 0 {
            continue
        }

        if d3d12.CreateDevice((^dxgi.IUnknown)(s.adapter), ._12_0, dxgi.IDevice_UUID, nil) >= 0 {
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
        check(hr, s.info_queue, "Failed getting info queue")
    }

    return s
}

set_resource :: proc(s: ^State, handle: render_types.Handle, res: ResourceData) {
    index := int(handle)

    if len(s.resources) < index + 1 {
        resize(&s.resources, index + 1)
    }

    s.resources[index] = { handle = handle, resource = res }
}

submit_command_list :: proc(s: ^State, commands: rc.CommandList) {
    hr: d3d12.HRESULT
    for command in commands {
        #partial switch c in command {
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

                    hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.rtv_descriptor_heap))
                    check(hr, s.info_queue, "Failed creating descriptor heap")
                }


                // Fetch the two render targets from the swapchain
                {
                    rtv_descriptor_size: u32 = s.device->GetDescriptorHandleIncrementSize(.RTV)

                    rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                    s.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

                    for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
                        hr = p.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&s.targets[i]))
                        check(hr, s.info_queue, "Failed getting render target")
                        s.device->CreateRenderTargetView(s.targets[i], nil, rtv_descriptor_handle);
                        rtv_descriptor_handle.ptr += uint(rtv_descriptor_size);
                    }
                }

                {
                    desc := d3d12.DESCRIPTOR_HEAP_DESC {
                        NumDescriptors = 10,
                        Type = .CBV_SRV_UAV,
                        Flags = .SHADER_VISIBLE,
                    };

                    for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
                        hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.cbv_descriptor_heaps[i]))
                        check(hr, s.info_queue, "Failed creating cbv descriptor heap")
                    }
                }

                s.mvp = 1

                {
                    heap_props := d3d12.HEAP_PROPERTIES {
                        Type = .UPLOAD,
                    }

                    resource_desc := d3d12.RESOURCE_DESC {
                        Dimension = .BUFFER,
                        Width = 256,
                        Height = 1,
                        DepthOrArraySize = 1,
                        MipLevels = 1,
                        SampleDesc = { Count = 1, Quality = 0, },
                        Layout = .ROW_MAJOR,
                    }

                    for i := 0; i < NUM_RENDERTARGETS; i += 1 {
                        hr = s.device->CreateCommittedResource(&heap_props, .NONE, &resource_desc, .GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&s.mat[i]))
                        check(hr, s.info_queue, "Failed creating commited resource")

                        r: d3d12.RANGE = {}
                        s.mat[i]->Map(0, &r, (^rawptr)(&s.mat_ptr[i]))
                        mem.copy(s.mat_ptr[i], rawptr(&s.mvp[0]), 128)

                        cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
                            SizeInBytes = 256,
                            BufferLocation = s.mat[i]->GetGPUVirtualAddress(),
                        }

                        mat_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                        s.cbv_descriptor_heaps[i]->GetCPUDescriptorHandleForHeapStart(&mat_handle)
                        s.device->CreateConstantBufferView(&cbv_desc, mat_handle)
                    }
                }

                // The command allocator is used to create the commandlist that is used to tell the GPU what to draw
                hr = s.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&s.command_allocator))
                check(hr, s.info_queue, "Failed creating command allocator")

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
                            RangeType = .CBV,
                            NumDescriptors = 1,
                            BaseShaderRegister = 0,
                            RegisterSpace = 0,
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
                    }

                    root_parameters[0].DescriptorTable = descriptor_table

                    vdesc.Desc_1_0 = {
                        NumParameters = 1,
                        pParameters = &root_parameters[0],
                        Flags = .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
                    }

                    // read https://www.braynzarsoft.net/viewtutorial/q16390-directx-12-constant-buffers-root-descriptor-tables properly

                    //READ

                    // read https://www.gamedev.net/forums/topic/708811-d3d12-best-approach-to-manage-constant-buffer-for-the-frame/5434409/

                    serialized_desc: ^d3d12.IBlob
                    hr = d3d12.SerializeVersionedRootSignature(&vdesc, &serialized_desc, nil)
                    check(hr, s.info_queue, "Failed to serialize root signature")
                    hr = s.device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&s.root_signature))
                    check(hr, s.info_queue, "Failed creating root signature")
                    serialized_desc->Release()
                }

                // The pipeline contains the shaders etc to use
                {
                    // Compile vertex and pixel shaders
                    data :cstring=
                        `cbuffer matrices : register(b0) {
                            float4x4 mvp;
                        };
                        struct PSInput {
                           float4 position : SV_POSITION;
                           float4 color : COLOR;
                        };
                        PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
                           PSInput result;
                           result.position = mul(mvp, position);
                           result.color = color;
                           return result;
                        }
                        float4 PSMain(PSInput input) : SV_TARGET {
                           return input.color;
                        };`

                    data_size: uint = len(data)

                    compile_flags: u32 = 0
                    when ODIN_DEBUG {
                        compile_flags |= u32(d3d_compiler.D3DCOMPILE.DEBUG)
                        compile_flags |= u32(d3d_compiler.D3DCOMPILE.SKIP_OPTIMIZATION)
                    }

                    vs: ^d3d12.IBlob = nil
                    ps: ^d3d12.IBlob = nil

                    hr = d3d_compiler.Compile(rawptr(data), data_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, nil)
                    check(hr, s.info_queue, "Failed to compile vertex shader")

                    hr = d3d_compiler.Compile(rawptr(data), data_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, nil)
                    check(hr, s.info_queue, "Failed to compile pixel shader")

                    // This layout matches the vertices data defined further down
                    vertex_format: []d3d12.INPUT_ELEMENT_DESC = {
                        { 
                            SemanticName = "POSITION", 
                            Format = .R32G32B32_FLOAT, 
                            InputSlotClass = .PER_VERTEX_DATA, 
                        },
                        {   
                            SemanticName = "COLOR", 
                            Format = .R32G32B32A32_FLOAT, 
                            AlignedByteOffset = size_of(f32) * 3, 
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
                        pRootSignature = s.root_signature,
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
                            RenderTarget = { 0 = default_blend_state, 1..7 = {} },
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
                            DepthEnable = false,
                            StencilEnable = false,
                        },
                        InputLayout = {
                            pInputElementDescs = &vertex_format[0],
                            NumElements = u32(len(vertex_format)),
                        },
                        PrimitiveTopologyType = .TRIANGLE,
                        NumRenderTargets = 1,
                        RTVFormats = { 0 = .R8G8B8A8_UNORM, 1..7 = .UNKNOWN },
                        DSVFormat = .UNKNOWN,
                        SampleDesc = {
                            Count = 1,
                            Quality = 0,
                        },
                    };
                    
                    hr = s.device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&s.pipeline))
                    check(hr, s.info_queue, "Pipeline creation failed")

                    vs->Release()
                    ps->Release()
                }

                // Create the commandlist that is reused further down.
                hr = s.device->CreateCommandList(0, .DIRECT, s.command_allocator, s.pipeline, d3d12.ICommandList_UUID, (^rawptr)(&s.cmdlist))
                check(hr, s.info_queue, "Failed to create command list")
                hr = s.cmdlist->Close()
                check(hr, s.info_queue, "Failed to close command list")

                set_resource(s, c.handle, p)
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

                set_resource(s, render_types.Handle(c), f)
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

                switch c.type {
                    case .Static:
                        gpu_data: rawptr
                        read_range: d3d12.RANGE
                        hr = rd.buffer->Map(0, &read_range, &gpu_data)
                        check(hr, s.info_queue, "Failed creating verex buffer resource")
                        mem.copy(gpu_data, c.data, c.size)
                        rd.buffer->Unmap(0, nil)
                    case .Dynamic:
                        hr = s.device->CreateCommittedResource(&heap_props, .NONE, &resource_desc, .GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&rd.staging_buffer))
                        check(hr, s.info_queue, "Failed creating staging buffer")
                        gpu_data: rawptr
                        read_range: d3d12.RANGE
                        hr = rd.staging_buffer->Map(0, &read_range, &gpu_data)
                        check(hr, s.info_queue, "Failed creating verex buffer resource")
                        mem.copy(gpu_data, c.data, c.size)
                        rd.staging_buffer->Unmap(0, nil)
                        rd.staging_buffer_updated = true
                }

                switch d in c.desc {
                    case rc.VertexBufferDesc: {
                        rd.view = d3d12.VERTEX_BUFFER_VIEW {
                            BufferLocation = rd.buffer->GetGPUVirtualAddress(),
                            StrideInBytes = u32(d.stride),
                            SizeInBytes = u32(c.size),
                        }
                    }
                }

                set_resource(s, c.handle, rd)
                free(c.data)
            }

            case rc.UpdateBuffer: {
                if b, ok := &s.resources[c.handle].resource.(Buffer); ok {
                    if b.staging_buffer != nil {
                        gpu_data: rawptr
                        read_range: d3d12.RANGE
                        hr = b.staging_buffer->Map(0, &read_range, &gpu_data)
                        check(hr, s.info_queue, "Failed creating vertex buffer resource")
                        mem.copy(gpu_data, c.data, c.size)
                        b.staging_buffer->Unmap(0, nil)
                        b.staging_buffer_updated = true
                    } else {
                        fmt.println("Trying to update non-updatable buffer")
                    }
                }

                free(c.data)
            }

            case rc.SetPipeline:
                if p, ok := &s.resources[c.handle].resource.(Pipeline); ok {
                    s.cmdlist->SetGraphicsRootSignature(s.root_signature)
                    s.cmdlist->SetDescriptorHeaps(1, &s.cbv_descriptor_heaps[s.frame_index]);
                    table_handle: d3d12.GPU_DESCRIPTOR_HANDLE
                    s.cbv_descriptor_heaps[s.frame_index]->GetGPUDescriptorHandleForHeapStart(&table_handle)
                    s.cmdlist->SetGraphicsRootDescriptorTable(0, table_handle);
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
                })

            case rc.SetRenderTarget:
                rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                s.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

                if (s.frame_index > 0) {
                    size := s.device->GetDescriptorHandleIncrementSize(.RTV)
                    rtv_handle.ptr += uint(s.frame_index * size)
                }

                s.cmdlist->OMSetRenderTargets(1, &rtv_handle, false, nil)

            case rc.ClearRenderTarget: 
                rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                s.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

                if (s.frame_index > 0) {
                    size := s.device->GetDescriptorHandleIncrementSize(.RTV)
                    rtv_handle.ptr += uint(s.frame_index * size)
                }

                cc := c.clear_color
                s.cmdlist->ClearRenderTargetView(rtv_handle, (^[4]f32)(&cc), 0, nil)

            case rc.DrawCall:
                if b, ok := &s.resources[c.vertex_buffer].resource.(Buffer); ok {
                    if vb_view, ok := &b.view.(d3d12.VERTEX_BUFFER_VIEW); ok {
                        num_instances := vb_view.SizeInBytes / vb_view.StrideInBytes
                        s.cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
                        s.cmdlist->IASetVertexBuffers(0, 1, vb_view)
                        s.cmdlist->DrawInstanced(num_instances, 1, 0, 0)
                    }
                }

            case rc.ResourceTransition:
                b := d3d12.RESOURCE_BARRIER {
                    Type = .TRANSITION,
                    Flags = .NONE,
                }

                b.Transition = {
                    pResource = s.targets[s.frame_index],
                    StateBefore = ri_to_d3d_state(c.before),
                    StateAfter = ri_to_d3d_state(c.after),
                    Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                }

                s.cmdlist->ResourceBarrier(1, &b);

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
                    s.frame_index = p->swapchain->GetCurrentBackBufferIndex()
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
}

new_frame :: proc(s: ^State) {
    hr: d3d12.HRESULT
    hr = s.command_allocator->Reset()
    check(hr, s.info_queue, "Failed resetting command allocator")

    hr = s.cmdlist->Reset(s.command_allocator, s.pipeline)
    check(hr, s.info_queue, "Failed to reset command list")
}

ri_to_d3d_state :: proc(ri_state: rc.ResourceState) -> d3d12.RESOURCE_STATES {
    switch ri_state {
        case .Present: return .PRESENT
        case .RenderTarget: return .RENDER_TARGET
    }
    return .COMMON
}

update :: proc(s: ^State) {
    hr: d3d12.HRESULT
    mem.copy(s.mat_ptr[s.frame_index], rawptr(&s.mvp[0]), 128)

    for res in &s.resources {
        if b, ok := &res.resource.(Buffer); ok {
            if b.staging_buffer_updated {
                s.cmdlist->CopyBufferRegion(b.buffer, 0, b.staging_buffer, 0, u64(b.size))
                b.staging_buffer_updated = false
            }
        } 
    }
}

set_mvp :: proc(s: ^State, mvp: ^hlsl.float4x4) {
    s.mvp = mvp^
}

mvp :: proc(s: ^State) -> hlsl.float4x4 {
    return s.mvp
}

check :: proc(res: d3d12.HRESULT, iq: ^d3d12.IInfoQueue, message: string) {
    if (res >= 0) {
        return;
    }

    if iq != nil {
        n := iq->GetNumStoredMessages()
        for i in 0..n {
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
