// TRAIL 09: Compute
// Same picture as TRAIL 02, completely different machine. A compute
// shader has no vertex stage: the GPU launches a grid of threads and
// each thread writes its pixel straight into a storage texture.
//
// Concepts: compute shaders, thread IDs, RWTexture, numthreads.
//
// Try:
//   1. Compare with 02_time side by side: same math, new model.
//   2. [numthreads(8,8,1)] is the workgroup size; try (16,16,1).
//   3. Write to a NEIGHBORING pixel instead (id.xy + int2(1,0))
//      and watch the image shift.
import "../../common";

public struct ComputeParams {
    [UiSlider(0.1, 5.0, 0.05, 1.0)]
    public float speed;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<ComputeParams> Params;

[[vk::binding(2, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    // Threads cover the whole window in 8x8 blocks; edge threads exit.
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);
    debug_watch_compute(0, uv, id.xy, Uniforms);

    float t = Uniforms.iTime * Params.speed;
    float d = length(uv - 0.5);
    float v = 0.5 + 0.5 * sin(20.0 * d - t * 3.0);
    debug_watch_compute(1, v, id.xy, Uniforms);
    out_tex[id.xy] = float4(float3(0.1, 0.4, 0.7) * v + 0.05, 1.0);
}
