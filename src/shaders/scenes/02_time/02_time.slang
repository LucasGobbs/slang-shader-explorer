// TRAIL 02: Time
// The SceneUniforms block gives you iTime: seconds since the scene
// started. Feed it through sin() and static images start to breathe.
//
// Concepts: uniforms, iTime, sin() for periodic motion, phase offsets.
//
// Try:
//   1. Change speed in the inspector while watching the rings.
//   2. Give each RGB channel a different phase (+0.0, +2.1, +4.2)
//      and watch white light split into color.
//   3. Replace sin with fract(t): what does the motion become?
import "../../common";

public struct TimeParams {
    [UiSlider(0.1, 5.0, 0.05, 1.0)]
    public float speed;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<TimeParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float t = Uniforms.iTime * Params.speed;
    // Rings expanding from the center: distance drives a sine wave.
    float d = length(uv - 0.5);
    float v = 0.5 + 0.5 * sin(20.0 * d - t * 3.0);
    return float4(float3(0.1, 0.4, 0.7) * v + 0.05, 1.0);
}
