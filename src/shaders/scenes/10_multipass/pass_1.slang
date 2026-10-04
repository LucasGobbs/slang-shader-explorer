// TRAIL 10 — pass_1: the grade
// Declaring input_tex creates this pass's typed input pin. graph.json connects
// the first pass's out_tex to it; editing that edge changes the real runtime
// pipeline. This pass maps the pattern to a palette and darkens the edges.
import "../../common";

public struct GradeParams {
    [UiSlider(0.0, 1.0, 0.01, 0.35)]
    public float vignette;

    [UiColor(0.85, 0.45, 0.15)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[[vk::binding(3, 0)]]
ConstantBuffer<GradeParams> Params;

[[vk::binding(4, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    float v = input_tex.Sample(input_sampler, uv).r;
    debug_watch_compute(0, v, id.xy, Uniforms);
    float3 col = lerp(float3(0.08, 0.1, 0.2), Params.tint, v);
    debug_watch_compute(1, col, id.xy, Uniforms);
    // Vignette: darken by distance from the center.
    float d = length(uv - 0.5);
    col *= 1.0 - Params.vignette * smoothstep(0.3, 0.8, d);
    out_tex[id.xy] = float4(col, 1.0);
}
