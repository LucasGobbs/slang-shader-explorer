// TRAIL 01: Hello, pixel!
// Your first shader: every pixel on screen runs pixelMain() and returns
// its own color. The only input you need is the pixel's coordinate.
//
// Concepts: fragment shader, normalized coordinates (uv), color as float3.
//
// Try:
//   1. Swap uv.x and uv.y in lerp(a, b, uv.x): what changes?
//   2. Make the gradient vertical instead of horizontal.
//   3. Pick your own color in the inspector (the tint parameter
//      appeared there automatically when this file declared it).
import "../../common";

public struct HelloParams {
    [UiColor(0.15, 0.35, 0.75)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<HelloParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    // uv goes (0,0) bottom-left to (1,1) top-right, aspect-corrected.
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float3 a = Params.tint;
    float3 b = float3(0.95, 0.93, 0.88); // paper white
    return float4(lerp(a, b, uv.x), 1.0);
}
