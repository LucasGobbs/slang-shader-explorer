// TRAIL 06 — Noise
// Procedural noise = smooth randomness. A hash gives a pseudo-random
// value per grid cell; interpolating between cells makes it smooth;
// layering scales (octaves) makes FBM, the texture of clouds and stone.
//
// Concepts: hash, value noise, fract/sin hashing, fractal Brownian motion.
//
// Try:
//   1. One octave = blocky. Slide octaves up and watch detail appear.
//   2. Animate: add 0.3 * Uniforms.iTime to the fbm() input.
//   3. Feed noise into a color ramp instead of grayscale.
import "../../common";

public struct NoiseParams {
    [UiSlider(1.0, 12.0, 0.1, 4.0)]
    public float frequency;

    [UiSlider(1.0, 6.0, 1.0, 4.0)]
    public float octaves;
};

float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

// Value noise: hash the 4 cell corners, smooth-interpolate inside.
float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f); // smoothstep curve
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// FBM: sum octaves, each at 2x frequency and half amplitude.
float fbm(float2 p, float octaves) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < int(octaves); i++) {
        v += amp * valueNoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return v;
}

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<NoiseParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float v = fbm(uv * Params.frequency, Params.octaves);
    float3 col = lerp(float3(0.1, 0.15, 0.25), float3(0.9, 0.85, 0.7), v);
    return float4(col, 1.0);
}
