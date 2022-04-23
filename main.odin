package zg

import "core:fmt"
import SDL "vendor:sdl2"
import D3D12 "vendor:directx/d3d12"
import DXGI "vendor:directx/dxgi"

BUILD_DEBUG :: true

success :: proc(res: D3D12.HRESULT) -> bool {
	return res > 0
}

main :: proc() {
	if err := SDL.Init({.VIDEO}); err != 0 {
		fmt.eprintln(err)
		return
	}

	defer SDL.Quit()

	window := SDL.CreateWindow("zg",
		SDL.WINDOWPOS_UNDEFINED,
		SDL.WINDOWPOS_UNDEFINED,
		1280, 720,
		{ .ALLOW_HIGHDPI, .SHOWN, .RESIZABLE })

	if window == nil {
		fmt.eprintln(SDL.GetError())
		return
	}

	defer SDL.DestroyWindow(window)

	debug: ^D3D12.IDebug = nil

	/*when BUILD_DEBUG {
		if !success(D3D12.GetDebugInterface(D3D12.IDebug_UUID, &debug)) {
			debug->EnableDebugLayer()
		} else {
			fmt.println("Failed to get debug interface")
			return
		}
	}*/

	factory: ^DXGI.IFactory4

	

	main_loop: for {
		for e: SDL.Event; SDL.PollEvent(&e) != 0; {
			#partial switch e.type {
				case .QUIT:
					break main_loop
			}
		}
	}
}