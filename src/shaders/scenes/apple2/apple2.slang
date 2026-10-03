// Inktober day 1, second take: apple. The same SDF apple as apple.slang
// revolved into 3D and raymarched over a paper floor plane. Two lights
// play with the scene — a warm key orbiting over time and a cool static
// fill — with soft shadows cast on the apple and the paper. The final
// color is ordered-dithered (4x4 Bayer, 5 levels per channel) into a
// print-like palette. Single gather pass per pixel: no depth buffer.

import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

// Sampled textures must precede read-write storage in vk::binding order
// (SDL GPU MSL contract; see apple.slang).
[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

// Paper floor: the apple (bottom at ~-0.58) floats just above it so the
// key light drops a contact shadow.
static const float PLANE_Y = -0.62;

float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a;
    float3 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// IQ's ellipsoid bound (not exact near the surface, fine for marching).
float sdEllipsoid(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / k1;
}

// Returns (distance, material id): 0 = paper plane, 1 = body, 2 = stem,
// 3 = leaf.
float2 mapApple(float3 p) {
    // Body: the shared 2D profile revolved around the y axis.
    float2 q = float2(length(p.xz), p.y);
    float2 res = float2(sdAppleBody(q), 1.0);

    float stem = sdCapsule(p, float3(0.0, 0.36, 0.0), float3(0.10, 0.74, 0.0), 0.024);
    if (stem < res.x) res = float2(stem, 2.0);

    // Leaf: thin ellipsoid tilted like the 2D one (0.55 rad in xy).
    float cs = cos(0.55), sn = sin(0.55);
    float3 lp = p - float3(0.30, 0.66, 0.0);
    lp = float3(cs * lp.x + sn * lp.y, -sn * lp.x + cs * lp.y, lp.z);
    float leaf = sdEllipsoid(lp, float3(0.22, 0.085, 0.02)) - 0.005;
    if (leaf < res.x) res = float2(leaf, 3.0);
    return res;
}

float2 map(float3 p) {
    // Spin the apple around y; the paper plane stays put.
    float t = Uniforms.iTime * 0.6;
    float cs = cos(t), sn = sin(t);
    float3 pr = float3(p.x * cs - p.z * sn, p.y, p.x * sn + p.z * cs);
    float2 res = mapApple(pr);
    float plane = p.y - PLANE_Y;
    if (plane < res.x) res = float2(plane, 0.0);
    return res;
}

float3 calcNormal(float3 p) {
    const float2 e = float2(1.0, -1.0) * 0.0005;
    return normalize(
        e.xyy * map(p + e.xyy).x +
        e.yyx * map(p + e.yyx).x +
        e.yxy * map(p + e.yxy).x +
        e.xxx * map(p + e.xxx).x
    );
}

// Returns (t, material id); t < 0 on miss.
float2 raymarch(float3 ro, float3 rd) {
    float t = 0.0;
    for (int i = 0; i < 128; i++) {
        float2 h = map(ro + rd * t);
        if (h.x < 0.0008) return float2(t, h.y);
        t += h.x * 0.9;
        if (t > 6.0) break;
    }
    return float2(-1.0, -1.0);
}

float softShadow(float3 ro, float3 rd) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 32; i++) {
        float d = map(ro + rd * t).x;
        res = min(res, 12.0 * d / t);
        t += clamp(d, 0.015, 0.25);
        if (res < 0.005 || t > 4.0) break;
    }
    return saturate(res);
}

float3 lighting(float3 pos, float3 n, float3 rd, float3 albedo, float gloss) {
    float3 V = -rd;
    // Hemisphere ambient so the shadowed side keeps some shape.
    float3 col = albedo * 0.18 * (0.5 + 0.5 * n.y);

    // Warm key light orbiting the scene.
    float t = Uniforms.iTime * 0.5;
    float3 L1 = normalize(float3(1.6 * cos(t), 1.4, 1.6 * sin(t) + 0.6));
    float d1 = saturate(dot(n, L1));
    if (d1 > 0.0) {
        float s1 = softShadow(pos + n * 0.003, L1);
        float3 H1 = normalize(L1 + V);
        float spe = pow(saturate(dot(n, H1)), gloss) * d1;
        col += (albedo * d1 + spe) * s1 * float3(1.0, 0.88, 0.72);
    }

    // Cool static fill, unshadowed and dim.
    float3 L2 = normalize(float3(-1.0, 0.5, 0.9));
    col += albedo * saturate(dot(n, L2)) * 0.35 * float3(0.55, 0.7, 0.95);

    return col;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    float2 paper_uv = float2(id.xy) / Uniforms.iResolution.xy;
    float3 paper = paper_tex.SampleLevel(paper_sampler, paper_uv, 0).rgb;

    float3 ro = float3(0.0, 0.32, 2.3);
    float3 fwd = normalize(float3(0.0, -0.02, 0.0) - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.35 + right * uv.x + up * uv.y);

    float2 hit = raymarch(ro, rd);
    float3 col;
    if (hit.x < 0.0) {
        // Miss: paper background with the usual vignette.
        col = paper * (1.0 - 0.25 * dot(uv, uv));
    } else {
        float3 pos = ro + rd * hit.x;
        float3 n = calcNormal(pos);
        int mat = int(hit.y + 0.5);
        float3 albedo;
        float gloss = 8.0;
        if (mat == 0) {
            // Paper floor: same texture, world-mapped.
            albedo = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.25 + 0.5, 0).rgb;
            gloss = 4.0;
        } else if (Uniforms.iColorMode > 0.5) {
            if (mat == 1) { albedo = float3(0.62, 0.08, 0.05); gloss = 42.0; }
            else if (mat == 2) { albedo = float3(0.30, 0.18, 0.08); }
            else { albedo = float3(0.25, 0.45, 0.15); gloss = 14.0; }
        } else {
            // Ink look: one dark albedo, specular reads as glossy ink.
            albedo = float3(0.07);
            gloss = 20.0;
        }
        col = lighting(pos, n, rd, albedo, gloss);
    }

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
