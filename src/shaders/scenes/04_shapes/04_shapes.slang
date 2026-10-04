// TRAIL 04 — Shapes with SDF
// A signed-distance function (SDF) answers: "how far is this pixel from
// the shape's edge?" Negative inside, positive outside. Everything else
// — fill, outline, soft glow — is just a remap of that one number.
//
// Concepts: signed distance fields, length(), smoothstep antialiasing.
//
// Try:
//   1. sdBox is given below — draw a box next to the circle.
//   2. min(d1, d2) unions two shapes: draw both at once.
//   3. Use abs(d) instead of d in the fill: you get a ring.
import "../../common";

public struct ShapeParams {
    [UiSlider(0.05, 0.45, 0.005, 0.25)]
    public float radius;

    [UiSlider(0.001, 0.1, 0.001, 0.02)]
    public float softness;
};

float sdCircle(float2 p, float r) { return length(p) - r; }

float sdBox(float2 p, float2 b) {
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<ShapeParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    // Centered coordinates: (0,0) is the middle of the screen.
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution) - 0.5;
    float d = sdCircle(uv, Params.radius);
    // smoothstep turns the distance into an antialiased mask:
    // 1 inside the circle, 0 outside, soft across `softness`.
    float fill = 1.0 - smoothstep(-Params.softness, Params.softness, d);
    float3 col = lerp(float3(0.94, 0.92, 0.87), float3(0.15, 0.2, 0.35), fill);
    return float4(col, 1.0);
}
