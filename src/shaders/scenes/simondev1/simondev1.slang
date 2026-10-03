
import "../../common";

public struct WavesParams {
    [UiSlider(1, 40, 0.5, 13)]
    public float frequency;

    [UiSlider(0.1, 5, 0.05, 1)]
    public float speed;

    [UiToggle(1)]
    public float useColor;

    [UiToggle(1)]
    public float teste;

    [UiColor(0.12, 0.25, 0.75)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<WavesParams> Params;

[[vk::binding(2, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(3, 0)]]
SamplerState paper_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    // Always [0,1] in both dimensions, independent of aspect/resize.
    float2 p = normalized_screen_coord(input.gl_FragCoord, Uniforms.iResolution);
    float3 red = float3(1,0,0);
    float3 blue = float3(0, 0, 1);
    float3 color = Params.tint;
    // float3 color = float3(lerp(red, blue, p.x));
    // float3 color = float3(smoothstep(red, blue, p.x));
    // color = float3(0.7);
    // color = fract(float3(p, 0.0) * 10 );



    return float4(color, 1.0);
}
