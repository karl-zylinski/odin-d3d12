package zmath
import l "core:math/linalg"
import m "core:math"
import h "core:math/linalg/hlsl"

// Types

float3 :: h.float3
float4 :: h.float4
float4x4 :: h.float4x4

Rect :: struct {
    x, y, w, h: f32,
}

// Procs

mul :: l.mul
matrix4_rotate :: proc(angle_radians: $AT, v: $VT) -> float4x4 {
    return float4x4(l.matrix4_rotate(angle_radians, l.Vector3f32(v)))
}
inverse :: h.inverse
cos :: m.cos
sin :: m.sin
fract :: l.fract
