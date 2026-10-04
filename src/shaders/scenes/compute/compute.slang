// New compute scene: one thread per pixel writing out_tex.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    out_tex[id.xy] = float4(float3(v), 1.0);
}
