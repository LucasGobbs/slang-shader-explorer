// Darkroom "develop" transition (overdrive FX): the newly selected scene
// emerges like a photo in developer fluid instead of a hard cut.
// Highlights surface first, mids and shadows follow (a luminance threshold
// falling with t), under a safelight-amber wash that fades out, with grain
// while the bath is fresh. t goes 0 -> 1 in about a second, then the
// normal blit path takes over (see main.odin).

[[vk::binding(0, 0)]]
Texture2D<float4> tex;

[[vk::binding(1, 0)]]
SamplerState tex_sampler;

struct DevelopUniforms {
    float t;       // 0..1 develop progress
    float time;    // app time in seconds, for animated grain
    float2 res;    // window size in pixels
    int variant;   // 0 = develop bath, 1 = bayer dissolve, 2 = iris
    float2 origin; // iris center (scene selector), normalized 0..1
};

[[vk::binding(2, 0)]]
ConstantBuffer<DevelopUniforms> u;

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
    // Metal NDC +y is up but texture uv (0,0) is the top row (see blit.slang).
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// 4x4 Bayer matrix index for the dissolve variant (ordered dithering is
// this app's signature look — the transition wears it too).
float bayer4(float2 p) {
    int2 q = int2(p) & 3;
    int idx = q.y * 4 + q.x;
    const float m[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    return m[idx] / 16.0;
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float3 scene = tex.Sample(tex_sampler, input.uv).rgb;
    float t = saturate(u.t);
    float3 amber = float3(0.91, 0.66, 0.34);
    float emerge;

    if (u.variant == 1) {
        // Bayer dissolve: pixels appear as the dither threshold passes
        // them, with an amber wash on the not-yet-dissolved side.
        float edge = 0.08;
        emerge = smoothstep(t - edge, t + edge, bayer4(input.uv * u.res));
        float3 notYet = amber * (0.35 + 0.65 * (1.0 - t)) * 0.55;
        float3 developed = scene * emerge + notYet * (1.0 - emerge);
        return float4(developed, 1.0);
    }

    if (u.variant == 2) {
        // Iris: a circle opens from the scene selector, amber frontier.
        float aspect = u.res.x / u.res.y;
        float2 d = input.uv - u.origin;
        d.x *= aspect;
        float radius = t * 1.5;
        float dist = length(d);
        emerge = 1.0 - smoothstep(radius - 0.12, radius, dist);
        float ring = smoothstep(0.02, 0.0, abs(dist - radius + 0.06)) * (1.0 - t);
        float3 developed = scene * emerge + amber * (1.0 - emerge) * 0.45 * (1.0 - t);
        return float4(developed + amber * ring * 0.8, 1.0);
    }

    // Development bath (variant 0): a luminance threshold falls from 1 to
    // 0; pixels emerge as the bath reaches them. Soft edge, per-pixel
    // dither so the front is organic rather than a clean wipe.
    float luma = dot(scene, float3(0.299, 0.587, 0.114));
    float edge = 0.22;
    float n = hash21(floor(input.uv * u.res / 2.0));
    float thresh = 1.0 - t * (1.0 + edge);
    emerge = smoothstep(thresh - edge, thresh + edge, luma + (n - 0.5) * edge);

    // Safelight wash: strong at the start, gone by t=0.75.
    float wash = (1.0 - smoothstep(0.0, 0.75, t)) * 0.55;
    float3 developed = scene * emerge + amber * wash * (0.25 + 0.75 * emerge) * (1.0 - emerge * 0.6);

    // Animated grain, fading with the wash.
    float grain = (hash21(input.uv * u.res + floor(u.time * 24.0)) - 0.5) * 0.09 * (1.0 - t);
    developed += grain;

    // Gentle vignette while developing.
    float2 d = input.uv - 0.5;
    float vig = 1.0 - dot(d, d) * 0.9 * (1.0 - t);
    return float4(developed * vig, 1.0);
}
