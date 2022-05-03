package zg

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "core:os"
import "vendor:sdl2"
import "vendor:directx/dxgi"
import "render_d3d12"
import rc "render_commands"
import "render_types"

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
    renderer_state := render_d3d12.create(wx, wy, window_handle)
    renderer_state.mvp = 1
    ri_state: rc.State
    fence: render_types.Handle
    vertex_buffer: render_types.Handle
    pipeline: render_types.Handle

    vertices := [?]f32 {
        // pos            color
         0.0 , 0.5, 0.0,  1,0,0,0,
         0.5, -0.5, 0.0,  0,1,0,0,
        -0.5, -0.5, 0.0,  0,0,1,0,
    }

    vertex_buffer_size := len(vertices) * size_of(vertices[0])

    {
        cmdlist: rc.CommandList
        pipeline = rc.create_pipeline(&ri_state, &cmdlist, f32(wx), f32(wy), render_types.WindowHandle(uintptr(window_handle)))
        vertex_buffer = rc.create_buffer(&ri_state, &cmdlist, rc.VertexBufferDesc { stride = 28 }, rawptr(&vertices[0]), vertex_buffer_size, .Dynamic)
        defer delete(cmdlist)
        fence = rc.create_fence(&ri_state, &cmdlist)
        render_d3d12.submit_command_list(&renderer_state, cmdlist)
    }
    
    main_loop: for {
        render_d3d12.new_frame(&renderer_state)

        for e: sdl2.Event; sdl2.PollEvent(&e) != 0; {
            #partial switch e.type {
                case .QUIT:
                    break main_loop
                case .KEYDOWN:
                    mvp := render_d3d12.mvp(&renderer_state)

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

                    if e.key.keysym.sym == .B {
                        cmdlist: rc.CommandList
                        defer render_d3d12.submit_command_list(&renderer_state, cmdlist)
                        defer delete(cmdlist)

                        nv := [?]f32 {
                            // pos            color
                             0.0 , 1.0, 0.0,  1,0,0,0,
                             0.5, -0.5, 0.0,  0,1,0,0,
                            -0.5, -0.5, 0.0,  0,0,1,0,
                        }

                        nv_size := len(nv) * size_of(nv[0])
                        rc.update_buffer(&cmdlist, vertex_buffer, rawptr(&nv[0]), nv_size)
                    }

                    render_d3d12.set_mvp(&renderer_state, &mvp)
            }
        }

        cmdlist: rc.CommandList
        defer delete(cmdlist)
        append(&cmdlist, rc.SetPipeline {
            handle = pipeline,
        })
        append(&cmdlist, rc.SetScissor {
            rect = { w = f32(wx), h = f32(wy), },
        })
        append(&cmdlist, rc.SetViewport {
            rect = { w = f32(wx), h = f32(wy), },
        })
        append(&cmdlist, rc.ResourceTransition {
            before = .Present,
            after = .RenderTarget,    
        })
        append(&cmdlist, rc.SetRenderTarget { })
        append(&cmdlist, rc.ClearRenderTarget { clear_color = {1, 0, 0, 1} })
        append(&cmdlist, rc.DrawCall {
            vertex_buffer = vertex_buffer,
        })
        append(&cmdlist, rc.ResourceTransition {
            before = .RenderTarget,
            after = .Present,    
        })
        append(&cmdlist, rc.Execute{ pipeline = pipeline, })
        append(&cmdlist, rc.Present{ handle = pipeline })
        append(&cmdlist, rc.WaitForFence { fence = fence, pipeline = pipeline, })
        render_d3d12.draw(&renderer_state, cmdlist)
    }
}
