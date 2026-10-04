// vignette3d: the multi-pass test scene. Entry pass renders the loaded
// model with two-light shading and a fresnel rim over the skybox; the
// chained pass (pass_1.slang) grades the frame with a vignette.

import "../../common";


[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> skybox_tex;

[[vk::binding(2, 0)]]
SamplerState skybox_sampler;


[shader("vertex")]
ModelVaryings vertMain(ModelVertex input, uint vertexIndex : SV_VertexID) {
    return model_scene_vertex(input, vertexIndex, Uniforms);
}

[shader("fragment")]
float4 pixelMain(ModelVaryings input) : SV_Target0 {
    float3 n = normalize(input.normal + float3(0.0, 0.0, 1e-8));

    // Key light: warm, wrapped for a soft terminator.
    float3 L = normalize(float3(0.5, 0.8, -0.6));
    float wrap = 0.5;
    float dif = saturate((dot(n, L) + wrap) / (1.0 + wrap));
    float3 H = normalize(L + float3(0.0, 0.0, -1.0));
    float spesad = pow(saturate(dot(n, H)), 30.0) * 0.35;

    // Fill light: cool, from below-opposite, so shadow sides stay readable.
    float3 L2 = normalize(float3(-0.6, -0.2, 0.5));
    float fill = saturate(dot(n, L2)) * 0.25;

    // Fresnel rim: the model sits at the origin, so the camera position is
    // a fair per-pixel view proxy at this distance.
    float3 V = normalize(Uniforms.iCameraPosition);
    float rim = pow(1.0 - saturate(dot(n, V)), 3.0) * 0.5;

    float3 base = float3(0.62, 0.08, 0.05);
    float3 col = base * (0.30 + 0.70 * dif)
               + float3(0.10, 0.14, 0.22) * fill
               + spesad
               + float3(0.9, 0.75, 0.55) * rim;
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, col);
}
