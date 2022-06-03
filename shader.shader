ByteAddressBuffer constant_buffer : register(t0, space1);

struct PushConstants {
    float4x4 mvp2;
};

ConstantBuffer<PushConstants> push_constants : register(b1, space0);

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
    result.position = mul(push_constants.mvp2, position);
    result.world_pos = position.xyz;
    result.normal = normal;
    return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
    float3 sun_dir = normalize(sun_pos - input.world_pos);

    float4 cc = asfloat(constant_buffer.Load4(0));



    return clamp(float4(0.9,0.9,0.65,1) * saturate(dot(sun_dir, normalize(input.normal))), float4(0.2, 0.2, 0.23, 1), float4(1,1,1,1)) * cc;
};