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
import linh "core:math/linalg/hlsl"
import lin "core:math/linalg"

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
    shader: render_types.Handle

    vertices := [?]f32 {
        // pos            color
         0.0 , 0.5, 0.0,  1,0,0,0,
         0.5, -0.5, 0.0,  0,1,0,0,
        -0.5, -0.5, 0.0,  0,0,1,0,

         1.0 , 0.5, 0.0,  1,0,0,0,
         1.5, -0.5, 0.0,  0,1,0,0,
         0.5, -0.5, 0.0,  0,0,1,0,

         2.0 , 0.5, 0.0,  1,0,0,0,
         2.5, -0.5, 0.0,  0,1,0,0,
         1.5, -0.5, 0.0,  0,0,1,0,

         3.0 , 0.5, 0.0,  1,0,0,0,
         3.5, -0.5, 0.0,  0,1,0,0,
         2.5, -0.5, 0.0,  0,0,1,0,

         4.0 , 0.5, 0.0,  1,0,0,0,
         4.5, -0.5, 0.0,  0,1,0,0,
         3.5, -0.5, 0.0,  0,0,1,0,

         5.0 , 0.5, 0.0,  1,0,0,0,
         5.5, -0.5, 0.0,  0,1,0,0,
         4.5, -0.5, 0.0,  0,0,1,0,

         6.0 , 0.5, 0.0,  1,0,0,0,
         6.5, -0.5, 0.0,  0,1,0,0,
         5.5, -0.5, 0.0,  0,0,1,0,

         7.0 , 0.5, 0.0,  1,0,0,0,
         7.5, -0.5, 0.0,  0,1,0,0,
         6.5, -0.5, 0.0,  0,0,1,0,

         8.0 , 0.5, 0.0,  1,0,0,0,
         8.5, -0.5, 0.0,  0,1,0,0,
         7.5, -0.5, 0.0,  0,0,1,0,

         9.0 , 0.5, 0.0,  1,0,0,0,
         9.5, -0.5, 0.0,  0,1,0,0,
         8.5, -0.5, 0.0,  0,0,1,0,

         10.0 , 0.5, 0.0,  1,0,0,0,
         10.5, -0.5, 0.0,  0,1,0,0,
         9.5, -0.5, 0.0,  0,0,1,0,
    }

    vertex_buffer_size := len(vertices) * size_of(vertices[0])

    {
        cmdlist: rc.CommandList
        pipeline = rc.create_pipeline(&ri_state, &cmdlist, f32(wx), f32(wy), render_types.WindowHandle(uintptr(window_handle)))
        f, err := os.open("shader.shader")
        defer os.close(f)
        fs, _ := os.file_size(f)
        shader_code := make([]byte, fs, context.temp_allocator)
        os.read(f, shader_code)
        shader = rc.create_shader(&ri_state, &cmdlist, rawptr(&shader_code[0]), int(fs))
        vertex_buffer = rc.create_buffer(&ri_state, &cmdlist, rc.VertexBufferDesc { stride = 28 }, rawptr(&vertices[0]), vertex_buffer_size, .Dynamic)
        defer delete(cmdlist)
        fence = rc.create_fence(&ri_state, &cmdlist)
        render_d3d12.submit_command_list(&renderer_state, cmdlist)
    }

    camera_pos := linh.float3 { 0, 0, -1 }
    camera_yaw: f32 = 0
    camera_pitch: f32 = 0

    main_loop: for {
        render_d3d12.new_frame(&renderer_state)

        camera_rot_x := lin.matrix4_rotate(camera_pitch, lin.Vector3f32{1, 0, 0})
        camera_rot_y := lin.matrix4_rotate(camera_yaw, lin.Vector3f32{0, 1, 0})
        camera_rot := lin.mul(camera_rot_y, camera_rot_x)

        for e: sdl2.Event; sdl2.PollEvent(&e) != 0; {
            #partial switch e.type {
                case .QUIT:
                    break main_loop
                case .KEYDOWN:
                    if e.key.keysym.sym == .W {
                        camera_pos += lin.mul(camera_rot, linh.float4{0,0,1,1}).xyz * 0.1
                    }
                    if e.key.keysym.sym == .S {
                        camera_pos -= lin.mul(camera_rot, linh.float4{0,0,1,1}).xyz * 0.1
                    }
                    if e.key.keysym.sym == .A {
                        camera_pos -= lin.mul(camera_rot, linh.float4{1,0,0,1}).xyz * 0.1
                    }
                    if e.key.keysym.sym == .D {
                        camera_pos += lin.mul(camera_rot, linh.float4{1,0,0,1}).xyz * 0.1
                    }

                    if e.key.keysym.sym == .B {
                        cmdlist: rc.CommandList
                        defer render_d3d12.submit_command_list(&renderer_state, cmdlist)
                        defer delete(cmdlist)

                        nv := [?]f32 {
                            // pos            color
                             0.0 , 1.0, 0,  1,0,0,0,
                             0.5, -0.5, 0,  0,1,0,0,
                            -0.5, -0.5, 0,  0,0,1,0,
                        }

                        nv_size := len(nv) * size_of(nv[0])
                        rc.update_buffer(&cmdlist, vertex_buffer, rawptr(&nv[0]), nv_size)
                    }

                case .MOUSEMOTION: {
                    camera_yaw += f32(e.motion.xrel) * 0.001
                    camera_pitch += f32(e.motion.yrel) * 0.001
                }
            }
        }

        camera_trans: linh.float4x4 = 1
        camera_trans[3].xyz = ([3]f32)(camera_pos)
        view: linh.float4x4 = linh.inverse(lin.mul(camera_trans, linh.float4x4(camera_rot)))

        near: f32 = 0.01
        far: f32 = 100

        mvp := lin.mul(linh.float4x4 {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, far/(far - near), (-far * near)/(far - near),
            0, 0, 1.0, 0,
        }, view)
        render_d3d12.set_mvp(&renderer_state, &mvp)

        render_d3d12.update(&renderer_state)

        cmdlist: rc.CommandList
        defer delete(cmdlist)
        append(&cmdlist, rc.SetPipeline {
            handle = pipeline,
        })
        append(&cmdlist, rc.SetShader {
            handle = shader,
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
        append(&cmdlist, rc.ClearRenderTarget { clear_color = {0, 0, 0, 1} })
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
        render_d3d12.submit_command_list(&renderer_state, cmdlist)
    }
}
