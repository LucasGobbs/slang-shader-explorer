// Inktober day 1: apple. A procedural apple drawn as 2D signed-distance
// shapes (body, stem, leaf) on fbm-grained paper. Default look is black
// ink with rough, hand-drawn edges; the "color" checkbox switches to a
// shaded red apple. The sliders drive the paper grain and edge wobble
// (octaves / lacunarity / gain).

import common;

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
RWTexture2D<float4> out_tex;

float hash21(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float fbm(float2 p, int octaves, float lacunarity, float gain) {
    float sum = 0.0;
    float amp = 0.5;
    float2 q = p;
    [MaxIters(12)]
    for (int i = 0; i < octaves; i++) {
        sum += amp * valueNoise(q);
        q = q * lacunarity + float2(17.3, 9.1);
        amp *= gain;
    }
    return sum;
}

// Apple body: a circle pinched horizontally at the poles, with a stem
// well pressed into the top and a small dimple at the bottom. Not an
// exact SDF near the dents — close enough for smoothstep fills.
float sdAppleBody(float2 p) {
    float2 q = p;
    q.x /= 1.0 - 0.18 * q.y * q.y;
    float d = length(q) - 0.52;
    d += 0.10 * exp(-40.0 * (p.x * p.x + (p.y - 0.45) * (p.y - 0.45)));
    d += 0.06 * exp(-60.0 * (p.x * p.x + (p.y + 0.50) * (p.y + 0.50)));
    return d;
}

float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

float sdEllipse(float2 p, float2 c, float2 r, float rot) {
    float cs = cos(rot);
    float sn = sin(rot);
    float2 q = p - c;
    q = float2(cs * q.x + sn * q.y, -sn * q.x + cs * q.y);
    return (length(q / r) - 1.0) * min(r.x, r.y);
}

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
    if (any(id.xy >= uint2(Uniforms.iResolution.xy))) return;
    float2 fragCoord = float2(id.x, Uniforms.iResolution.y - float(id.y));

    // Centered, aspect-correct coordinates; the apple spans ~60% of the
    // window height.
    float2 p = (fragCoord - 0.5 * Uniforms.iResolution.xy) / Uniforms.iResolution.y;
    float t = Uniforms.iTime;
    // Zoom out so the stem and leaf fit the frame, and shift down so the
    // apple's visual mass (body low, stem/leaf high) sits centered.
    p = p * 1.5 + float2(0.0, 0.05);
    p.y -= 0.02 * sin(t * 0.8); // gentle bob

    int octaves = int(Uniforms.iFbm.x);
    float lacunarity = Uniforms.iFbm.y;
    float gain = Uniforms.iFbm.z;

    float grain = fbm(fragCoord * 0.35 / Uniforms.iResolution.y * 40.0,
                      octaves, lacunarity, gain);

    AppleDist d = appleDistances(p);

    // Hand-drawn wobble: perturb the ink edge with low-frequency noise.
    float wobble = fbm(p * 6.0 + float2(3.7, 1.3), octaves, lacunarity, gain) - 0.25;
    float dInk = d.all + 0.035 * wobble;

    float aa = 1.5 / Uniforms.iResolution.y;

    // Paper: warm off-white, grain darkening, soft vignette.
    float3 paper = float3(0.93, 0.91, 0.86) * (0.92 + 0.08 * grain);
    paper *= 1.0 - 0.25 * dot(p, p);

    // Contact shadow under the apple.
    float shadow = exp(-pow(length((p - float2(0.05, -0.62)) / float2(0.48, 0.10)), 2.0));
    paper *= 1.0 - 0.25 * shadow;

    float3 col;
    if (Uniforms.iColorMode > 0.5) {
        // Color look: shaded red apple, brown stem, green leaf.
        float bodyFill = smoothstep(aa, -aa, d.body);
        float stemFill = smoothstep(aa, -aa, d.stem);
        float leafFill = smoothstep(aa, -aa, d.leaf);

		// Cheap spherical shading keyed on the body SDF.
		float shade = clamp(0.65 - 0.9 * d.body - 0.4 * p.y, 0.0, 1.2);
        float3 red = lerp(float3(0.45, 0.05, 0.05), float3(0.85, 0.15, 0.10), shade);
        red *= 0.9 + 0.2 * grain;
        // Glossy highlight.
        red += 0.55 * exp(-pow(length((p - float2(-0.18, 0.16)) / float2(0.16, 0.24)), 2.0));

        float3 brown = float3(0.30, 0.18, 0.08);
        float3 green = float3(0.25, 0.45, 0.15) * (0.85 + 0.3 * grain);

        col = paper;
        col = lerp(col, red, bodyFill);
        col = lerp(col, brown, stemFill);
        col = lerp(col, green, leafFill);
        // Ink outline on top, for the inktober feel.
        float outline = smoothstep(0.012, 0.002, abs(d.all + 0.01 * wobble));
        col = lerp(col, float3(0.10), outline * 0.85);
    } else {
        // Ink look: rough-edged black fill with dry-brush texture inside.
        float inkFill = smoothstep(aa, -aa, dInk);
        float dryBrush = 0.75 + 0.25 * fbm(p * 30.0, octaves, lacunarity, gain);
        float3 ink = float3(0.08) * dryBrush;
        col = lerp(paper, ink, inkFill);
        // Leaf vein.
        float vein = sdSegment(p, float2(0.12, 0.72), float2(0.46, 0.58)) - 0.004;
        float veinMask = smoothstep(aa, -aa, vein) * smoothstep(aa, -aa, d.leaf);
        col = lerp(col, paper, veinMask * 0.7);
    }

    out_tex[id.xy] = float4(col, 1.0);
}
