// Shared input layout only. Every scene declares its own
// ConstantBuffer<SceneUniforms> binding; reflection is structural, so the
// glue emits the same layout for all of them. Algorithms live in each
// shader file — a reader sees everything a scene uses in one place.

public struct SceneUniforms {
    public float3 iResolution;
    public float iTime;
    // Shape controls driven by the UI sliders: x = octave count,
    // y = lacunarity (frequency multiplier per octave), z = gain
    // (amplitude multiplier per octave). w is free for per-scene use.
    public float4 iFbm;
    // 1.0 = scene's alternate look (e.g. color instead of ink),
    // 0.0 = default look. Driven by the "color" checkbox.
    public float iColorMode;
    // Free per-scene toggle (1.0 by default).
    public float iManual;
}
