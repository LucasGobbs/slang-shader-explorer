package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// Scene templates for the toolbar's "+ new" menu. A new file lands in
// SCENES_DIR; the scene watcher discovers it on the next frame, compiles
// it, and lists it — no code change or restart needed. Names auto-increment
// (compute.slang, compute_2.slang, ...) so repeated clicks never clobber.

SceneTemplateKind :: enum {
	COMPUTE,
	GRAPHICS_2D,
	GRAPHICS_3D,
}

TEMPLATE_COMPUTE :: `// New compute scene: one thread per pixel writing out_tex.
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
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    out_tex[id.xy] = float4(float3(v), 1.0);
}
`

TEMPLATE_GRAPHICS_2D :: `// New 2D graphics scene: fullscreen triangle, per-pixel fragment.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 p = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    return float4(float3(v), 1.0);
}
`

TEMPLATE_GRAPHICS_3D :: `// New 3D graphics scene: renders the loaded model with wrapped diffuse.
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
    float3 L = normalize(float3(0.5, 0.8, -0.6));
    float dif = 0.35 + 0.65 * saturate(dot(n, L));
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, float3(0.7) * dif);
}
`

template_base_name :: proc(kind: SceneTemplateKind) -> string {
	switch kind {
	case .COMPUTE:     return "compute"
	case .GRAPHICS_2D: return "graphics2d"
	case .GRAPHICS_3D: return "graphics3d"
	}
	return "scene"
}

template_source :: proc(kind: SceneTemplateKind) -> string {
	switch kind {
	case .COMPUTE:     return TEMPLATE_COMPUTE
	case .GRAPHICS_2D: return TEMPLATE_GRAPHICS_2D
	case .GRAPHICS_3D: return TEMPLATE_GRAPHICS_3D
	}
	return ""
}

// Creates a scene unit (directory with the entry shader) at the first
// free name under SCENES_DIR and returns the scene title for follow-up
// selection.
scene_create :: proc(kind: SceneTemplateKind) -> (title: string, ok: bool) {
	base := template_base_name(kind)
	source := template_source(kind)
	for n := 1; n < 100; n += 1 {
		name := base
		if n > 1 {
			name = fmt.tprintf("%s_%d", base, n)
		}
		dir := fmt.tprintf("%s/%s", SCENES_DIR, name)
		if os.exists(dir) do continue
		if os.make_directory(dir) != nil {
			log.errorf("new scene: failed to create %s", dir)
			return "", false
		}
		path := fmt.tprintf("%s/%s.slang", dir, name)
		if os.write_entire_file(path, transmute([]u8)source) != nil {
			log.errorf("new scene: failed to write %s", path)
			return "", false
		}
		log.infof("new scene: created %s", path)
		return strings.clone(name), true
	}
	return "", false
}
