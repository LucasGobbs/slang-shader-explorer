// Hot-add test: minimal compute scene with one annotated param. Created
// while the app was running; it appeared in the scene list without any
// code change or restart.

import "../../common";

public struct RingsParams {
    [UiSlider(2, 60, 1, 6)]
    public float rings;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<RingsParams> Params;

[[vk::binding(2, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);

    float r = length(p) * Params.rings - Uniforms.iTime;
    float v = smoothstep(0.4, 0.6, frac(r));

    float3 col = lerp(float3(0.222, 0.91, 0.86), float3(0.1), v);
    col = gizmo2d(fragCoord, Uniforms.iResolution, col);
    out_tex[id.xy] = float4(col, 1.0);
}
