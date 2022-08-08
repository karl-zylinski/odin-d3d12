#cbuffer color float4 dynamic
#cbuffer sun_pos float3 dynamic
#cbuffer mvp float4x4 dynamic

#texture2d albedo

SamplerState tex_sampler;

struct PSInput {
    float4 position : SV_POSITION;
    float3 world_pos : POSITION0;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
};

PSInput VSMain(float4 position : POSITION0, float3 normal : NORMAL0, float2 uv : TEXCOORD0) {
    PSInput result;
    result.position = mul(get_mvp(), position);
    result.world_pos = position.xyz;
    result.normal = normal;
    result.uv = uv;
    return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
    Texture2D a = get_albedo();
    float4 sc = a.Sample(tex_sampler, input.uv);
    float3 sun_dir = normalize(get_sun_pos() - input.world_pos);
    return clamp(float4(0.9,0.9,0.65,1) * saturate(dot(sun_dir, normalize(input.normal))), float4(0.2, 0.2, 0.23, 1), float4(1,1,1,1)) * sc;
};