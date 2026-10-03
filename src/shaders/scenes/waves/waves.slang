
import "../../common";

public struct WavesParams {
    [UiSlider(1, 40, 0.5, 13)]
    public float frequency;

    [UiSlider(0.1, 5, 0.05, 1)]
    public float speed;

    [UiToggle(1)]
    public float useColor;

    [UiToggle(1)]
    public float teste;

    [UiColor(0.12, 0.25, 0.75)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<WavesParams> Params;

[[vk::binding(2, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(3, 0)]]
SamplerState paper_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 fragCoord = input.uv * Uniforms.iResolution.xy;
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);

    float w = sin(p.x * Params.frequency + Uniforms.iTime * Params.speed)
            * sin(p.y * Params.frequency * 0.8 - Uniforms.iTime * Params.speed);
    float v = smoothstep(-0.2, 0.2, w);

    float3 paper = paper_tex.SampleLevel(paper_sampler, input.uv, 0).rgb;
    float3 ink = Params.useColor > 0.5 ? Params.tint : float3(0.08);
    float3 col = lerp(paper, ink, v);
    return float4(orderedDither(col, 5.0, uint2(fragCoord)), 1.0);
}
