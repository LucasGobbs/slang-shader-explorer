// TRAIL 07 — Textures
// Real images join the shader as Texture2D + SamplerState. The paper
// texture here is picked in the inspector — the sampler handles lookup
// and filtering. We ink an SDF circle onto real paper grain.
//
// Concepts: texture sampling, samplers, compositing procedural with image.
//
// Try:
//   1. Change the ink color in the inspector (the InkParams struct
//      declared it — no UI code was written anywhere).
//   2. Multiply uv by 2 before sampling: the paper tiles.
//   3. Use the paper's brightness to jitter the circle's edge (add
//      0.02 * paper.r to d) for a hand-drawn look.
import "../../common";

public struct InkParams {
    [UiColor(0.12, 0.12, 0.15)]
    public float3 ink;

    [UiSlider(0.05, 0.45, 0.005, 0.25)]
    public float radius;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<InkParams> Params;

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
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float3 paper = paper_tex.Sample(paper_sampler, uv).rgb;
    float d = length(uv - 0.5) - Params.radius;
    float fill = 1.0 - smoothstep(-0.01, 0.01, d);
    return float4(lerp(paper, Params.ink, fill), 1.0);
}
