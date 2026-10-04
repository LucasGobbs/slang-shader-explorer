// New 3D graphics scene: renders the loaded model with wrapped diffuse.
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
    float3 n = normalize(input.normal);
    float3 L = normalize(float3(0.5, 0.8, -0.1));
    float dif = 0.35 + 0.65 * saturate(dot(n, L));
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, float3(0.7) * dif);
}
