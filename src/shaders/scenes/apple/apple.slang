// Inktober day 1: apple. A procedural apple drawn as 2D signed-distance
// shapes (body, stem, leaf) on real scanned paper (paper_tex, picked in
// the UI) instead of procedural grain. Default look is black ink with
// rough, hand-drawn edges; the "color" checkbox switches to a shaded red
// apple. The final color is ordered-dithered (see common.slang) into a
// print-like palette.

import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

struct AppleDist {
    float body;
    float stem;
    float leaf;
    float all;
}

AppleDist appleDistances(float2 p) {
    AppleDist d;
    d.body = sdAppleBody(p);
    d.stem = sdSegment(p, float2(0.00, 0.38), float2(0.10, 0.74)) - 0.022;
    d.leaf = sdEllipse(p, float2(0.30, 0.66), float2(0.22, 0.085), 0.55);
    d.all = min(d.body, min(d.stem, d.leaf));
    return d;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);

    float2 p = scene_uv(fragCoord, Uniforms.iResolution);
    float t = Uniforms.iTime;
    uint2 uv = id.xy;
    float2 norm_uv = float2(uv) / Uniforms.iResolution.xy;
    float3 paper_texture = paper_tex.SampleLevel(paper_sampler, norm_uv, 0).rgb;

    float3 bg = paper_texture;


    // Zoom out 
    p = p * 1.5 + float2(0.0, 0.05);
    p.y -= 0.02 * sin(t * 0.8); // gentle bob

    int octaves = int(Uniforms.iFbm.x);
    float lacunarity = Uniforms.iFbm.y;
    float gain = Uniforms.iFbm.z;

    float grain = fbm(fragCoord * 0.35 / Uniforms.iResolution.y * 40.0,
                      octaves, lacunarity, gain);

    bg += grain*0.2;
    AppleDist d = appleDistances(p);


    float wobbleAmp = 0.035;
    float dryness = fbm(p * 2.0 + 7.0, octaves, lacunarity, gain);
    wobbleAmp = 0.015 + 0.06 * dryness;
    // Hand-drawn wobble: perturb the ink edge with low-frequency noise.
    float wobble = fbm(p * 6.0 + float2(3.7, 1.3), octaves, lacunarity, gain) - 0.25;
    float dInk = d.all + wobbleAmp * wobble;

    float aa = 1.5 / Uniforms.iResolution.y;

    // Vignette
    bg *= 1.0 - 0.55 * dot(p, p);

    // Contact shadow
    float shadow = exp(-pow(length((p - float2(0.05, -0.62)) / float2(0.48, 0.10)), 2.0));
    bg *= 1.0 - 0.25 * shadow;

    float3 col;

    float inkFill = smoothstep(aa, -aa, dInk);

    float dryBrush = 0.7 + 0.3 * fbm(p * float2(6.0, 45.0), octaves, lacunarity, gain);

    float3 ink = float3(0.10) * dryBrush;



    col = lerp(bg, ink, inkFill);

    float rim = smoothstep(0.025, 0.0, abs(dInk));
    col = lerp(col, ink * 0.4, rim * inkFill * 0.8);

    float speck = step(0.79, fbm(p * 10.0, octaves, lacunarity, gain)) * inkFill;
    col = lerp(col, bg, speck * 0.01);

    float bleed = smoothstep(aa * 16.0, aa, dInk) * (1.0 - inkFill);
    float fibers = fbm(p * 25.0, octaves, lacunarity, gain);
    col = lerp(col, bg * 0.52, bleed * 0.35 * fibers);

    out_tex[uv] = float4(col, 1.0);
}
