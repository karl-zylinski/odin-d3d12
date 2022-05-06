cbuffer matrices : register(b0) {
    float4x4 mvp;
};

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
    float3 sun_pos = normalize(float3(-50, 150, 250) - input.world_pos);
    return clamp(float4(0.9,0.9,0.65,1) * dot(sun_pos, normalize(input.normal)), float4(0.2, 0.2, 0.23, 1), float4(1,1,1,1));
};