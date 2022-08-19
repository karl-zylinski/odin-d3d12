#cbuffer tint float4
#cbuffer sun_pos float3
#cbuffer mvp float4x4

#texture2d color
#texture2d normal

SamplerState tex_sampler;

#vertexinput position float3
#vertexinput normal float3
#vertexinput uv float2

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 world_pos : POSITION0;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
};

VertexOutput vertex_shader(uint vertex_id : SV_VertexID) {
    VertexOutput result;

    VertexInput v = vertex_inputs.Load<VertexInput>(vertex_id * sizeof(VertexInput));

    result.position = mul(get_mvp(), float4(v.position, 1));
    result.world_pos = v.position.xyz;
    result.normal = v.normal;
    result.uv = v.uv;
    
    return result;
}

float4 pixel_shader(VertexOutput input) : SV_TARGET {
    float4 sc = get_color().Sample(tex_sampler, input.uv);
    float3 sun_dir = normalize(get_sun_pos() - input.world_pos);
    float3 n = get_normal().Sample(tex_sampler, input.uv).rgb;
    return clamp(float4(0.9,0.9,0.65,1) * saturate(dot(sun_dir, normalize(n * 2 - 1))), float4(0.2, 0.2, 0.23, 1), float4(1,1,1,1)) * sc * get_tint();
};