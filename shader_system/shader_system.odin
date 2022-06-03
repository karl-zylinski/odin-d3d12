package shader_system

import "core:os"
import "core:strings"
import "core:fmt"

ConstantBufferType :: enum {
    None,
    Float4x4,
    Float4,
    Float3,
}

ConstantBuffer :: struct {
    type: ConstantBufferType,
    name: string,
    updatable: bool,
}

Shader :: struct {
    code: rawptr,
    code_size: int,
    constant_buffers: []ConstantBuffer,
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

    count_cbuffers :: proc(code: string) -> int {
        n: int
        for c, i in code {
            if first_on_line(code, i) {
                if string_at(code, i, CBufferMarker) {
                    n += 1
                }
            }
        }
        return n
    }

    get_word :: proc(code: string, i_in: int) -> (string, int) {
        i := i_in
        start := i

        for code[i] != ' ' && code[i] != '\n' && code[i] != '\t' && i < len(code) {
            i += 1
        }

        return code[start:i], i
    }

    parse_cbuffer_type :: proc(type: string) -> ConstantBufferType {
        if strings.equal_fold(type, "Float4x4") {
            return .Float4x4
        } else if strings.equal_fold(type, "Float4") {
            return .Float4
        } else if strings.equal_fold(type, "Float3") {
            return .Float3
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
        cb.type = parse_cbuffer_type(type_str)
        i = skip_whitespace(code, i)

        if !first_on_line(code, i) {
            prop: string
            prop, i = get_word(code, i)

            if strings.equal_fold(prop, "dynamic") {
                cb.updatable = true
            }
        }

        return cb, i
    }

    get_line :: proc(code: string, i_in: int) -> (string, int) {
        i := i_in
        start := i

        for i < len(code) && code[i] != '\n'{
            i += 1
        }

        return code[start:i], i
    }

    hlsl_type :: proc(type: ConstantBufferType) -> string {
        switch type {
            case .None: return ""
            case .Float4x4: return "float4x4"
            case .Float4: return "float4"
            case .Float3: return "float3"
        }

        return ""
    }

    parse_cbuffers :: proc(code: string, shader: ^Shader) {
        cbuf_idx := 0
        code_builder := strings.make_builder(allocator = context.temp_allocator)
        for i := 0; i < len(code); i += 1 {
            if first_on_line(code, i) {
                if string_at(code, i, CBufferMarker) {
                    shader.constant_buffers[cbuf_idx], i = parse_cbuffer(code, i)
                    cbuf_idx += 1
                } else {
                    line: string
                    line, i = get_line(code, i)
                    strings.write_string(&code_builder, line)
                    strings.write_string(&code_builder, "\n")
                }
            }
        }
        generated := strings.make_builder(allocator = context.temp_allocator)
        
        if len(shader.constant_buffers) > 0 {
            strings.write_string(&generated, "ByteAddressBuffer constant_buffer : register(t0, space1);\n\n")

            strings.write_string(&generated, "struct IndexConstants {\n")
            
            for cb in shader.constant_buffers {
                strings.write_string(&generated, "\tuint ")
                strings.write_string(&generated, cb.name)
                strings.write_string(&generated, "_index;\n")
            }

            strings.write_string(&generated, "};\n\n")
            strings.write_string(&generated, "ConstantBuffer<IndexConstants> index_constants : register(b1, space0);\n\n");

            for cb in shader.constant_buffers {
                type_str := hlsl_type(cb.type)
                strings.write_string(&generated, fmt.tprintf("%v get_%v() {{\n", type_str, cb.name))
                index_name := fmt.tprintf("index_constants.%v_index", cb.name)

                switch cb.type {
                    case .None: break
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

        combined_code := strings.concatenate({strings.to_string(generated), strings.to_string(code_builder)})
        shader.code = strings.ptr_from_string(combined_code)

        fmt.println(combined_code)
        shader.code_size = len(combined_code)
    }

    parse_shader :: proc(code: string) -> Shader {
        num_cbuffers := count_cbuffers(code)

        s: Shader = {
            constant_buffers = make([]ConstantBuffer, num_cbuffers),
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

    delete(s.constant_buffers)
    free(s.code)
}