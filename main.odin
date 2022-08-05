package zg

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sys/windows"
import "core:os"
import "core:runtime"
import "vendor:sdl2"
import "vendor:directx/dxgi"
import "render_d3d12"
import rc "render_commands"
import "render_types"
import "core:math"
import "core:math/linalg/hlsl"
import lin "core:math/linalg"
import "shader_system"
import "base"

load_obj_model :: proc(filename: string) -> ([dynamic]f32, [dynamic]u32, [dynamic]f32, [dynamic]u32, [dynamic]f32, [dynamic]u32)  {
    f, err := os.open(filename)
    defer os.close(f)
    fs, _ := os.file_size(f)
    teapot_bytes := make([]byte, fs)
    defer delete(teapot_bytes)
    os.read(f, teapot_bytes)
    teapot := strings.string_from_ptr(&teapot_bytes[0], int(fs))
    out: [dynamic]f32
    normals_out: [dynamic]f32
    texcoords_out: [dynamic]f32
    indices_out: [dynamic]u32
    normal_indices_out: [dynamic]u32
    texcoord_indices_out: [dynamic]u32

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
        i := skip_whitespace(teapot, i_in)
        n0, n1, n2: f32
        i, n0 = parse_number(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n1 = parse_number(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n2 = parse_number(teapot, i)
        append(out, n0, n1, n2)
        return i
    }

    parse_texcoord :: proc(teapot: string, i_in: int, out: ^[dynamic]f32) -> int {
        i := skip_whitespace(teapot, i_in)
        n0, n1: f32
        i, n0 = parse_number(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n1 = parse_number(teapot, i)
        append(out, n0, n1)
        return i
    }

    parse_face_index :: proc(teapot: string, i_in: int) -> (int, u32, u32, u32) {
        num_slashes := 0

        {
            slashi := i_in
            for teapot[slashi] != ' ' && teapot[slashi] != '\n' {
                if teapot[slashi] == '/' {
                    num_slashes += 1
                }

                slashi += 1
            }
        }

        i := i_in
        start := i

        for teapot[i] != '/' {
            i += 1
        }

        ii, _ := strconv.parse_int(teapot[start:i])
        i += 1

        if num_slashes == 0 {
            return i, u32(ii - 1), 0, 0
        }

        start = i

        for teapot[i] != '/' && teapot[i] != ' ' && teapot[i] != '\n' && teapot[i] != '\t' {
            i += 1
        }

        ni, _ := strconv.parse_int(teapot[start:i])
        i += 1

        if num_slashes == 1 {
            return i, u32(ii - 1), u32(ni - 1), 0
        }

        start = i

        for teapot[i] != ' ' && teapot[i] != '\n' && teapot[i] != '\t' {
            i += 1
        }

        ti, _ := strconv.parse_int(teapot[start:i])
        return i, u32(ii - 1), u32(ni - 1), u32(ti - 1)
    }

    parse_face :: proc(teapot: string, i_in: int, out: ^[dynamic]u32, normal_indices_out: ^[dynamic]u32, texcoord_indices_out: ^[dynamic]u32) -> int {
        num_slashes := 0

        {
            slashi := i_in
            for teapot[slashi] != '\n' {
                if teapot[slashi] == '/' {
                    num_slashes += 1
                }

                slashi += 1
            }
        }

        i := skip_whitespace(teapot, i_in + 1)
        n0, n1, n2, in0, in1, in2, t0, t1, t2: u32
        i, n0, in0, t0 = parse_face_index(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n1, in1, t1 = parse_face_index(teapot, i)
        i = skip_whitespace(teapot, i)
        i, n2, in2, t2 = parse_face_index(teapot, i)
        append(out, n0, n1, n2)

        if num_slashes >= 3 {
            append(normal_indices_out, in0, in1, in2)
        }

        if num_slashes >= 6 {
            append(texcoord_indices_out, t0, t1, t2)
        }

        return i
    }

    for i := 0; i < len(teapot); i += 1 {
        switch teapot[i] {
            case '#': i = parse_comment(teapot, i)
            case 'v': if teapot[i + 1] == ' ' {
                i = parse_vertex(teapot, i + 1, &out)
            } else if teapot[i + 1] == 'n' {
                i = parse_vertex(teapot, i + 2, &normals_out)
            } else if teapot[i + 1] == 't' {
                i = parse_texcoord(teapot, i + 2, &texcoords_out)
            }
            case 'f': i = parse_face(teapot, i, &indices_out, &normal_indices_out, &texcoord_indices_out)
        }
    }

    return out, indices_out, normals_out, normal_indices_out, texcoords_out, texcoord_indices_out
}

Renderable :: struct {
    vertex_buffer: render_types.Handle,
    index_buffer: render_types.Handle,
    mvp_buffer: render_types.Handle,
    position: hlsl.float4,
    shader: render_types.Handle,
}

create_renderable :: proc(renderer_state: ^render_d3d12.State, rc_state: ^rc.State, filename: string, shader: render_types.Handle) -> (ren: Renderable) {
    vertices, indices, normals, normal_indices, texcoords, texcoord_indices := load_obj_model(filename)
    defer delete(vertices)
    defer delete(indices)
    defer delete(normals)
    defer delete(normal_indices)
    defer delete(texcoords)
    defer delete(texcoord_indices)

    vertex_data := make([]f32, len(vertices) * 3)
    defer delete(vertex_data)
    vdi := 0
    for v, i in vertices {
        vertex_data[vdi] = vertices[i]
        vdi += 1
        if (i + 1) % 3 == 0 && i != 0 {
            vdi += 5
        }
    }

    if len(normals) > 0 {
        for i in 0..<len(normal_indices) {
            n_idx := normal_indices[i] * 3
            v_idx := indices[i] * 8 + 3
            vertex_data[v_idx] = normals[n_idx]
            vertex_data[v_idx + 1] = normals[n_idx + 1]
            vertex_data[v_idx + 2] = normals[n_idx + 2]
        }
    }

    if len(texcoords) > 0 {
        for i in 0..<len(texcoord_indices) {
            n_idx := texcoord_indices[i] * 2
            v_idx := indices[i] * 8 + 6
            vertex_data[v_idx] = texcoords[n_idx]
            vertex_data[v_idx + 1] = texcoords[n_idx + 1]
        }
    }

    vertex_buffer_size := len(vertex_data) * size_of(vertex_data[0])
    index_buffer_size := len(indices) * size_of(indices[0])

    cmdlist: rc.CommandList
    defer delete(cmdlist)
    ren.vertex_buffer = rc.create_buffer(rc_state, &cmdlist, rc.VertexBufferDesc { stride = 32 }, rawptr(&vertex_data[0]), vertex_buffer_size, .Dynamic)
    ren.index_buffer = rc.create_buffer(rc_state, &cmdlist, rc.IndexBufferDesc { stride = 4 }, rawptr(&indices[0]), index_buffer_size, .Dynamic)
    render_d3d12.submit_command_list(renderer_state, &cmdlist)

    ren.mvp_buffer = rc.create_constant(rc_state)
    ren.shader = shader

    return ren
}

render_renderable :: proc(rc_state: ^rc.State, pipeline: render_types.Handle, cmdlist: ^rc.CommandList, view: hlsl.float4x4, ren: ^Renderable) {
    model: hlsl.float4x4 = 1
    model[3].xyz = ren.position.xyz

    mvp := lin.mul(hlsl.float4x4 {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, far/(far - near), (-far * near)/(far - near),
        0, 0, 1.0, 0,
    }, lin.mul(view, model))

    rc.upload_constant(rc_state, cmdlist, pipeline, ren.mvp_buffer, &mvp)

    append(cmdlist, rc.SetConstant {
        pipeline = pipeline,
        shader = ren.shader,
        name = base.hash("mvp"),
        constant = ren.mvp_buffer,
    })

    append(cmdlist, rc.DrawCall {
        vertex_buffer = ren.vertex_buffer,
        index_buffer = ren.index_buffer,
    })
}

near :: f32(0.01)
far :: f32(100)

run :: proc() {
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

    // Get the window handle from SDL
    window_info: sdl2.SysWMinfo
    sdl2.GetWindowWMInfo(window, &window_info)
    window_handle := dxgi.HWND(window_info.info.win.window)
    renderer_state := render_d3d12.create(wx, wy, window_handle)
    ri_state: rc.State
    fence: render_types.Handle
    pipeline: render_types.Handle
    shader: render_types.Handle

    {
        cmdlist: rc.CommandList
        defer delete(cmdlist)
        pipeline = rc.create_pipeline(&ri_state, &cmdlist, f32(wx), f32(wy), render_types.WindowHandle(uintptr(window_handle)))
        shader_def := shader_system.load_shader("shader.shader")
        shader = rc.create_shader(&ri_state, &cmdlist, shader_def)
        fence = rc.create_fence(&ri_state, &cmdlist)
        render_d3d12.submit_command_list(&renderer_state, &cmdlist)
    }

    ren := create_renderable(&renderer_state, &ri_state, "capsule.obj", shader)
    //ren2 := create_renderable(&renderer_state, &ri_state, "car.obj", shader)

    camera_pos := hlsl.float3 { 0, 0, -1 }
    camera_yaw: f32 = 0
    camera_pitch: f32 = 0
    input: [4]bool
    t :f32= 0

    color_const := rc.create_constant(&ri_state)
    sun_pos_const := rc.create_constant(&ri_state)

    main_loop: for {
        t += 0.16
        render_d3d12.new_frame(&renderer_state, pipeline)

        camera_rot_x := lin.matrix4_rotate(camera_pitch, lin.Vector3f32{1, 0, 0})
        camera_rot_y := lin.matrix4_rotate(camera_yaw, lin.Vector3f32{0, 1, 0})
        camera_rot := lin.mul(camera_rot_y, camera_rot_x)

        for e: sdl2.Event; sdl2.PollEvent(&e) != false; {
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

                case .MOUSEMOTION: {
                    camera_yaw += f32(e.motion.xrel) * 0.001
                    camera_pitch += f32(e.motion.yrel) * 0.001
                }
            }
        }

        if input[0] {
            camera_pos += lin.mul(camera_rot, hlsl.float4{0,0,1,1}).xyz * 0.1
        }

        if input[1] {
            camera_pos -= lin.mul(camera_rot, hlsl.float4{0,0,1,1}).xyz * 0.1
        }

        if input[2] {
            camera_pos -= lin.mul(camera_rot, hlsl.float4{1,0,0,1}).xyz * 0.1
        }
            
        if input[3] {
            camera_pos += lin.mul(camera_rot, hlsl.float4{1,0,0,1}).xyz * 0.1
        }

        camera_trans: hlsl.float4x4 = 1
        camera_trans[3].xyz = ([3]f32)(camera_pos)
        view: hlsl.float4x4 = hlsl.inverse(lin.mul(camera_trans, hlsl.float4x4(camera_rot)))

        color := hlsl.float4 {
            1, 0, 0, 1,
        }

        sun_pos := hlsl.float3 {
            math.cos(t)*50, 0, math.sin(t)*50,
        }
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

        rc.upload_constant(&ri_state, &cmdlist, pipeline, sun_pos_const, &sun_pos)

        append(&cmdlist, rc.SetConstant {
            pipeline = pipeline,
            shader = shader,
            name = base.hash("sun_pos"),
            constant = sun_pos_const,
        })

        rc.upload_constant(&ri_state, &cmdlist, pipeline, color_const, &color)

        append(&cmdlist, rc.SetConstant {
            pipeline = pipeline,
            shader = shader,
            name = base.hash("color"),
            constant = color_const,
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

        {
    //        ren.position.x = math.cos(t*0.1)*10
            render_renderable(&ri_state, pipeline, &cmdlist, view, &ren)
        }

        {
      /*      ren2.position.x = 3
            ren2.position.z = math.sin(t*0.1)*10
            render_renderable(&ri_state, pipeline, &cmdlist, view, &ren2)*/
        }

        append(&cmdlist, rc.ResourceTransition {
            before = .RenderTarget,
            after = .Present,    
        })
        append(&cmdlist, rc.Execute{ pipeline = pipeline, })
        append(&cmdlist, rc.Present{ handle = pipeline })
        append(&cmdlist, rc.WaitForFence { fence = fence, pipeline = pipeline, })
        render_d3d12.submit_command_list(&renderer_state, &cmdlist)
    }

    {
        cmdlist: rc.CommandList
        defer delete(cmdlist)
        rc.destroy_resource(&ri_state, &cmdlist, shader)
        rc.destroy_resource(&ri_state, &cmdlist, fence)
        rc.destroy_resource(&ri_state, &cmdlist, ren.vertex_buffer)
        rc.destroy_resource(&ri_state, &cmdlist, ren.index_buffer)
//        rc.destroy_resource(&ri_state, &cmdlist, ren2.vertex_buffer)
  //      rc.destroy_resource(&ri_state, &cmdlist, ren2.index_buffer)
        rc.destroy_resource(&ri_state, &cmdlist, color_const)
        rc.destroy_resource(&ri_state, &cmdlist, sun_pos_const)
        rc.destroy_resource(&ri_state, &cmdlist, ren.mvp_buffer)
    //    rc.destroy_resource(&ri_state, &cmdlist, ren2.mvp_buffer)
        rc.destroy_resource(&ri_state, &cmdlist, pipeline)
        render_d3d12.submit_command_list(&renderer_state, &cmdlist)
    }
    
    render_d3d12.destroy(&renderer_state)
    rc.destroy_state(&ri_state)
}

main :: proc() {
    tracking_allocator: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking_allocator, context.allocator)
    context.allocator = mem.tracking_allocator(&tracking_allocator)

    run()

    for key, value in tracking_allocator.allocation_map {
        fmt.printf("%v: Leaked %v bytes\n", value.location, value.size)
    }

    mem.tracking_allocator_destroy(&tracking_allocator)
}
