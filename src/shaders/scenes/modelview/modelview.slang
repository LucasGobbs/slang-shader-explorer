// Model viewer demo. Runtime/background plumbing lives in common.slang;
// this scene only declares resources and model shading.

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
    // Wrapped diffuse (soft terminator) + specular, no env tint.
    float3 n = normalize(input.normal + float3(0.0, 0.0, 1e-8));
    float3 L = normalize(float3(0.5, 0.8, -0.6));
    float wrap = 0.5;
    float dif = saturate((dot(n, L) + wrap) / (1.0 + wrap));
    float3 H = normalize(L + float3(0.0, 0.0, -1.0));
    float spe = pow(saturate(dot(n, H)), 30.0) * 0.35;
    float3 col = float3(0.62, 0.08, 0.05) * (0.35 + 0.65 * dif) + spe;
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, col);
}
