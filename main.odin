package zg

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import SDL "vendor:sdl2"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"

BUILD_DEBUG :: true
NUM_RENDERTARGETS :: 2

assert_ok :: proc(res: d3d12.HRESULT, message: string) -> bool {
    if (res >= 0) {
        return true;
    }

	fmt.printf("%v. Error code: %0x\n", message, u32(res))
    return false;
}

main :: proc() {
	if err := SDL.Init({.VIDEO}); err != 0 {
		fmt.eprintln(err)
		return
	}

	defer SDL.Quit()

	wx := i32(640)
	wy := i32(480)

	window := SDL.CreateWindow("d3d12 triangle",
		SDL.WINDOWPOS_UNDEFINED,
		SDL.WINDOWPOS_UNDEFINED,
		wx, wy,
		{ .ALLOW_HIGHDPI, .SHOWN, .RESIZABLE })

	if window == nil {
		fmt.eprintln(SDL.GetError())
		return
	}

	defer SDL.DestroyWindow(window)

	/*debug: ^d3d12.IDebug

	debug_uuid := &d3d12.IID{0xcf59a98c, 0xa950, 0x4326, {0x91, 0xef, 0x9b, 0xba, 0xa1, 0x7b, 0xfd, 0x95}}

	when BUILD_DEBUG {
		if success(d3d12.GetDebugInterface(debug_uuid, (^rawptr)(&debug))) {
			debug->EnableDebugLayer()
		} else {
			fmt.println("Failed to get debug interface")
			return
		}
	}*/

	factory: ^dxgi.IFactory4

	{
		flags :u32= 0

		when BUILD_DEBUG {
			flags |= dxgi.CREATE_FACTORY_DEBUG
		}

		if !assert_ok(dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, &factory), "Failed creating factory") {
			return
		}
	}

	adapter: ^dxgi.IAdapter1
	error_not_found := dxgi.HRESULT(-142213123)

    for i :u32= 0; factory->EnumAdapters1(i, &adapter) != error_not_found; i += 1 {
        desc: dxgi.ADAPTER_DESC1
        adapter->GetDesc1(&desc)
        if desc.Flags & u32(dxgi.ADAPTER_FLAG.SOFTWARE) != 0 {
            continue
        }

        if d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._11_0, dxgi.IDevice_UUID, nil) >= 0 {
            break
        } else {
            fmt.println("Failed to create device")
        }
    }

    if adapter == nil {
    	fmt.println("Could not find hardware adapter")
    	return
    }

    device: ^d3d12.IDevice

    if !assert_ok(d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._11_0, d3d12.IDevice_UUID, (^rawptr)(&device)), "Failed to create device") {
    	return
    }

    
    queue: ^d3d12.ICommandQueue

    {
    	desc := d3d12.COMMAND_QUEUE_DESC {
    		Type = .DIRECT,
    	}
        if !assert_ok(device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&queue)), "Failed creating command queue") {
        	return
        }
    }

    window_info: SDL.SysWMinfo
    SDL.GetWindowWMInfo(window, &window_info)

    window_handle := dxgi.HWND(window_info.info.win.window)

    swapchain: ^dxgi.ISwapChain3
    
    {
    	desc := dxgi.SWAP_CHAIN_DESC1 {
            Width = u32(wx),
            Height = u32(wy),
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

        if !assert_ok(factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(queue), window_handle, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swapchain)), "Failed to create swap chain") {
            return;
        }
    }

    frame_index := swapchain->GetCurrentBackBufferIndex()
    rtv_descriptor_heap: ^d3d12.IDescriptorHeap

    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = NUM_RENDERTARGETS,
            Type = .RTV,
            Flags = .NONE,
        };

        if !assert_ok(device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&rtv_descriptor_heap)), "Failed creating descriptor heap") {
            return
        }
    }

    targets: [NUM_RENDERTARGETS]^d3d12.IResource

    {
        rtv_descriptor_size :u32= device->GetDescriptorHandleIncrementSize(.RTV);
        rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

        for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
            if !assert_ok(swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&targets[i])), "Failed getting render target") {
                return;
            }
            device->CreateRenderTargetView(targets[i], nil, rtv_descriptor_handle);
            rtv_descriptor_handle.ptr += uint(rtv_descriptor_size);
        }
    }

    command_allocator: ^d3d12.ICommandAllocator

    if !assert_ok(device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&command_allocator)), "Failed creating command allocator") {
        return;
    }

    root_signature: ^d3d12.IRootSignature 

    {
        desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
            Version = ._1_0,
        };

        desc.Desc_1_0.Flags = .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT

        serialized_desc: ^d3d12.IBlob

        if !assert_ok(d3d12.SerializeVersionedRootSignature(&desc, &serialized_desc, nil), "Failed to serialize root signature") {
            return;
        }

        if !assert_ok(device->CreateRootSignature(0,
            serialized_desc->GetBufferPointer(),
            serialized_desc->GetBufferSize(),
            d3d12.IRootSignature_UUID,
            (^rawptr)(&root_signature)), "Failed creating root signature") {
            return;
        }

        serialized_desc->Release()
    }

    pipeline: ^d3d12.IPipelineState

    {
        data :cstring=
            `struct PSInput {
               float4 position : SV_POSITION;
               float4 color : COLOR;
            };
            PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
               PSInput result;
               result.position = position;
               result.color = color;
               return result;
            }
            float4 PSMain(PSInput input) : SV_TARGET {
               return input.color;
            };`

        data_size :uint= len(data)

        compile_flags :u32= 0
        when BUILD_DEBUG {
            compile_flags |= u32(d3dc.D3DCOMPILE.DEBUG)
            compile_flags |= u32(d3dc.D3DCOMPILE.SKIP_OPTIMIZATION)
        }

        vs: ^d3d12.IBlob = nil
        ps: ^d3d12.IBlob = nil

        if !assert_ok(d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, nil), "Failed to compile vertex shader") {
            return;
        }

        if !assert_ok(d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, nil), "Failed to compile pixel shader") {
            return;
        }

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
            pRootSignature = root_signature,
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
        
        if !assert_ok(device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pipeline)), "Pipeline creation failed") {
            return
        }

        vs->Release()
        ps->Release()
    }

    cmdlist: ^d3d12.IGraphicsCommandList

    {
        if !assert_ok(device->CreateCommandList(0, .DIRECT, command_allocator, pipeline, 
                                                    d3d12.ICommandList_UUID,
                                                    (^rawptr)(&cmdlist)), "Failed to create command list") {
            return
        }

        if !assert_ok(cmdlist->Close(), "Failed to close command list") {
            return
        }
    }

    vertex_buffer: ^d3d12.IResource
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW

    {
        aspect := f32(wx) / f32(wy)

        vertices := [?]f32 {
            // pos                          color
             0.0 , 0.5 * aspect, 0.0,  1,0,0,0,
             0.5, -0.5 * aspect, 0.0,  0,1,0,0,
            -0.5, -0.5 * aspect, 0.0,  0,0,1,0,
        }

        heap_props := d3d12.HEAP_PROPERTIES {
            Type = .UPLOAD,
        }

        vertex_buffer_size := len(vertices) * size_of(vertices[0])

        resource_desc := d3d12.RESOURCE_DESC {
            Dimension = .BUFFER,
            Alignment = 0,
            Width = u64(vertex_buffer_size),
            Height = 1,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = .UNKNOWN,
            SampleDesc = { Count = 1, Quality = 0 },
            Layout = .ROW_MAJOR,
            Flags = .NONE,
        }

        if !assert_ok(device->CreateCommittedResource(&heap_props, .NONE, &resource_desc,
            .GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&vertex_buffer)), "Failed creating vertex buffer") {
            return
        }

        gpu_data: rawptr
        read_range: d3d12.RANGE

        if !assert_ok(vertex_buffer->Map(0, &read_range, &gpu_data), "Failed creating verex buffer resource") {
            return
        }

        mem.copy(gpu_data, &vertices[0], vertex_buffer_size)
        vertex_buffer->Unmap(0, nil)

        vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
            BufferLocation = vertex_buffer->GetGPUVirtualAddress(),
            StrideInBytes = u32(vertex_buffer_size/3),
            SizeInBytes = u32(vertex_buffer_size),
        }
    }

    fence_value: u64
    fence: ^d3d12.IFence
    fence_event: windows.HANDLE

    {
        if !assert_ok(device->CreateFence(fence_value, .NONE, d3d12.IFence_UUID, (^rawptr)(&fence)), "Failed to create fence") {
            return;
        }

        fence_value += 1

        manual_reset: windows.BOOL = false
        initial_state: windows.BOOL = false
        fence_event = windows.CreateEventW(nil, manual_reset, initial_state, nil)
        if fence_event == nil {
            //hr = HRESULT_FROM_WIN32(GetLastError());
            fmt.println("Failed to create fence event")
            return
        }
    }

    {
        current_fence_value := fence_value

        if !assert_ok(queue->Signal(fence, current_fence_value), "Failed to signal fence") {
            return;
        }

        fence_value += 1
        completed := fence->GetCompletedValue()

        if completed < current_fence_value {

            if !assert_ok(fence->SetEventOnCompletion(current_fence_value, fence_event), "Failed to set event on completion flag") {
                return;
            }

            windows.WaitForSingleObject(fence_event, windows.INFINITE);
        }

        frame_index = swapchain->GetCurrentBackBufferIndex()
    }

	main_loop: for {
		for e: SDL.Event; SDL.PollEvent(&e) != 0; {
			#partial switch e.type {
				case .QUIT:
					break main_loop
                case .WINDOWEVENT:
                    if e.window.event == .EXPOSED {
                        if !assert_ok(command_allocator->Reset(), "Failed resetting command allocator") {
                            return
                        }

                        if !assert_ok(cmdlist->Reset(command_allocator, pipeline), "Failed to reset command list") {
                            return
                        }

                        viewport := d3d12.VIEWPORT {
                            Width = f32(wx),
                            Height = f32(wy),
                        }

                        scissor_rect := d3d12.RECT {
                            left = 0, right = wx,
                            top = 0, bottom = wy,
                        }

                        // This state is reset everytime the cmd list is reset, so we need to rebind it
                        cmdlist->SetGraphicsRootSignature(root_signature)
                        cmdlist->RSSetViewports(1, &viewport)
                        cmdlist->RSSetScissorRects(1, &scissor_rect)

                        to_render_target_barrier := d3d12.RESOURCE_BARRIER {
                            Type = .TRANSITION,
                            Flags = .NONE,
                        }

                        to_render_target_barrier.Transition = {
                            pResource = targets[frame_index],
                            StateBefore = .PRESENT,
                            StateAfter = .RENDER_TARGET,
                            Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                        }

                        cmdlist->ResourceBarrier(1, &to_render_target_barrier)

                        rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
                        rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

                        if (frame_index > 0) {
                            s := device->GetDescriptorHandleIncrementSize(.RTV)
                            rtv_handle.ptr += uint(frame_index * s)
                        }

                        cmdlist->OMSetRenderTargets(1, &rtv_handle, false, nil)

                        // clear backbuffer
                        clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
                        cmdlist->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)

                        // draw calls!
                        cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
                        cmdlist->IASetVertexBuffers(0, 1, &vertex_buffer_view)
                        cmdlist->DrawInstanced(3, 1, 0, 0)
                        
                        to_present_barrier := to_render_target_barrier
                        to_present_barrier.Transition.StateBefore = .RENDER_TARGET;
                        to_present_barrier.Transition.StateAfter = .PRESENT;

                        cmdlist->ResourceBarrier(1, &to_present_barrier);

                        if !assert_ok(cmdlist->Close(), "Failed to close command list") {
                            return
                        }

                        // execute
                        cmdlists := [?]^d3d12.IGraphicsCommandList { cmdlist }
                        queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))

                        // present
                        {
                            flags: u32
                            params: dxgi.PRESENT_PARAMETERS
                            if !assert_ok(swapchain->Present1(1, flags, &params), "Present failed") {
                                return
                            }
                        }

                        {
                            current_fence_value := fence_value

                            if !assert_ok(queue->Signal(fence, current_fence_value), "Failed to signal fence") {
                                return;
                            }

                            fence_value += 1
                            completed := fence->GetCompletedValue()

                            if completed < current_fence_value {

                                if !assert_ok(fence->SetEventOnCompletion(current_fence_value, fence_event), "Failed to set event on completion flag") {
                                    return;
                                }

                                windows.WaitForSingleObject(fence_event, windows.INFINITE);
                            }

                            frame_index = swapchain->GetCurrentBackBufferIndex()
                        }
                    }
			}
		}
	}
}
