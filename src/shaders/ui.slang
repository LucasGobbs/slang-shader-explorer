// UI overlay shader: textured/colored quads in pixel space, y-down.
// Used by the microui renderer (src/ui.odin). Texture + sampler follow the
// separate-binding pattern SDL GPU expects.

struct UiUniforms {
    float2 iResolution;
    float2 _pad;
}

[[vk::binding(0, 0)]]
ConstantBuffer<UiUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D atlas_tex;

[[vk::binding(2, 0)]]
SamplerState atlas_sampler;

struct VertexInput {
    [[vk::location(0)]] float2 position : POSITION;
    [[vk::location(1)]] float2 uv : TEXCOORD0;
    [[vk::location(2)]] float4 color : COLOR0;
}

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertMain(VertexInput input) {
    VertexOutput output;
    // Pixel coords (y-down) to clip space.
    float2 clip = (input.position / Uniforms.iResolution) * 2.0 - 1.0;
    output.position = float4(clip.x, -clip.y, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float a = atlas_tex.Sample(atlas_sampler, input.uv).r;
    return float4(input.color.rgb, input.color.a * a);
}
