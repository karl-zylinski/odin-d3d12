#cbuffer color float4 dynamic
#cbuffer sun_pos float3 dynamic
#cbuffer mvp float4x4 dynamic

struct PSInput {
    float4 position : SV_POSITION;
    float3 world_pos : POSITION0;
    float3 normal : NORMAL;
};

PSInput VSMain(float4 position : POSITION0, float3 normal : NORMAL0) {
    PSInput result;
    result.position = mul(mvp, position);
    result.world_pos = position.xyz;
    result.normal = normal;
    return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
    float3 sun_dir = normalize(sun_pos - input.world_pos);
    return clamp(float4(0.9,0.9,0.65,1) * saturate(dot(sun_dir, normalize(input.normal))), float4(0.2, 0.2, 0.23, 1), float4(1,1,1,1)) * color;
};