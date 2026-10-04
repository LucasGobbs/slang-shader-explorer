// Vignette grade chained after the 3D render: samples the previous pass's
// frame (input_tex) and darkens the frame edges toward a tint, with a
// whisper of dithered grain so the falloff doesn't band.

import "../../common";

public struct VignetteParams {
    [UiSlider(0.0, 2.0, 0.01, 0.85)]
    public float strength;
    [UiSlider(0.1, 1.4, 0.01, 0.65)]
    public float radius;
    [UiColor(0.02, 0.01, 0.04)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[[vk::binding(3, 0)]]
ConstantBuffer<VignetteParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    float4 col = input_tex.Sample(input_sampler, uv);

    float2 p = (input.gl_FragCoord - 0.5 * Uniforms.iResolution.xy) / Uniforms.iResolution.y;
    float d = length(p);
    float vig = smoothstep(Params.radius, Params.radius + 0.45, d);
    col.rgb = lerp(col.rgb, Params.tint, saturate(vig * Params.strength));

    uint2 id = uint2(input.gl_FragCoord);
    col.rgb += (bayer4(id) - 0.5) * (1.5 / 255.0);
    return float4(col.rgb, 1.0);
}
