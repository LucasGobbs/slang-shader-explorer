// TRAIL 03 — Mouse
// iMousePos (pixels) and iMouseClick (0/1) make the shader interactive.
// A spotlight follows your cursor; press the button to warm the light.
//
// Concepts: interaction uniforms, pixel-space vs uv-space distance,
// smoothstep for soft edges.
//
// Try:
//   1. Change radius live in the inspector.
//   2. Replace smoothstep with step — what happens to the edge?
//   3. Make the spotlight repel instead of attract (uv - dir).
import "../../common";

public struct MouseParams {
    [UiSlider(20.0, 400.0, 1.0, 140.0)]
    public float radius;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<MouseParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    // iMousePos is in pixels — compare it against fragCoord, not uv.
    float d = length(input.gl_FragCoord.xy - Uniforms.iMousePos);
    float light = 1.0 - smoothstep(0.0, Params.radius, d);
    float3 cool = float3(0.12, 0.25, 0.6);
    float3 warm = float3(0.9, 0.55, 0.2);
    float3 col = (Uniforms.iMouseClick > 0.5 ? warm : cool) * light + 0.03;
    return float4(col, 1.0);
}
