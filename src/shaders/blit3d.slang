// 3D heightfield view: renders the offscreen texture as a displaced mesh
// instead of the flat blit. A procedural 256x256 grid (no vertex buffers)
// reads the scene texture's .r channel as height, drapes the texture's
// color, and shades with screen-space derivative normals (dpdx/dpdy).

struct CameraUniforms {
    float3 camPos;
    float aspect;
    float3 fwd;
    float fovTan;
    float3 right;
    float nearZ;
    float3 up;
    float farZ;
}

[[vk::binding(0, 0)]]
ConstantBuffer<CameraUniforms> Camera;

[[vk::binding(1, 0)]]
Texture2D<float4> tex;

[[vk::binding(2, 0)]]
SamplerState tex_sampler;

static const uint GRID = 256;
static const float HEIGHT_SCALE = 0.35;

struct VsOut {
    float4 pos : SV_POSITION;
    float3 world : TEXCOORD0;
    float3 color : TEXCOORD1;
};

[shader("vertex")]
VsOut vertMain(uint vid : SV_VertexID) {
    VsOut o;
    uint cell = vid / 6;
    uint corner = vid % 6;
    let offs = uint2[6](
        uint2(0, 0), uint2(1, 0), uint2(0, 1),
        uint2(0, 1), uint2(1, 0), uint2(1, 1)
    );
    uint2 quad = uint2(cell % GRID, cell / GRID) + offs[corner];
    float2 uv = float2(quad) / float(GRID);
    float4 sample = tex.SampleLevel(tex_sampler, uv, 0.0);

    float3 world = float3(uv.x * 2.0 - 1.0, sample.r * HEIGHT_SCALE, uv.y * 2.0 - 1.0);

    float3 rel = world - Camera.camPos;
    float z = dot(rel, Camera.fwd);
    float x = dot(rel, Camera.right);
    float y = dot(rel, Camera.up);
    float zc = clamp((z - Camera.nearZ) / (Camera.farZ - Camera.nearZ), 0.0, 1.0);

    o.pos = float4(x / (Camera.aspect * Camera.fovTan), y / Camera.fovTan, zc, z);
    o.world = world;
    o.color = sample.rgb;
    return o;
}

[shader("fragment")]
float4 pixelMain(VsOut i) : SV_Target0 {
    // Screen-space derivative normal: exact for the rasterized triangles,
    // free on top of the color fetch.
    float3 n = normalize(cross(ddx(i.world), ddy(i.world)));
    float diff = max(0.0, dot(n, normalize(float3(0.5, 0.8, 0.3))));
    return float4(i.color * (0.35 + 0.65 * diff), 1.0);
}
