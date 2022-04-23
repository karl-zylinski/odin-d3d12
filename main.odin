package zg

import "core:fmt"
import SDL "vendor:sdl2"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

BUILD_DEBUG :: true
NUM_RENDERTARGETS :: 2

success :: proc(res: d3d12.HRESULT) -> bool {

	if (res < 0) {
		fmt.printf("Fail: %0x\n", u32(res))
	}

	return res >= 0
}

main :: proc() {
	if err := SDL.Init({.VIDEO}); err != 0 {
		fmt.eprintln(err)
		return
	}

	defer SDL.Quit()

	wx := i32(1280)
	wy := i32(720)

	window := SDL.CreateWindow("zg",
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

		if !success(dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, &factory)) {
			fmt.println("Failed creating factory")
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

        if success(d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._11_0, dxgi.IDevice_UUID, nil)) {
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
    device_id :dxgi.IID= {0x189819f1, 0x1db6, 0x4b57, { 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 }}

    if !success(d3d12.CreateDevice((^dxgi.IUnknown)(adapter),  ._11_0,  &device_id, (^rawptr)(&device))) {
    	fmt.println("Failed to create device")
    	return
    }

    command_queue_id :dxgi.IID= {0x0ec870a6, 0x5d7e, 0x4c22, { 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed }}
    queue: ^d3d12.ICommandQueue

    {
    	desc := d3d12.COMMAND_QUEUE_DESC {
    		Type = .DIRECT,
    	}
        if !success(device->CreateCommandQueue(&desc, &command_queue_id, (^rawptr)(&queue))) {
        	fmt.println("Failed creating command queue")
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

        if !success(factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(queue), window_handle, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swapchain))) {
        	fmt.println("Failed to create swap chain");
            return;
        }
    }

    frame_index := swapchain->GetCurrentBackBufferIndex()
	descrptor_heap_id :dxgi.IID= {0x8efb471d, 0x616c, 0x4f49, { 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 }}
    rtvDescriptorHeap: ^d3d12.IDescriptorHeap

    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = NUM_RENDERTARGETS,
            Type = .RTV,
            Flags = .NONE,
        };

        if !success(device->CreateDescriptorHeap(&desc, &descrptor_heap_id, (^rawptr)(&rtvDescriptorHeap))) {
        	fmt.println("Failed creating descriptor heap")
            return
        }
    }

	main_loop: for {
		for e: SDL.Event; SDL.PollEvent(&e) != 0; {
			#partial switch e.type {
				case .QUIT:
					break main_loop
			}
		}
	}
}
