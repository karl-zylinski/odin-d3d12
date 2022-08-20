package ze

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:sys/windows"
import "core:runtime"
import "core:image/png"

import "vendor:sdl2"
import "vendor:directx/dxgi"

import rd3d12 "ze:render_d3d12"
import rc "ze:render_commands"
import rt "ze:render_types"
import ss "ze:shader_system"
import "ze:base"
import "ze:math"
import "ze:obj"

Renderable :: struct {
    vertex_buffer: rc.BufferHandle,
    index_buffer: rc.BufferHandle,
    position: math.float4,
    shader: rc.ShaderHandle,
}

create_renderable :: proc(renderer_state: ^rd3d12.State, rc_state: ^rc.State, filename: string, shader: rc.ShaderHandle) -> (ren: Renderable) {
    loaded_obj := obj.load(filename)
    defer obj.free(&loaded_obj)

    Vertex :: struct {
        position: math.float3,
        normal: math.float3,
        tangent: math.float3,
        bitangent: math.float3,
        uv: math.float2,
    }

    vertex_data := make([]Vertex, len(loaded_obj.vertices))
    defer delete(vertex_data)

    for vd, i in &vertex_data {
        vd.position = loaded_obj.vertices[i]
    }

    indices := make([]u32, len(loaded_obj.triangles) * 3)
    defer delete(indices)

    index_idx := 0
    for t in loaded_obj.triangles {
        for idx in t.indices {
            vertex_data[idx.vertex].normal = loaded_obj.normals[idx.normal]
            vertex_data[idx.vertex].uv = loaded_obj.uvs[idx.uv]
            indices[index_idx] = u32(idx.vertex)
            index_idx += 1
        }

        // tangent & bitangent calc, adapted from Eric Lengyel's C++ code
        {
            i0 := t.indices[0].vertex
            i1 := t.indices[1].vertex
            i2 := t.indices[2].vertex
            p0 := loaded_obj.vertices[i0]
            p1 := loaded_obj.vertices[i1]
            p2 := loaded_obj.vertices[i2]
            w0 := loaded_obj.uvs[t.indices[0].uv]
            w1 := loaded_obj.uvs[t.indices[1].uv]
            w2 := loaded_obj.uvs[t.indices[2].uv]
            e1, e2 := p1 - p0, p2 - p0
            x1, x2 := w1.x - w0.x, w2.x - w0.x
            y1, y2 := w1.y - w0.y, w2.y - w0.y
            r := 1.0 / (x1 * y2 - x2 * y1)
            t := (e1 * y2 - e2 * y1) * r
            b := (e2 * x1 - e1 * x2) * r
            vertex_data[i0].tangent += t
            vertex_data[i1].tangent += t
            vertex_data[i2].tangent += t
            vertex_data[i0].bitangent += b
            vertex_data[i1].bitangent += b
            vertex_data[i2].bitangent += b
        }
    }

    for v in &vertex_data {
        v.tangent = math.normalize(v.tangent)
        v.bitangent = math.normalize(v.bitangent)
    }

    vertex_buffer_size := len(vertex_data) * size_of(vertex_data[0])
    index_buffer_size := len(indices) * size_of(u32)

    cmdlist := rc.create_command_list(rc_state)
    rc.begin_resource_creation(&cmdlist)
    ren.vertex_buffer = rc.create_buffer(&cmdlist, vertex_buffer_size + (256 - vertex_buffer_size % 256), rawptr(&vertex_data[0]), vertex_buffer_size, 0)
    rc.resource_transition(&cmdlist, ren.vertex_buffer, .CopyDest, .ConstantBuffer)
    ren.index_buffer = rc.create_buffer(&cmdlist, index_buffer_size, rawptr(&indices[0]), index_buffer_size, 4)
    rc.resource_transition(&cmdlist, ren.index_buffer, .CopyDest, .IndexBuffer)
    rc.execute(&cmdlist)
    rd3d12.submit_command_list(renderer_state, &cmdlist)

    ren.shader = shader

    return ren
}

near :: f32(0.1)
far :: f32(10000)

calc_mvp :: proc(view: math.float4x4, ren: ^Renderable) -> math.float4x4 {
    model: math.float4x4 = 1
    model[3].xyz = ren.position.xyz

    return math.mul(math.float4x4 {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, far/(far - near), (-far * near)/(far - near),
        0, 0, 1.0, 0,
    }, math.mul(view, model))
}

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
    renderer_state := rd3d12.create(wx, wy, window_handle)
    rc_state: rc.State
    pipeline: rc.PipelineHandle
    shader: rc.ShaderHandle
    constants_buffer: rc.BufferHandle
    color_tex, normal_tex: rc.TextureHandle

    {
        cmdlist := rc.create_command_list(&rc_state)
        rc.begin_resource_creation(&cmdlist)
        pipeline = rc.create_pipeline(&cmdlist, f32(wx), f32(wy), rt.WindowHandle(uintptr(window_handle)))
        shader_def := ss.load_shader("shader.shader")
        shader = rc.create_shader(&cmdlist, shader_def)
        constants_buffer = rc.create_buffer(&cmdlist, 4096, nil, 0, 0)
        rc.resource_transition(&cmdlist, constants_buffer, .CopyDest, .ConstantBuffer)

        {
            ta := base.make_temp_arena()

            if tex, err := png.load("rock_color.png", {}, ta); err == nil {
                color_tex = rc.create_texture(&cmdlist, .R8G8B8A8_UNORM, tex.width, tex.height, &tex.pixels.buf[0])
            }

            if tex, err := png.load("rock_normal.png", {}, ta); err == nil {
                normal_tex = rc.create_texture(&cmdlist, .R8G8B8A8_UNORM, tex.width, tex.height, &tex.pixels.buf[0])
            }
        }

        rc.execute(&cmdlist)
        rd3d12.submit_command_list(&renderer_state, &cmdlist)
    }

    ren := create_renderable(&renderer_state, &rc_state, "rock.obj", shader)

    camera_pos := math.float3 { 0, 0, -2 }
    camera_yaw: f32 = 0
    camera_pitch: f32 = 0
    input: [6]bool
    t :f32= 0

    main_loop: for {
        t += 0.016
        camera_rot_x := math.matrix4_rotate(camera_pitch, math.float3{1, 0, 0})
        camera_rot_y := math.matrix4_rotate(camera_yaw, math.float3{0, 1, 0})
        camera_rot := math.mul(camera_rot_y, camera_rot_x)

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
                    if e.key.keysym.sym == .Q {
                        input[4] = false
                    }
                    if e.key.keysym.sym == .E {
                        input[5] = false
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
                    if e.key.keysym.sym == .Q {
                        input[4] = true
                    }
                    if e.key.keysym.sym == .E {
                        input[5] = true
                    }

                case .MOUSEMOTION: {
                    camera_yaw += f32(e.motion.xrel) * 0.001
                    camera_pitch += f32(e.motion.yrel) * 0.001
                }
            }
        }

        if input[0] {
            camera_pos += math.mul(camera_rot, math.float4{0,0,1,1}).xyz
        }

        if input[1] {
            camera_pos -= math.mul(camera_rot, math.float4{0,0,1,1}).xyz
        }

        if input[2] {
            camera_pos -= math.mul(camera_rot, math.float4{1,0,0,1}).xyz
        }

        if input[3] {
            camera_pos += math.mul(camera_rot, math.float4{1,0,0,1}).xyz
        }

        if input[4] {
            camera_pos -= math.mul(camera_rot, math.float4{0,1,0,1}).xyz
        }

        if input[5] {
            camera_pos += math.mul(camera_rot, math.float4{0,1,0,1}).xyz
        }

        camera_trans: math.float4x4 = 1
        camera_trans[3].xyz = ([3]f32)(camera_pos)
        view: math.float4x4 = math.inverse(math.mul(camera_trans, math.float4x4(camera_rot)))

        color := math.float4 {
            1, 1, 1, 1,
        }

        sun_pos := math.float3 {
            math.cos(f32(t))*500, 0, math.sin(f32(t))*500,
        }
        rd3d12.update(&renderer_state)

        cmdlist := rc.create_command_list(&rc_state)

        rc.begin_pass(&cmdlist, pipeline)
        rc.set_shader(&cmdlist, shader)
        rc.set_texture(&cmdlist, base.hash("color"), color_tex)
        rc.set_texture(&cmdlist, base.hash("normal"), normal_tex)

        constants := rc.BufferWithNamedOffsets {
            data = make([dynamic]u8, context.temp_allocator),
            offsets = make([dynamic]rc.NamedOffset, context.temp_allocator),
        }

        rc.buffer_append(&constants, &sun_pos, base.hash("sun_pos"))
        rc.buffer_append(&constants, &color, base.hash("tint"))

        rc.set_scissor(&cmdlist, { w = f32(wx), h = f32(wy), })
        rc.set_viewport(&cmdlist, { w = f32(wx), h = f32(wy), })

        rc.resource_transition(&cmdlist, pipeline, .Present, .RenderTarget)
        rc.clear_render_target(&cmdlist, pipeline, {0, 0, 0, 1})
        rc.set_render_target(&cmdlist, pipeline)

        mvp := calc_mvp(view, &ren)
        rc.buffer_append(&constants, &mvp, base.hash("mvp"))
        rc.resource_transition(&cmdlist, constants_buffer, .ConstantBuffer, .CopyDest)
        rc.update_buffer(&cmdlist, constants_buffer, rawptr(&constants.data[0]), len(constants.data))
        rc.resource_transition(&cmdlist, constants_buffer, .CopyDest, .ConstantBuffer)
        rc.set_constant_buffer(&cmdlist, constants_buffer)

        for n in constants.offsets {
            rc.set_constant(&cmdlist, n.name, n.offset)
        }

        rc.draw_call(&cmdlist, ren.vertex_buffer, ren.index_buffer)
        rc.resource_transition(&cmdlist, pipeline, .RenderTarget, .Present)
        rc.execute(&cmdlist)
        rc.present(&cmdlist)
        rd3d12.submit_command_list(&renderer_state, &cmdlist)
    }

    {
        cmdlist := rc.create_command_list(&rc_state)
        rc.destroy_resource(&cmdlist, shader)
        rc.destroy_resource(&cmdlist, ren.vertex_buffer)
        rc.destroy_resource(&cmdlist, ren.index_buffer)
        rc.destroy_resource(&cmdlist, pipeline)
        rc.destroy_resource(&cmdlist, color_tex)
        rc.destroy_resource(&cmdlist, normal_tex)
        rc.destroy_resource(&cmdlist, constants_buffer)
        rd3d12.submit_command_list(&renderer_state, &cmdlist)
    }
    
    rd3d12.destroy(&renderer_state)
    rc.destroy_state(&rc_state)
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
