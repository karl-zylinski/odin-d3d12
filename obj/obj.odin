package obj

import "core:os"
import "core:strings"
import "core:strconv"

import "ze:math"

load :: proc(filename: string) -> ([dynamic]math.float3, [dynamic]u32, [dynamic]math.float3, [dynamic]u32, [dynamic]math.float2, [dynamic]u32)  {
    f, err := os.open(filename)
    defer os.close(f)
    fs, _ := os.file_size(f)
    source_bytes := make([]byte, fs)
    defer delete(source_bytes)
    os.read(f, source_bytes)
    source := strings.string_from_ptr(&source_bytes[0], int(fs))
    out: [dynamic]math.float3
    normals_out: [dynamic]math.float3
    texcoords_out: [dynamic]math.float2
    indices_out: [dynamic]u32
    normal_indices_out: [dynamic]u32
    texcoord_indices_out: [dynamic]u32

    parse_comment :: proc(source: string, i_in: int) -> int {
        i := i_in
        for source[i] != '\n' {
            i += 1
        }

        i += 1
        return i
    }

    skip_whitespace :: proc(source: string, i_in: int) -> int {
        i := i_in

        for i < len(source) {
            if source[i] != ' ' && source[i] != '\t' && source[i] != '\n' {
                return i
            }
            i += 1
        }

        return i
    }

    parse_number :: proc(source: string, i_in: int) -> (int, f32) {
        i := i_in
        start := i

        for source[i] != ' ' && source[i] != '\n' && source[i] != '\t' {
            i += 1
        }

        num, ok := strconv.parse_f32(source[start:i])
        return i, num
    }

    parse_vertex :: proc(source: string, i_in: int, out: ^[dynamic]math.float3) -> int {
        i := skip_whitespace(source, i_in)
        n0, n1, n2: f32
        i, n0 = parse_number(source, i)
        i = skip_whitespace(source, i)
        i, n1 = parse_number(source, i)
        i = skip_whitespace(source, i)
        i, n2 = parse_number(source, i)
        append(out, math.float3 { n0, n1, n2 })
        return i
    }

    parse_texcoord :: proc(source: string, i_in: int, out: ^[dynamic]math.float2) -> int {
        i := skip_whitespace(source, i_in)
        n0, n1: f32
        i, n0 = parse_number(source, i)
        i = skip_whitespace(source, i)
        i, n1 = parse_number(source, i)

        // There may be a third coordiante, that we skip for now
        for source[i] != '\n' && source[i] != '\r' {
            i += 1
        }

        append(out, math.float2 { n0, n1 })
        return i
    }

    parse_face_index :: proc(source: string, i_in: int) -> (int, u32, u32, u32) {
        num_slashes := 0

        {
            slashi := i_in
            for source[slashi] != ' ' && source[slashi] != '\n' {
                if source[slashi] == '/' {
                    num_slashes += 1
                }

                slashi += 1
            }
        }

        i := i_in
        start := i

        for source[i] != '/' {
            i += 1
        }

        ii, _ := strconv.parse_int(source[start:i])
        i += 1

        if num_slashes == 0 {
            return i, u32(ii - 1), 0, 0
        }

        start = i

        for source[i] != '/' && source[i] != ' ' && source[i] != '\n' && source[i] != '\t' {
            i += 1
        }

        ti, _ := strconv.parse_int(source[start:i])
        i += 1

        if num_slashes == 1 {
            return i, u32(ii - 1), u32(ti - 1), 0
        }

        start = i

        for source[i] != ' ' && source[i] != '\n' && source[i] != '\t' {
            i += 1
        }

        ni, _ := strconv.parse_int(source[start:i])
        return i, u32(ii - 1), u32(ti - 1), u32(ni - 1)
    }

    parse_face :: proc(source: string, i_in: int, out: ^[dynamic]u32, normal_indices_out: ^[dynamic]u32, texcoord_indices_out: ^[dynamic]u32) -> int {
        num_slashes := 0

        {
            slashi := i_in
            for source[slashi] != '\n' {
                if source[slashi] == '/' {
                    num_slashes += 1
                }

                slashi += 1
            }
        }

        i := skip_whitespace(source, i_in + 1)
        n0, n1, n2, in0, in1, in2, t0, t1, t2: u32
        i, n0, t0, in0 = parse_face_index(source, i)
        i = skip_whitespace(source, i)
        i, n1, t1, in1 = parse_face_index(source, i)
        i = skip_whitespace(source, i)
        i, n2, t2, in2 = parse_face_index(source, i)
        append(out, n0, n1, n2)

        if num_slashes >= 3 {
            append(normal_indices_out, in0, in1, in2)
        }

        if num_slashes >= 6 {
            append(texcoord_indices_out, t0, t1, t2)
        }

        return i
    }

    for i := 0; i < len(source); i += 1 {
        switch source[i] {
            case '#': i = parse_comment(source, i)
            case 'v': if source[i + 1] == ' ' {
                i = parse_vertex(source, i + 1, &out)
            } else if source[i + 1] == 'n' {
                i = parse_vertex(source, i + 2, &normals_out)
            } else if source[i + 1] == 't' {
                i = parse_texcoord(source, i + 2, &texcoords_out)
            }
            case 'f': i = parse_face(source, i, &indices_out, &normal_indices_out, &texcoord_indices_out)
        }
    }

    return out, indices_out, normals_out, normal_indices_out, texcoords_out, texcoord_indices_out
}