// Mouse uniform test: blue dot follows the cursor (iMousePos), turns
// red while the left button is pressed (iMouseClick).

import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);

    float d = length(fragCoord - Uniforms.iMousePos) - 40.0;
    float3 dot_col = Uniforms.iMouseClick > 0.5 ? float3(0.8, 0.1, 0.1) : float3(0.1, 0.3, 0.8);
    float3 col = lerp(dot_col, float3(0.93, 0.91, 0.86), smoothstep(-1.5, 1.5, d));
    out_tex[id.xy] = float4(col, 1.0);
}
