// TRAIL 05 — Combining SDFs
// Three operators build almost every SDF scene:
//   min(a, b)  union        — either shape
//   max(a, b)  intersection — only where both overlap
//   max(a,-b)  subtraction  — a with b carved out
// Here a circle chases a box while you morph between the three.
//
// Concepts: SDF boolean operators, animating shape centers.
//
// Try:
//   1. Animate the box too, at half the speed.
//   2. Chain a third shape with another min().
//   3. Subtraction order matters: swap max(d1,-d2) to max(d2,-d1).
import "../../common";

public struct OpsParams {
    [UiSlider(0.0, 1.0, 0.01, 0.0)]
    public float operation; // 0=union, 0.5=intersection, 1=subtraction
};

float sdCircle(float2 p, float r) { return length(p) - r; }

float sdBox(float2 p, float2 b) {
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<OpsParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution) - 0.5;

    // The box orbits slowly; the circle stays centered.
    float a = Uniforms.iTime * 0.7;
    float2 boxPos = 0.25 * float2(cos(a), sin(a));
    float dBox = sdBox(uv - boxPos, float2(0.15, 0.15));
    float dCircle = sdCircle(uv, 0.2);

    // Blend between the three boolean operators with one slider.
    float dUnion = min(dBox, dCircle);
    float dInter = max(dBox, dCircle);
    float dSub = max(dCircle, -dBox);
    float d = Params.operation < 0.5
        ? lerp(dUnion, dInter, Params.operation * 2.0)
        : lerp(dInter, dSub, Params.operation * 2.0 - 1.0);

    float fill = 1.0 - smoothstep(-0.01, 0.01, d);
    float3 col = lerp(float3(0.94, 0.92, 0.87), float3(0.55, 0.2, 0.25), fill);
    return float4(col, 1.0);
}
