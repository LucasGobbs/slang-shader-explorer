// Fullscreen blit: samples the offscreen texture the compute scenes
// rendered this frame. The only graphics pipeline in the app besides the
// UI overlay.

[[vk::binding(0, 0)]]
Texture2D<float4> tex;

[[vk::binding(1, 0)]]
SamplerState tex_sampler;

struct VsOut {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    VsOut o;
    // Fullscreen triangle; uv interpolates 0..1 across the screen.
    float2 p = float2((vertexIndex << 1) & 2, vertexIndex & 2);
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    // Metal NDC +y is up but texture uv (0,0) is the top row: without the
    // flip, texture row 0 (scene top, fragCoord.y = iResolution.y) lands
    // at the bottom of the screen and the scene renders upside down.
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    return tex.Sample(tex_sampler, input.uv);
}
