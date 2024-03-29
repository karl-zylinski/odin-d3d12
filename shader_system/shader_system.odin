package shader_system

import "core:os"
import "core:strings"
import "core:fmt"

ShaderType :: enum {
    None,
    Float4x4,
    Float4,
    Float3,
    Float2,
    Float,
}

ConstantBuffer :: struct {
    type: ShaderType,
    name: string,
}

Texture2D :: struct {
    name: string,
}

VertexInput :: struct {
    name: string,
    type: ShaderType,
}

Shader :: struct {
    code: rawptr,
    code_size: int,
    constant_buffers: []ConstantBuffer,
    textures_2d: []Texture2D,
    vertex_inputs: []VertexInput,
}

load_shader :: proc(path: string) -> Shader {
    f, err := os.open(path)
    defer os.close(f)
    fs, _ := os.file_size(f)
    shader_code := make([]byte, fs, context.temp_allocator)
    os.read(f, shader_code)

    first_on_line :: proc(code: string, i: int) -> bool {
        return i == 0 || code[i - 1] == '\n'
    }

    string_at :: proc(code: string, i: int, cmp: string) -> bool {
        return strings.equal_fold(code[i:min(len(code), i + len(cmp))], cmp)
    }

    skip_whitespace :: proc(code: string, i_in: int) -> int {
        i := i_in

        for i < len(code) {
            if code[i] != ' ' && code[i] != '\t' && code[i] != '\n' && i < len(code) {
                return i
            }
            i += 1
        }

        return i
    }

    CBufferMarker :: "#cbuffer"
    Texture2DMarker :: "#texture2d"
    VertexInputMarker :: "#vertexinput"

    count_occurance :: proc(code: string, str: string, beginning_of_line: bool) -> int {
        n: int
        for c, i in code {
            if !beginning_of_line || first_on_line(code, i) {
                if string_at(code, i, str) {
                    n += 1
                }
            }
        }
        return n
    }

    get_word :: proc(code: string, i_in: int) -> (string, int) {
        i := i_in
        start := i

        for code[i] != ' ' && code[i] != '\r' && code[i] != '\n' && code[i] != '\t' && i < len(code) {
            i += 1
        }

        return code[start:i], i
    }

    parse_shader_type :: proc(type: string) -> ShaderType {
        if strings.equal_fold(type, "Float4x4") {
            return .Float4x4
        } else if strings.equal_fold(type, "Float4") {
            return .Float4
        } else if strings.equal_fold(type, "Float3") {
            return .Float3
        } else if strings.equal_fold(type, "Float2") {
            return .Float2
        } else if strings.equal_fold(type, "Float") {
            return .Float
        }

        fmt.printf("Error: Unknown type %v\n", type)

        return .None
    }

    parse_cbuffer :: proc(code: string, i_in: int) -> (ConstantBuffer, int) {
        i := i_in
        cb: ConstantBuffer

        if !string_at(code, i, CBufferMarker) {
            return cb, i
        }

        i += len(CBufferMarker)
        i = skip_whitespace(code, i)

        name: string
        name, i = get_word(code, i)
        cb.name = strings.clone(name)
        i = skip_whitespace(code, i)
        type_str: string
        type_str, i = get_word(code, i)
        cb.type = parse_shader_type(type_str)
        i = skip_whitespace(code, i)

        if !first_on_line(code, i) {
            prop: string
            prop, i = get_word(code, i)
        }

        return cb, i
    }

    parse_vertex_input :: proc(code: string, i_in: int) -> (VertexInput, int) {
        i := i_in
        vi: VertexInput

        if !string_at(code, i, VertexInputMarker) {
            return vi, i
        }

        i += len(VertexInputMarker)
        i = skip_whitespace(code, i)

        name: string
        name, i = get_word(code, i)
        vi.name = strings.clone(name)
        i = skip_whitespace(code, i)
        type_str: string
        type_str, i = get_word(code, i)
        vi.type = parse_shader_type(type_str)
        i = skip_whitespace(code, i)

        if !first_on_line(code, i) {
            prop: string
            prop, i = get_word(code, i)
        }

        return vi, i
    }

    get_line :: proc(code: string, i_in: int) -> (string, int) {
        i := i_in
        start := i

        for i < len(code) && code[i] != '\n'{
            i += 1
        }

        return code[start:i], i
    }

    hlsl_type :: proc(type: ShaderType) -> string {
        switch type {
            case .None: return ""
            case .Float4x4: return "float4x4"
            case .Float4: return "float4"
            case .Float3: return "float3"
            case .Float2: return "float2"
            case .Float: return "float"
        }

        return ""
    }

    parse_texture2d :: proc(code: string, i_in: int) -> (Texture2D, int) {
        i := i_in
        t: Texture2D

        if !string_at(code, i, Texture2DMarker) {
            return t, i
        }

        i += len(Texture2DMarker)
        i = skip_whitespace(code, i)

        name: string
        name, i = get_word(code, i)
        t.name = strings.clone(name)
        i = skip_whitespace(code, i)

        return t, i
    }

    parse_cbuffers :: proc(code: string, shader: ^Shader) {
        cbuf_idx := 0
        tex2d_idx := 0
        vi_idx := 0
        code_builder := strings.builder_make(allocator = context.temp_allocator)
        for i := 0; i < len(code); i += 1 {
            if first_on_line(code, i) {
                if string_at(code, i, CBufferMarker) {
                    shader.constant_buffers[cbuf_idx], i = parse_cbuffer(code, i)
                    cbuf_idx += 1
                } else if string_at(code, i, Texture2DMarker) {
                    shader.textures_2d[tex2d_idx], i = parse_texture2d(code, i)
                    tex2d_idx += 1
                } else if string_at(code, i, VertexInputMarker) {
                    shader.vertex_inputs[vi_idx], i = parse_vertex_input(code, i)
                    vi_idx += 1
                } else {
                    line: string
                    line, i = get_line(code, i)
                    strings.write_string(&code_builder, line)
                    strings.write_string(&code_builder, "\n")
                }
            }
        }
        generated := strings.builder_make(allocator = context.temp_allocator)

        if len(shader.vertex_inputs) > 0 {
            strings.write_string(&generated, "ByteAddressBuffer vertex_inputs : register(t0, space2);\n\n")

            strings.write_string(&generated, "struct VertexInput {\n")

            for vi in shader.vertex_inputs {
                type_str := hlsl_type(vi.type)
                strings.write_string(&generated, fmt.tprintf("\t%v %v;\n", type_str, vi.name))
            }

            strings.write_string(&generated, "};\n\n")
        }

        if len(shader.constant_buffers) > 0 {
            strings.write_string(&generated, "ByteAddressBuffer constant_buffer : register(t0, space0);\n\n")

            strings.write_string(&generated, "struct IndexConstants {\n")

            for cb in shader.constant_buffers {
                strings.write_string(&generated, "\tuint ")
                strings.write_string(&generated, cb.name)
                strings.write_string(&generated, "_index;\n")
            }

            strings.write_string(&generated, "};\n\n")
            strings.write_string(&generated, "ConstantBuffer<IndexConstants> index_constants : register(b0, space0);\n\n");

            for cb in shader.constant_buffers {
                type_str := hlsl_type(cb.type)
                strings.write_string(&generated, fmt.tprintf("%v get_%v() {{\n", type_str, cb.name))
                index_name := fmt.tprintf("index_constants.%v_index", cb.name)

                switch cb.type {
                    case .None: break
                    case .Float: {
                        strings.write_string(&generated, fmt.tprintf("\treturn asfloat(constant_buffer.Load(%v));\n", index_name))
                    }
                    case .Float2: {
                        strings.write_string(&generated, fmt.tprintf("\treturn asfloat(constant_buffer.Load2(%v));\n", index_name))
                    }
                    case .Float3: {
                        strings.write_string(&generated, fmt.tprintf("\treturn asfloat(constant_buffer.Load3(%v));\n", index_name))
                    }
                    case .Float4: {
                        strings.write_string(&generated, fmt.tprintf("\treturn asfloat(constant_buffer.Load4(%v));\n", index_name))
                    }
                    case .Float4x4: {
                        strings.write_string(&generated, fmt.tprintf("\tfloat4 x = asfloat(constant_buffer.Load4(%v));\n", index_name))
                        strings.write_string(&generated, fmt.tprintf("\tfloat4 y = asfloat(constant_buffer.Load4(%v + 16));\n", index_name))
                        strings.write_string(&generated, fmt.tprintf("\tfloat4 z = asfloat(constant_buffer.Load4(%v + 32));\n", index_name))
                        strings.write_string(&generated, fmt.tprintf("\tfloat4 w = asfloat(constant_buffer.Load4(%v + 48));\n", index_name))
                        strings.write_string(&generated, "\treturn transpose(float4x4(x, y, z, w));\n")
                    }
                }

                strings.write_string(&generated, "}\n\n")
            }

        }

        if len(shader.textures_2d) > 0 {
            strings.write_string(&generated, "Texture2D bindless_textures[] : register(t0, space1);\n\n")

            strings.write_string(&generated, "struct IndexTextures {\n")

            for t in shader.textures_2d {
                strings.write_string(&generated, "\tuint ")
                strings.write_string(&generated, t.name)
                strings.write_string(&generated, "_index;\n")
            }

            strings.write_string(&generated, "};\n\n")
            strings.write_string(&generated, "ConstantBuffer<IndexTextures> index_textures : register(b0, space1);\n\n");

            for t, idx in shader.textures_2d {
                strings.write_string(&generated, fmt.tprintf("Texture2D get_%v() {{\n", t.name))
                index_name := fmt.tprintf("index_textures.%v_index", t.name)
                strings.write_string(&generated, fmt.tprintf("\treturn bindless_textures[%v];\n", idx))
                strings.write_string(&generated, "}\n\n")
            }
        }

        combined_code := strings.concatenate({strings.to_string(generated), strings.to_string(code_builder)})
        shader.code = strings.ptr_from_string(combined_code)

        fmt.println(combined_code)
        shader.code_size = len(combined_code)
    }

    parse_shader :: proc(code: string) -> Shader {
        s: Shader = {
            constant_buffers = make([]ConstantBuffer, count_occurance(code, CBufferMarker, true)),
            textures_2d = make([]Texture2D, count_occurance(code, Texture2DMarker, true)),
            vertex_inputs = make([]VertexInput, count_occurance(code, VertexInputMarker, true)),
        }

        parse_cbuffers(code, &s)
        return s
    }

    return parse_shader(strings.string_from_ptr(&shader_code[0], int(fs)))
}

free_shader :: proc(s: ^Shader) {
    for cb in s.constant_buffers {
        delete(cb.name)
    }

    for vi in s.vertex_inputs {
        delete(vi.name)
    }

    for t in s.textures_2d {
        delete(t.name)
    }

    delete(s.constant_buffers)
    delete(s.textures_2d)
    delete(s.vertex_inputs)
    free(s.code)
}