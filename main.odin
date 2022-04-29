package zg

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "core:os"
import "vendor:sdl2"
import "vendor:directx/dxgi"
import "renderer_d3d12"
import ri "render_interface"

main :: proc() {
    // Init SDL and create window
    if err := sdl2.Init({.VIDEO}); err != 0 {
        fmt.eprintln(err)
        return
    }

    defer sdl2.Quit()
    wx := i32(640)
    wy := i32(480)
    window := sdl2.CreateWindow("d3d12 triangle", sdl2.WINDOWPOS_UNDEFINED, sdl2.WINDOWPOS_UNDEFINED, wx, wy, { .ALLOW_HIGHDPI, .SHOWN, .RESIZABLE })

    if window == nil {
        fmt.eprintln(sdl2.GetError())
        return
    }

    defer sdl2.DestroyWindow(window)

    // Get the window handle from SDL
    window_info: sdl2.SysWMinfo
    sdl2.GetWindowWMInfo(window, &window_info)
    window_handle := dxgi.HWND(window_info.info.win.window)
    renderer_state := renderer_d3d12.create(wx, wy, window_handle)
    renderer_state.mvp = 1
    ri_state: ri.State
    fence: ri.Handle
    vertex_buffer: ri.Handle

    vertices := [?]f32 {
        // pos            color
         0.0 , 0.5, 0.0,  1,0,0,0,
         0.5, -0.5, 0.0,  0,1,0,0,
        -0.5, -0.5, 0.0,  0,0,1,0,
    }

    vertex_buffer_size := len(vertices) * size_of(vertices[0])

    {
        cmdlist: ri.Command_List
        vertex_buffer = ri.create_buffer(&ri_state, &cmdlist, .Blob, rawptr(&vertices[0]), vertex_buffer_size)
        defer delete(cmdlist)
        fence = ri.create_fence(&ri_state, &cmdlist)
        renderer_d3d12.submit_command_list(&renderer_state, cmdlist)
    }
    
    main_loop: for {
        for e: sdl2.Event; sdl2.PollEvent(&e) != 0; {
            #partial switch e.type {
                case .QUIT:
                    break main_loop
                case .KEYDOWN:
                    mvp := renderer_d3d12.mvp(&renderer_state)

                    if e.key.keysym.sym == .UP {
                        mvp[3][1] += 0.1
                    }
                    if e.key.keysym.sym == .DOWN {
                        mvp[3][1] -= 0.1
                    }
                    if e.key.keysym.sym == .LEFT {
                        mvp[3][0] -= 0.1
                    }
                    if e.key.keysym.sym == .RIGHT {
                        mvp[3][0] += 0.1
                    }

                    renderer_d3d12.set_mvp(&renderer_state, &mvp)
            }
        }

        renderer_d3d12.new_frame(&renderer_state)
        cmdlist: ri.Command_List
        defer delete(cmdlist)
        append(&cmdlist, ri.Command_Resource_Transition {
            before = .Render_Target,
            after = .Present,    
        })
        append(&cmdlist, ri.Command_Execute{})
        append(&cmdlist, ri.Command_Present{})
        append(&cmdlist, ri.Command_Wait_For_Fence(fence))
        renderer_d3d12.draw(&renderer_state, cmdlist)
    }
}
