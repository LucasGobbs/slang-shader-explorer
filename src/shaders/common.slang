// Shared input layout plus the math every scene reuses: value-noise fbm
// and the compute→Shadertoy coordinate helpers. Scene-specific algorithms
// (SDFs, palettes) live in each shader file.

public struct SceneUniforms {
    public float3 iResolution;
    public float iTime;
    // Noise controls: x = octave count, y = lacunarity (frequency
    // multiplier per octave), z = gain (amplitude multiplier per
    // octave). w is free for per-scene use.
    public float4 iFbm;
    // 1.0 = scene's alternate look (e.g. color instead of ink),
    // 0.0 = default look. Driven by the "color" checkbox.
    [UiToggle(0)]
    public float iColorMode;
    // Mouse position in pixels, same convention as frag_coord
    // (y up from the bottom).
  	 
    public float2 iMousePos;
    // 1.0 while the left button is pressed outside the UI.
    public float iMouseClick;
    // Camera computed by Odin and passed to every scene.
    public column_major float4x4 iViewProjection;
    public float3 iCameraPosition;
    public float3 iCameraRight;
    public float3 iCameraUp;
    public float3 iCameraForward;
    // Free per-scene toggle (1.0 by default).
    public float iManual;
    // Selected invocation for debug_watch_* helpers.
    public uint2 iDebugPixel;
    public uint iDebugEnabled;
    public uint iDebugFrame;
    public uint iDebugPass;
}

public float hash21(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

public float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

public float fbm(float2 p, int octaves, float lacunarity, float gain) {
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

// Compute dispatches count y down from the top; scenes expect
// Shadertoy-style fragCoord with y up from the bottom.
public float2 frag_coord(uint3 id, float3 iResolution) {
    return float2(id.x, iResolution.y - float(id.y));
}

public bool is_outside(uint3 id, float3 iResolution) {
    return any(id.xy >= uint2(iResolution.xy));
}

// Centered, aspect-correct scene coordinates: y in [-0.5, 0.5],
// 1 unit = iResolution.y pixels.
public float2 scene_uv(float2 fragCoord, float3 iResolution) {
    return (fragCoord - 0.5 * iResolution.xy) / iResolution.y; 
}  

// Ordered 4x4 Bayer dither: quantizes each channel to `levels` steps
// with a per-pixel threshold jitter, so gradients read as print
// halftone. Both apple scenes finish with this.
public float bayer4(uint2 p) {
    static const uint M[16] = {
        0u, 8u, 2u, 10u,
        12u, 4u, 14u, 6u,
        3u, 11u, 1u, 9u,
        15u, 7u, 13u, 5u,
    };
    return (float(M[(p.y % 4u) * 4u + (p.x % 4u)]) + 0.5) / 16.0;
}

public float3 orderedDither(float3 col, float levels, uint2 id) {
    return floor(saturate(col) * levels + bayer4(id)) / levels;
}

// Debug visualizations: map intermediate values to colors that can be
// returned directly from a fragment/compute shader while investigating it.
public float4 debug_scalar(float value, float minValue, float maxValue) {
    float span = max(maxValue - minValue, 1e-6);
    float t = saturate((value - minValue) / span);
    return float4(t.xxx, 1.0);
}

public float4 debug_signed(float value, float absMax) {
    float t = saturate(abs(value) / max(absMax, 1e-6));
    float3 zero = float3(0.5);
    float3 negative = float3(0.1, 0.35, 1.0);
    float3 positive = float3(1.0, 0.2, 0.1);
    return float4(lerp(zero, value < 0.0 ? negative : positive, t), 1.0);
}

public float4 debug_vector(float2 value) {
    return float4(saturate(value * 0.5 + 0.5), 0.5, 1.0);
}

public float4 debug_vector(float3 value) {
    return float4(saturate(value * 0.5 + 0.5), 1.0);
}

public float4 debug_normal(float3 normal) {
    return float4(normalize(normal) * 0.5 + 0.5, 1.0);
}

public float4 debug_mask(bool value) {
    return value ? float4(1.0) : float4(0.0, 0.0, 0.0, 1.0);
}

// Invalid-value convention shared with the blit overlay:
// NaN = magenta, +Inf = yellow, -Inf = cyan.
public float4 debug_nan_inf(float4 value) {
    if (any(isnan(value))) return float4(1.0, 0.0, 1.0, 1.0);
    if (any(isinf(value) && value < 0.0)) return float4(0.0, 1.0, 1.0, 1.0);
    if (any(isinf(value))) return float4(1.0, 1.0, 0.0, 1.0);
    return value;
}

// Selected-invocation watch console. The shared buffer is used by either
// graphics or compute; dead-code elimination removes it from shaders that
// never call a debug_watch_* helper.
public static const uint DEBUG_WATCH_COUNT = 8;

public struct DebugWatchRecord {
    public uint frameId;
    public uint type;   // 1=float, 2=float2, 3=float3, 4=float4
    public uint count;
    public uint reserved; // pass index
    public float4 value;
};
[[vk::binding(0, 1)]]
RWStructuredBuffer<DebugWatchRecord> debug_records;

public void debug_watch_fragment(uint slot, float4 value, uint type, uint2 fragCoord, SceneUniforms debug) {
    if (debug.iDebugEnabled == 0 || slot >= DEBUG_WATCH_COUNT || any(fragCoord != debug.iDebugPixel)) return;
    DebugWatchRecord record;
    record.frameId = debug.iDebugFrame;
    record.type = type;
    record.count = min(type, 4u);
    record.reserved = debug.iDebugPass;
    record.value = value;
    debug_records[debug.iDebugPass * DEBUG_WATCH_COUNT + slot] = record;
}

public void debug_watch_fragment(uint slot, float value, uint2 fragCoord, SceneUniforms debug) {
    debug_watch_fragment(slot, float4(value, 0, 0, 0), 1, fragCoord, debug);
}

public void debug_watch_fragment(uint slot, float2 value, uint2 fragCoord, SceneUniforms debug) {
    debug_watch_fragment(slot, float4(value, 0, 0), 2, fragCoord, debug);
}

public void debug_watch_fragment(uint slot, float3 value, uint2 fragCoord, SceneUniforms debug) {
    debug_watch_fragment(slot, float4(value, 0), 3, fragCoord, debug);
}

public void debug_watch_fragment(uint slot, float4 value, uint2 fragCoord, SceneUniforms debug) {
    debug_watch_fragment(slot, value, 4, fragCoord, debug);
}

public void debug_watch_compute(uint slot, float4 value, uint type, uint2 dispatchId, SceneUniforms debug) {
    if (debug.iDebugEnabled == 0 || slot >= DEBUG_WATCH_COUNT || any(dispatchId != debug.iDebugPixel)) return;
    DebugWatchRecord record;
    record.frameId = debug.iDebugFrame;
    record.type = type;
    record.count = min(type, 4u);
    record.reserved = debug.iDebugPass;
    record.value = value;
    debug_records[debug.iDebugPass * DEBUG_WATCH_COUNT + slot] = record;
}

public void debug_watch_compute(uint slot, float value, uint2 dispatchId, SceneUniforms debug) {
    debug_watch_compute(slot, float4(value, 0, 0, 0), 1, dispatchId, debug);
}

public void debug_watch_compute(uint slot, float2 value, uint2 dispatchId, SceneUniforms debug) {
    debug_watch_compute(slot, float4(value, 0, 0), 2, dispatchId, debug);
}

public void debug_watch_compute(uint slot, float3 value, uint2 dispatchId, SceneUniforms debug) {
    debug_watch_compute(slot, float4(value, 0), 3, dispatchId, debug);
}

public void debug_watch_compute(uint slot, float4 value, uint2 dispatchId, SceneUniforms debug) {
    debug_watch_compute(slot, value, 4, dispatchId, debug);
}

// UI annotations for the playground: fields of a scene's own params
// struct tagged with these become widgets in the Controls window
// (reflection carries the attribute arguments to the app).
[__AttributeUsage(_AttributeTargets.Var)]
public struct UiSliderAttribute {
    public float minVal;
    public float maxVal;
    public float step;
    public float defaultVal;
}

[__AttributeUsage(_AttributeTargets.Var)]
public struct UiToggleAttribute {
    public float defaultVal;
}

[__AttributeUsage(_AttributeTargets.Var)]
public struct UiColorAttribute {
    public float r;
    public float g;
    public float b;
}

// Graphics scenes are fullscreen passes: triangle from SV_VertexID, no
// vertex buffers. Usage:
//   [shader("vertex")]
//   VsOut vertMain(uint i : SV_VertexID) {
//       return fullscreen_vertex(i, Uniforms.iResolution.xy);
//   }
// gl_FragCoord mirrors GLSL (pixels, origin bottom-left, y up), so
// Shadertoy/GLSL ports drop in unchanged; the vertex stage then reads
// Uniforms, and the runtime pushes the cbuffer to it automatically.
public struct VsOut {
    public float4 pos : SV_POSITION;
    public float2 uv : TEXCOORD0;
    public float2 gl_FragCoord : TEXCOORD1;
};

public VsOut fullscreen_vertex(uint vertexIndex, float2 resolution) {
    VsOut o;
    float2 p = float2((vertexIndex << 1) & 2, vertexIndex & 2);
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    // Texture uv uses top-left origin; gl_FragCoord follows GLSL with
    // bottom-left origin and pixel coordinates.
    o.uv = float2(p.x, 1.0 - p.y);
    o.gl_FragCoord = p * resolution;
    return o;
}

// Aspect-independent screen coordinates: left/bottom = 0, right/top =
// 1 for every window size and aspect ratio.
public float2 normalized_screen_coord(float2 fragCoord, float3 iResolution) {
    return fragCoord / iResolution.xy;
}

// Standard model-viewer vertex interface. The runtime recognizes this
// stage_in layout and supplies the selected model's interleaved buffer.
public struct ModelVertex {
    public float3 position : POSITION;
    public float3 normal : NORMAL;
    public float2 uv : TEXCOORD0;
};

public struct ModelVaryings {
    public float4 pos : SV_POSITION;
    public float3 normal : TEXCOORD0;
    public float2 uv : TEXCOORD1;
    public float2 ndc : TEXCOORD2;
};

// Handles both runtime draws: fullscreen background (iManual=1) and
// indexed model (iManual=0). Scene shaders only forward their inputs.
public ModelVaryings model_scene_vertex(
    ModelVertex input,
    uint vertexIndex,
    ConstantBuffer<SceneUniforms> uniforms)
{
    ModelVaryings o;
    if (uniforms.iManual > 0.5) {
        float2 p = float2((vertexIndex << 1) & 2, vertexIndex & 2);
        o.pos = float4(p * 2.0 - 1.0, 0.9999, 1.0);
        o.normal = float3(0.0);
        o.uv = float2(0.0);
        o.ndc = p * 2.0 - 1.0;
        return o;
    }

    o.pos = mul(uniforms.iViewProjection, float4(input.position, 1.0));
    o.normal = input.normal;
    o.uv = input.uv;
    o.ndc = float2(0.0);
    return o;
}

// Gizmo helpers: bottom-right axis indicators, opt-in: a scene calls
// one of these with its final color and gets the gizmo composited over
// it. fragCoord is y-up (see frag_coord).

float gizmo_seg_dist(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * t);
}

// 2D gizmo: X (red, right) and Y (green, up) for 2D scenes.
public float3 gizmo2d(float2 fragCoord, float3 iResolution, float3 col) {
    float2 p = fragCoord - float2(iResolution.x - 60.0, 60.0);
    float r = length(p);
    if (r > 45.0) return col;
    float aa = 1.5;
    col = lerp(float3(0.9), col, smoothstep(3.0 - aa, 3.0 + aa, r));
    float dx = gizmo_seg_dist(p, float2(0.0), float2(36.0, 0.0));
    col = lerp(float3(0.85, 0.15, 0.15), col, smoothstep(2.0 - aa, 2.0 + aa, dx));
    float dy = gizmo_seg_dist(p, float2(0.0), float2(0.0, 36.0));
    col = lerp(float3(0.2, 0.8, 0.2), col, smoothstep(2.0 - aa, 2.0 + aa, dy));
    return col;
}

// 3D gizmo: X/Y/Z axes projected orthographically with the orbit
// camera's right/up basis (rotation only, no translation).
public float3 gizmo3d(float2 fragCoord, float3 iResolution, float3 right, float3 up, float3 col) {
    float2 p = fragCoord - float2(iResolution.x - 60.0, 60.0);
    float r = length(p);
    if (r > 45.0) return col;
    float aa = 1.5;
    col = lerp(float3(0.9), col, smoothstep(3.0 - aa, 3.0 + aa, r));
    float3 axes[3] = { float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0) };
    float3 cols[3] = { float3(0.85, 0.15, 0.15), float3(0.2, 0.8, 0.2), float3(0.3, 0.45, 0.95) };
    for (int i = 0; i < 3; i++) {
        float2 proj = float2(dot(axes[i], right), dot(axes[i], up)) * 36.0;
        float d = gizmo_seg_dist(p, float2(0.0), proj);
        col = lerp(cols[i], col, smoothstep(2.0 - aa, 2.0 + aa, d));
    }
    return col;
}

// Resolves the shared background/model branch. The scene computes only
// `modelColor`; skybox sampling and gizmo composition stay hidden here.
public float4 model_scene_fragment(
    ModelVaryings input,
    ConstantBuffer<SceneUniforms> uniforms,
    Texture2D<float4> skyboxTex,
    SamplerState skyboxSampler,
    float3 modelColor)
{
	
    if (uniforms.iManual > 0.5) {
        const float CAMERA_F = 1.2; // must match camera.odin
        float aspect = uniforms.iResolution.x / uniforms.iResolution.y;
        float3 dir = normalize(
            uniforms.iCameraRight * (input.ndc.x * aspect / CAMERA_F) +
            uniforms.iCameraUp * (input.ndc.y / CAMERA_F) +
            uniforms.iCameraForward
        );
        float2 suv = float2(atan2(dir.z, dir.x) / 6.2831853 + 0.5,
                            acos(saturate(dir.y)) / 3.14159265);
        float3 col = skyboxTex.SampleLevel(skyboxSampler, suv, 0).rgb;
        float2 fragCoord = (input.ndc * 0.5 + 0.5) * uniforms.iResolution.xy;
        col = gizmo3d(fragCoord, uniforms.iResolution,
                      uniforms.iCameraRight, uniforms.iCameraUp, col);
        return float4(col, 1.0);
    }
    return float4(modelColor, 1.0);
}

// SDF primitives shared by the apple scenes.

public float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

public float sdEllipse(float2 p, float2 c, float2 r, float rot) {
    float cs = cos(rot);
    float sn = sin(rot);
    float2 q = p - c;
    q = float2(cs * q.x + sn * q.y, -sn * q.x + cs * q.y);
    return (length(q / r) - 1.0) * min(r.x, r.y);
}

// Apple body profile: a circle pinched horizontally at the poles, with a
// stem well pressed into the top and a small dimple at the bottom. Not an
// exact SDF near the dents, close enough for smoothstep fills. apple2
// revolves this profile around the y axis.
public float sdAppleBody(float2 p) {
    float2 q = p;
    q.x /= 1.0 - 0.18 * q.y * q.y;
    float d = length(q) - 0.52;
    d += 0.10 * exp(-40.0 * (p.x * p.x + (p.y - 0.45) * (p.y - 0.45)));
    d += 0.06 * exp(-60.0 * (p.x * p.x + (p.y + 0.50) * (p.y + 0.50)));
    return d;
}
