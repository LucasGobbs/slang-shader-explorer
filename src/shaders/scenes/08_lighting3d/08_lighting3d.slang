// TRAIL 08 — Lighting a 3D model
// Same ideas, new stage: the vertex shader transforms the loaded model,
// the fragment shader receives interpolated normals and lights them.
// Wrapped diffuse keeps shadows soft; a rim term fakes bounce light.
//
// Concepts: vertex/fragment split, normals, dot(n, l) diffuse, rim light.
//
// Try:
//   1. wrap = 0 gives hard Lambert; slide it and watch the terminator.
//   2. Rotate the light by iTime: L = normalize(float3(cos(t), 0.8, sin(t))).
//   3. Kill the rim term — notice how much depth it was adding.
import "../../common";

public struct LightParams {
    [UiSlider(0.0, 0.5, 0.01, 0.15)]
    public float wrap;

    [UiColor(0.75, 0.4, 0.25)]
    public float3 tint;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<LightParams> Params;

[[vk::binding(2, 0)]]
Texture2D<float4> skybox_tex;

[[vk::binding(3, 0)]]
SamplerState skybox_sampler;

[shader("vertex")]
ModelVaryings vertMain(ModelVertex input, uint vertexIndex : SV_VertexID) {
    return model_scene_vertex(input, vertexIndex, Uniforms);
}

[shader("fragment")]
float4 pixelMain(ModelVaryings input) : SV_Target0 {
    float3 n = normalize(input.normal);
    float3 L = normalize(float3(0.5, 0.8, -0.1));
    // Wrapped diffuse: remap dot(n,l) from [-1,1] toward [0,1].
    float dif = saturate((dot(n, L) + Params.wrap) / (1.0 + Params.wrap));
    // Cheap rim from the normal alone: surfaces facing away from the
    // light AND grazing the viewer (small |n.z|) catch a faint glow.
    float rim = pow(1.0 - abs(n.z), 3.0) * (1.0 - dif);
    float3 lit = Params.tint * (0.15 + 0.85 * dif) + rim * 0.25;
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, lit);
}
