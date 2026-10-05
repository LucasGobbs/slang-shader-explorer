// TRAIL 10: Multi-pass
// Until now, one pass did everything. Real effects chain passes: this
// compute pass writes an animated pattern into out_tex, and pass_1.slang
// reads that texture and grades it. Reflection creates typed pins; graph.json
// stores the executable topology shared by the node editor and runtime.
//
// Concepts: render passes, textures as glue, reflection-checked graphs.
//
// Try:
//   1. Open the node editor and find both passes plus the viewport output.
//   2. Detach out_tex -> input_tex and confirm: pass_1 samples black.
//   3. Reconnect the same pins and confirm: the graded pattern returns.
//   4. Change the pattern here; pass_1 follows without source changes.
//
import "../../common";

public struct PatternParams {
    [UiSlider(0.1, 5.0, 0.05, 1.0)]
    public float speed;

    [UiSlider(2.0, 30.0, 0.5, 12.0)]
    public float rings;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<PatternParams> Params;

[[vk::binding(2, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    float t = Uniforms.iTime * Params.speed;
    float d = length(uv - 0.5);
    float v = 0.5 + 0.5 * sin(Params.rings * d - t * 3.0);
    debug_watch_compute(0, v, id.xy, Uniforms);
    // Grayscale pattern out; pass_1 decides what it LOOKS like.
    out_tex[id.xy] = float4(float3(v), 1.0);
}
