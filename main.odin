package zg

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sys/windows"
import "core:os"
import "vendor:sdl2"
import "vendor:directx/dxgi"
import "render_d3d12"
import rc "render_commands"
import "render_types"
import linh "core:math/linalg/hlsl"
import lin "core:math/linalg"

load_teapot :: proc() -> ([dynamic]f32, [dynamic]u32)  {
    f, err := os.open("teapot.obj")
    defer os.close(f)
    fs, _ := os.file_size(f)
    teapot_bytes := make([]byte, fs, context.temp_allocator)
    os.read(f, teapot_bytes)
    teapot := strings.string_from_ptr(&teapot_bytes[0], int(fs))
    out: [dynamic]f32
    indices_out: [dynamic]u32

    parse_comment :: proc(teapot: string, i_in: int) -> int {
        i := i_in
        for teapot[i] != '\n' {
            i += 1
        }

        i += 1
        return i
    }

    skip_whitespace :: proc(teapot: string, i_in: int) -> int {
        i := i_in

        for i < len(teapot) {
            if teapot[i] != ' ' && teapot[i] != '\t' && teapot[i] != '\n' {
                return i
            }
            i += 1
        }

        return i
    }

    parse_number :: proc(teapot: string, i_in: int) -> (int, f32) {
        i := i_in
        start := i

        for teapot[i] != ' ' && teapot[i] != '\n' && teapot[i] != '\t' {
            i += 1
        }

        num, ok := strconv.parse_f32(teapot[start:i])
        return i, num
    }

    parse_vertex :: proc(teapot: string, i_in: int, out: ^[dynamic]f32) -> int {
        i := skip_whitespace(teapot, i_in + 1)
        n0, n1, n2: f32
        i, n0 = parse_number(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n1 = parse_number(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n2 = parse_number(teapot, i)
        append(out, n0, n1, n2)
        return i
    }

    parse_face_index :: proc(teapot: string, i_in: int) -> (int, u32, u32) {
        i := i_in
        start := i

        for teapot[i] != '/' {
            i += 1
        }

        ii, _ := strconv.parse_int(teapot[start:i])
        i += 2

        start = i

        for teapot[i] != ' ' && teapot[i] != '\n' && teapot[i] != '\t' {
            i += 1
        }

        ni, _ := strconv.parse_int(teapot[start:i])

        return i, u32(ii - 1), u32(ni - 1)
    }

    parse_face :: proc(teapot: string, i_in: int, out: ^[dynamic]u32) -> int {
        i := skip_whitespace(teapot, i_in + 1)
        n0, n1, n2: u32
        i, n0, _ = parse_face_index(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n1, _ = parse_face_index(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n2, _ = parse_face_index(teapot, i)
        append(out, n0, n1, n2)
        return i
    }

    for i := 0; i < len(teapot); i += 1 {
        switch teapot[i] {
            case '#': i = parse_comment(teapot, i)
            case 'v': if teapot[i + 1] != 'n' {
                i = parse_vertex(teapot, i, &out)
            }
            case 'f': i = parse_face(teapot, i, &indices_out)
        }
    }

    fmt.println(len(out)/3)

    return out, indices_out
}

main :: proc() {
    // Init SDL and create window
    if err := sdl2.Init({.VIDEO}); err != 0 {
        fmt.eprintln(err)
        return
    }

    defer sdl2.Quit()
    wx := i32(1200)
    wy := i32(1200)
    window := sdl2.CreateWindow("d3d12 triangle", sdl2.WINDOWPOS_UNDEFINED, sdl2.WINDOWPOS_UNDEFINED, wx, wy, { .ALLOW_HIGHDPI, .SHOWN, .RESIZABLE })

    if window == nil {
        fmt.eprintln(sdl2.GetError())
        return
    }

    sdl2.SetWindowGrab(window, true)
    sdl2.CaptureMouse(true)
    sdl2.SetRelativeMouseMode(true)
    defer sdl2.DestroyWindow(window)

    vertices, indices := load_teapot()

    // Get the window handle from SDL
    window_info: sdl2.SysWMinfo
    sdl2.GetWindowWMInfo(window, &window_info)
    window_handle := dxgi.HWND(window_info.info.win.window)
    renderer_state := render_d3d12.create(wx, wy, window_handle)
    ri_state: rc.State
    fence: render_types.Handle
    vertex_buffer: render_types.Handle
    index_buffer: render_types.Handle
    pipeline: render_types.Handle
    shader: render_types.Handle

    vertex_buffer_size := len(vertices) * size_of(vertices[0])
    index_buffer_size := len(indices) * size_of(indices[0])

    {
        cmdlist: rc.CommandList
        pipeline = rc.create_pipeline(&ri_state, &cmdlist, f32(wx), f32(wy), render_types.WindowHandle(uintptr(window_handle)))
        f, err := os.open("shader.shader")
        defer os.close(f)
        fs, _ := os.file_size(f)
        shader_code := make([]byte, fs, context.temp_allocator)
        os.read(f, shader_code)
        shader = rc.create_shader(&ri_state, &cmdlist, rawptr(&shader_code[0]), int(fs))
        vertex_buffer = rc.create_buffer(&ri_state, &cmdlist, rc.VertexBufferDesc { stride = 12 }, rawptr(&vertices[0]), vertex_buffer_size, .Dynamic)
        index_buffer = rc.create_buffer(&ri_state, &cmdlist, rc.IndexBufferDesc { stride = 4 }, rawptr(&indices[0]), index_buffer_size, .Dynamic)
        defer delete(cmdlist)
        fence = rc.create_fence(&ri_state, &cmdlist)
        render_d3d12.submit_command_list(&renderer_state, cmdlist)
    }

    camera_pos := linh.float3 { 0, 0, -1 }
    camera_yaw: f32 = 0
    camera_pitch: f32 = 0
    input: [4]bool

    main_loop: for {
        render_d3d12.new_frame(&renderer_state, pipeline)

        camera_rot_x := lin.matrix4_rotate(camera_pitch, lin.Vector3f32{1, 0, 0})
        camera_rot_y := lin.matrix4_rotate(camera_yaw, lin.Vector3f32{0, 1, 0})
        camera_rot := lin.mul(camera_rot_y, camera_rot_x)

        for e: sdl2.Event; sdl2.PollEvent(&e) != 0; {
            #partial switch e.type {
                case .QUIT:
                    break main_loop
                case .KEYUP: {
                    if e.key.keysym.sym == .W {
                        input[0] = false
                    }
                    if e.key.keysym.sym == .S {
                        input[1] = false
                    }
                    if e.key.keysym.sym == .A {
                        input[2] = false
                    }
                    if e.key.keysym.sym == .D {
                        input[3] = false
                    }
                }
                case .KEYDOWN:
                    if e.key.keysym.sym == .W {
                        input[0] = true
                    }
                    if e.key.keysym.sym == .S {
                        input[1] = true
                    }
                    if e.key.keysym.sym == .A {
                        input[2] = true
                    }
                    if e.key.keysym.sym == .D {
                        input[3] = true
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

        if input[0] {
            camera_pos += lin.mul(camera_rot, linh.float4{0,0,1,1}).xyz * 0.1
        }

        if input[1] {
            camera_pos -= lin.mul(camera_rot, linh.float4{0,0,1,1}).xyz * 0.1
        }

        if input[2] {
            camera_pos -= lin.mul(camera_rot, linh.float4{1,0,0,1}).xyz * 0.1
        }
            
        if input[3] {
            camera_pos += lin.mul(camera_rot, linh.float4{1,0,0,1}).xyz * 0.1
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
        render_d3d12.set_mvp(&renderer_state, pipeline, &mvp)

        render_d3d12.update(&renderer_state, pipeline)

        cmdlist: rc.CommandList
        defer delete(cmdlist)
        append(&cmdlist, rc.SetPipeline {
            handle = pipeline,
        })
        append(&cmdlist, rc.SetShader {
            handle = shader,
            pipeline = pipeline,
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
        append(&cmdlist, rc.ClearRenderTarget { render_target = { pipeline = pipeline, }, clear_color = {0, 0, 0, 1}, })
        append(&cmdlist, rc.SetRenderTarget { render_target = { pipeline = pipeline, }, })
        append(&cmdlist, rc.DrawCall {
            vertex_buffer = vertex_buffer,
            index_buffer = index_buffer,
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
