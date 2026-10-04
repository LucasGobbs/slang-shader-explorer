// New 2D graphics scene: fullscreen triangle, per-pixel fragment.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 p = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    return float4(float3(v), 1.0);
}
