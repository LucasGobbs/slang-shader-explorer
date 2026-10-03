package main

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// Compiler diagnostics for the editor: parsed from slangc stderr on scene
// build failure. The ImGui editor turns them into squiggles/markers;
// cleared on the next successful build. build_errors_version bumps on every
// change so UI layers can cache.
BuildError :: struct {
	file: string, // shader name relative to src/shaders, no extension ("scenes/apple")
	line: int,    // 1-based, as reported
	col:  int,    // 1-based, as reported
	msg:  string, // the "error[...]" line
}

build_errors: [dynamic]BuildError
build_errors_version: int

build_errors_clear :: proc() {
	for be in build_errors {
		delete(be.file)
		delete(be.msg)
	}
	clear(&build_errors)
}

// slangc error shape:
//   error[E20001]: unexpected token
//     --> src/shaders/scenes/apple.slang:27:1
//
// Binding gotcha (debugged 2026-10-03, apple scene black screen): slang
// assigns Metal texture indices by declaration order and THEN dead-code
// eliminates unused resources. A debug write like
// `out_tex[uv] = float4(float3(1,0,0), 1.0);` doesn't use the sampled
// paper texture, so the sampler is eliminated but out_tex stays at
// [[texture(1)]] — while SDL binds the pass storage texture at Metal
// index 0. Writes land on an unbound texture and are silently discarded
// (black screen, white GPU download, valid-looking MSL). Rule: debug
// writes must still consume the sampled values; samplers first, storage
// after, matching SDL's expectation.
build_errors_parse :: proc(stderr: string) {
	build_errors_clear()
	lines := strings.split_lines(stderr, context.temp_allocator)
	for i := 0; i < len(lines); i += 1 {
		ln := strings.trim_space(lines[i])
		if !strings.has_prefix(ln, "error") do continue
		msg := ln
		for j := i + 1; j < min(i + 4, len(lines)); j += 1 {
			loc := strings.trim_space(lines[j])
			if !strings.has_prefix(loc, "-->") do continue
			ref := strings.trim_space(strings.trim_prefix(loc, "-->"))
			last := strings.last_index(ref, ":")
			if last < 0 do break
			prev := strings.last_index(ref[:last], ":")
			if prev < 0 do break
			col, _ := strconv.parse_int(ref[last + 1:])
			line, _ := strconv.parse_int(ref[prev + 1:])
			path := ref[:prev]
			// Keep the path relative to src/shaders ("scenes/apple").
			rel := path
			if idx := strings.index(rel, "src/shaders/"); idx >= 0 {
				rel = rel[idx + len("src/shaders/"):]
			}
			rel = strings.trim_suffix(rel, ".slang")
			// Canonicalize "scenes/../common" -> "common": slang follows
			// imports and can report the error inside an imported file.
			for {
				dd := strings.index(rel, "/../")
				if dd < 0 do break
				prev := strings.last_index(rel[:dd], "/")
				if prev < 0 {
					rel = rel[dd + 4:]
					break
				}
				rel = strings.concatenate({rel[:prev], rel[dd + 3:]}, context.temp_allocator)
			}
			append(
				&build_errors,
				BuildError {
					file = strings.clone(rel),
					line = line,
					col = col,
					msg = strings.clone(msg),
				},
			)
			break
		}
	}
	build_errors_version += 1
}

// Runtime scene system: a scene is a directory in SCENES_DIR — a small
// unit owning its files: <name>/<name>.slang is the entry shader,
// graph.json the node structure (see imgui_nodes.odin), and any further
// .slang files are scene-owned modules. Adding a directory needs no code
// change: the watcher (scene_poll) generates a goose manifest for the
// found scenes, runs goose-build, and (re)builds pipelines, uniform
// blocks, and UI widgets from slang's reflection JSON. Scenes are data —
// only infra shaders (blit, blit3d, ui) stay compiled into the app.
//
// Conventions for scene shaders:
// - import "../../common" for SceneUniforms, helpers, and the Ui* widget
//   attributes ([UiSlider]/[UiToggle]/[UiColor] on params fields).
// - Compute: [shader("compute")] entry, writes a RWTexture2D<float4>.
// - Graphics: vertMain = common.fullscreen_vertex, pixelMain writes
//   SV_Target0; the pass renders into the same scene texture.
// - If the scene declares samplers, slot 0 gets the selected paper
//   texture.
// - Uniform fields named iResolution/iTime/iFbm/iColorMode/iManual are
//   filled by the app; everything else comes from widgets.

SCENES_DIR :: "src/shaders/scenes"
// Scene artifacts live in their own directory, outside the compiled
// `generated` package: the glue .odin goose emits for scenes is unused
// (pipelines are built from reflection JSON) and two manifests sharing
// one outputDir would clobber each other's common.odin.
GENERATED_DIR :: "src/generated/scenes"
SCENES_MANIFEST :: "src/generated/scenes/manifest.json"

SceneKind :: enum {
	COMPUTE,
	GRAPHICS,
}

// Stage discriminator for reflection parsing (sdl.GPUShaderStage has no
// compute value).
StageKind :: enum {
	COMPUTE,
	VERTEX,
	FRAGMENT,
}

UiWidgetKind :: enum {
	SLIDER,
	TOGGLE,
	COLOR,
}

UiWidget :: struct {
	label:    string,
	buf:      int, // index into RuntimeScene.cbuffers
	offset:   int, // byte offset inside that uniform block
	kind:     UiWidgetKind,
	min:      f32,
	max:      f32,
	step:     f32,
	value:    [3]f32, // SLIDER uses [0], COLOR uses all three
	on:       bool,   // TOGGLE
}

UniformField :: struct {
	name:   string,
	offset: int,
	size:   int,
}

CBuffer :: struct {
	name:         string,
	compute_slot: u32,
	vert_slot:    u32,
	frag_slot:    u32,
	block:        []u8,
	fields:       [dynamic]UniformField,
	in_vert:      bool, // graphics: stage presence (push only where declared)
	in_frag:      bool,
}

RuntimeScene :: struct {
	title:    string,
	source:   string,
	mtime:    time.Time,
	kind:     SceneKind,
	compute:  ^sdl.GPUComputePipeline,
	graphics: ^sdl.GPUGraphicsPipeline,
	thread:   [3]u32,
	entry:    string, // compute entry; graphics entries below
	entry_vert, entry_frag: string,
	cbuffers: [dynamic]CBuffer,
	widgets:  [dynamic]UiWidget,
	// Sampled texture names in sampler-slot order. Bound by name:
	// "paper_tex" gets the selected paper, "skybox_tex" the selected
	// skybox; anything else falls back to paper.
	sampler_textures: [dynamic]string,
	// Model-viewer scenes: the vertex entry takes a [[stage_in]] struct,
	// so the default model (model.odin) is drawn indexed with depth
	// instead of the fullscreen triangle.
	uses_model:   bool,
	vertex_attrs: [dynamic]sdl.GPUVertexAttribute,
}

SceneManager :: struct {
	scenes:  [dynamic]RuntimeScene,
	current: int,
}

// --------------------------------------------------------------------
// JSON navigation helpers (slang reflection schema, defensive lookups)

jget :: proc(v: json.Value, key: string) -> json.Value {
	obj, ok := v.(json.Object)
	if !ok do return nil
	return obj[key]
}

jarr :: proc(v: json.Value) -> []json.Value {
	arr, ok := v.(json.Array)
	if !ok do return nil
	return arr[:]
}

jstr :: proc(v: json.Value) -> string {
	s, ok := v.(json.String)
	if !ok do return ""
	return s
}

jfloat :: proc(v: json.Value) -> f32 {
	#partial switch n in v {
	case json.Float:
		return f32(n)
	case json.Integer:
		return f32(n)
	}
	return 0
}

jint :: proc(v: json.Value) -> int {
	return int(jfloat(v))
}

jkind :: proc(v: json.Value) -> string {
	return jstr(jget(v, "kind"))
}

// --------------------------------------------------------------------
// Reflection parsing

// Counts resources of one parameter list (global scope or one entry
// point) into SDL pipeline counts.
ResourceCounts :: struct {
	samplers:  u32,
	ro_tex:    u32,
	rw_tex:    u32,
	ro_buf:    u32,
	rw_buf:    u32,
	ubuf:      u32,
}

// Returns the stage's "used" flag for a named resource (0 when absent).
entry_binding_used :: proc(entry: json.Value, name: string) -> int {
	for b in jarr(jget(entry, "bindings")) {
		if jstr(jget(b, "name")) == name {
			return jint(jget(jget(b, "binding"), "used"))
		}
	}
	return 0
}

// Resource usage of ONE stage: entryPoints[].bindings carries a per-
// stage "used" flag (global parameters list every module resource).
count_resources :: proc(params: []json.Value, entry: json.Value) -> ResourceCounts {
	c: ResourceCounts
	for b in jarr(jget(entry, "bindings")) {
		binding := jget(b, "binding")
		if jint(jget(binding, "used")) == 0 do continue
		name := jstr(jget(b, "name"))

		// Look the parameter up for access/type details.
		access := ""
		tk := ""
		for p in params {
			if jstr(jget(p, "name")) != name do continue
			access = jstr(jget(p, "access"))
			if access == "" do access = jstr(jget(jget(p, "type"), "access"))
			tk = jkind(jget(p, "type"))
			break
		}
		is_buffer := strings.contains(tk, "tructuredBuffer")

		switch jkind(binding) {
		case "samplerState":
			c.samplers += 1
		case "constantBuffer":
			// Raw MSL keeps original buffer indices. Gaps count: a sole
			// buffer(1) requires num_uniform_buffers=2 and push slot 1.
			c.ubuf = max(c.ubuf, u32(jint(jget(binding, "index")) + 1))
		case "shaderResource":
			read_write := access == "readWrite"
			if is_buffer {
				if read_write {
					c.rw_buf += 1
				} else {
					c.ro_buf += 1
				}
			} else {
				if read_write {
					c.rw_tex += 1
				} else {
					c.ro_tex += 1
				}
			}
		}
	}
	// A Texture2D read through a SamplerState is a SAMPLED texture in SDL
	// terms, not a readonly storage texture: slang pairs texture index i
	// with sampler index i, so the first `samplers` readonly textures are
	// sampled and must not be counted as storage.
	c.ro_tex -= min(c.ro_tex, c.samplers)
	return c
}

// Merges the constant buffers of one stage's reflection into the scene:
// same-name cbuffers from the other stage unify, with stage presence
// taken from the entry point's used bindings so graphics pushes only
// where the block is used.
parse_cbuffers :: proc(
	scene: ^RuntimeScene,
	params: []json.Value,
	entry: json.Value,
	stage: StageKind,
) {
	for p in params {
		binding := jget(p, "binding")
		if jkind(binding) != "constantBuffer" do continue
		name := jstr(jget(p, "name"))
		if entry_binding_used(entry, name) == 0 do continue
		cb: ^CBuffer
		for &existing in scene.cbuffers {
			if existing.name == name {
				cb = &existing
				break
			}
		}
		if cb == nil {
			append(&scene.cbuffers, CBuffer {
				name = strings.clone(name),
			})
			cb = &scene.cbuffers[len(scene.cbuffers) - 1]

			fields := jarr(jget(jget(jget(jget(p, "type"), "elementVarLayout"), "type"), "fields"))
			size := 0
			for f in fields {
				fbinding := jget(f, "binding")
				field := UniformField {
					name   = strings.clone(jstr(jget(f, "name"))),
					offset = jint(jget(fbinding, "offset")),
					size   = jint(jget(fbinding, "size")),
				}
				append(&cb.fields, field)
				size = max(size, field.offset + field.size)

				// Widget attributes ([UiSlider]/[UiToggle]/[UiColor]).
				for attr in jarr(jget(f, "userAttribs")) {
					args := jarr(jget(attr, "arguments"))
					w := UiWidget {
						label  = field.name,
						buf    = len(scene.cbuffers) - 1,
						offset = field.offset,
					}
					switch jstr(jget(attr, "name")) {
					case "UiSlider":
						w.kind = .SLIDER
						if len(args) >= 4 {
							w.min = jfloat(args[0])
							w.max = jfloat(args[1])
							w.step = jfloat(args[2])
							w.value[0] = jfloat(args[3])
						}
						append(&scene.widgets, w)
					case "UiToggle":
						w.kind = .TOGGLE
						if len(args) >= 1 do w.on = jfloat(args[0]) != 0
						append(&scene.widgets, w)
					case "UiColor":
						w.kind = .COLOR
						w.value = {1, 1, 1}
						if len(args) >= 3 {
							w.value = {jfloat(args[0]), jfloat(args[1]), jfloat(args[2])}
						}
						append(&scene.widgets, w)
					}
				}
			}
			// std140 rounds the block to a multiple of 16.
			cb.block = make([]u8, (size + 15) &~ 15)
		}
		slot := u32(jint(jget(binding, "index")))
		#partial switch stage {
		case .COMPUTE:
			cb.compute_slot = slot
		case .VERTEX:
			cb.in_vert = true
			cb.vert_slot = slot
		case .FRAGMENT:
			cb.in_frag = true
			cb.frag_slot = slot
		}
	}
}

// Parses one per-stage reflection file (<name>.<stage>.msl.refl.json):
// resource counts (used-marked), entry point name, thread count, and
// cbuffers/widgets merged into the scene.
scene_parse_stage_refl :: proc(
	scene: ^RuntimeScene,
	path: string,
	stage: StageKind,
) -> (counts: ResourceCounts, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("scene %s: failed to read %s", scene.title, path)
		return {}, false
	}
	root, parse_err := json.parse(data)
	if parse_err != nil {
		fmt.eprintfln("scene %s: failed to parse %s: %v", scene.title, path, parse_err)
		return {}, false
	}

	entry: json.Value
	for e in jarr(jget(root, "entryPoints")) {
		if entry == nil do entry = e
		#partial switch stage {
		case .COMPUTE:
			scene.entry = strings.clone(jstr(jget(e, "name")))
			tg := jarr(jget(e, "threadGroupSize"))
			if len(tg) == 3 {
				scene.thread = {u32(jint(tg[0])), u32(jint(tg[1])), u32(jint(tg[2]))}
			}
		case .VERTEX:
			scene.entry_vert = strings.clone(jstr(jget(e, "name")))
			// A [[stage_in]] struct means the scene wants the default
			// model drawn indexed (attribute offsets come from the fixed
			// model layout, keyed by attribute location).
			for p in jarr(jget(e, "parameters")) {
				if jkind(jget(p, "binding")) != "varyingInput" do continue
				for f in jarr(jget(jget(p, "type"), "fields")) {
					location := jint(jget(jget(f, "binding"), "index"))
					offset, ok := model_attr_offset(location)
					if !ok {
						fmt.eprintfln(
							"scene %s: model vertex attribute %s has unsupported location %d",
							scene.title, jstr(jget(f, "name")), location,
						)
						continue
					}
					format: sdl.GPUVertexElementFormat
					switch jint(jget(jget(f, "type"), "elementCount")) {
					case 1:
						format = .FLOAT
					case 2:
						format = .FLOAT2
					case 3:
						format = .FLOAT3
					case 4:
						format = .FLOAT4
					case:
						continue
					}
					append(&scene.vertex_attrs, sdl.GPUVertexAttribute {
						location    = u32(location),
						buffer_slot = 0,
						format      = format,
						offset      = offset,
					})
				}
				if len(scene.vertex_attrs) > 0 do scene.uses_model = true
			}
		case .FRAGMENT:
			scene.entry_frag = strings.clone(jstr(jget(e, "name")))
		}
	}
	if scene.thread == {} do scene.thread = {8, 8, 1}

	params := jarr(jget(root, "parameters"))
	counts = count_resources(params, entry)
	parse_cbuffers(scene, params, entry, stage)

	// Sampled textures in sampler-slot order (compute and fragment
	// stages): slang pairs the i-th sampled texture with the i-th
	// sampler by binding index.
	if stage != .VERTEX {
		for b in jarr(jget(entry, "bindings")) {
			binding := jget(b, "binding")
			if jkind(binding) != "samplerState" || jint(jget(binding, "used")) == 0 do continue
			slot := jint(jget(binding, "index"))
			for tb in jarr(jget(entry, "bindings")) {
				tbinding := jget(tb, "binding")
				if jkind(tbinding) != "shaderResource" do continue
				if jint(jget(tbinding, "index")) != slot || jint(jget(tbinding, "used")) == 0 do continue
				for len(scene.sampler_textures) <= slot {
					append(&scene.sampler_textures, "")
				}
				scene.sampler_textures[slot] = strings.clone(jstr(jget(tb, "name")))
			}
		}
	}
	return counts, true
}

scene_parse_reflection :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) -> bool {
	compute_refl := fmt.tprintf("%s/%s.compute.msl.refl.json", GENERATED_DIR, scene.title)
	vert_refl := fmt.tprintf("%s/%s.vert.msl.refl.json", GENERATED_DIR, scene.title)
	frag_refl := fmt.tprintf("%s/%s.frag.msl.refl.json", GENERATED_DIR, scene.title)

	if os.exists(compute_refl) {
		scene.kind = .COMPUTE
		counts, ok := scene_parse_stage_refl(scene, compute_refl, .COMPUTE)
		if !ok do return false
		scene.compute = create_compute_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.compute.msl", GENERATED_DIR, scene.title),
			scene.entry,
			counts,
			scene.thread,
		)
		return scene.compute != nil
	}

	if os.exists(vert_refl) && os.exists(frag_refl) {
		scene.kind = .GRAPHICS
		vc, okv := scene_parse_stage_refl(scene, vert_refl, .VERTEX)
		fc, okf := scene_parse_stage_refl(scene, frag_refl, .FRAGMENT)
		if !okv || !okf do return false
		scene.graphics = create_graphics_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.vert.msl", GENERATED_DIR, scene.title),
			fmt.tprintf("%s/%s.frag.msl", GENERATED_DIR, scene.title),
			scene.entry_vert,
			scene.entry_frag,
			vc,
			fc,
			scene,
		)
		return scene.graphics != nil
	}

	fmt.eprintfln("scene %s: no reflection artifacts found", scene.title)
	return false
}

// --------------------------------------------------------------------
// Pipeline creation from reflection counts (no compiled glue)

create_shader_raw :: proc(
	gpu: ^sdl.GPUDevice,
	path: string,
	entrypoint: string,
	stage: sdl.GPUShaderStage,
	c: ResourceCounts,
) -> ^sdl.GPUShader {
	blob, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("scene: failed to read %s", path)
		return nil
	}
	shader := sdl.CreateGPUShader(
		gpu,
		{
			stage = stage,
			format = {.MSL},
			code_size = len(blob),
			code = raw_data(blob),
			entrypoint = strings.clone_to_cstring(entrypoint, context.temp_allocator),
			num_samplers = c.samplers,
			num_uniform_buffers = c.ubuf,
			num_storage_buffers = c.rw_buf,
			num_storage_textures = c.rw_tex,
		},
	)
	if shader == nil {
		fmt.eprintfln("scene: failed to create shader from %s: %s", path, sdl.GetError())
	}
	return shader
}

create_compute_pipeline_raw :: proc(
	gpu: ^sdl.GPUDevice,
	msl_path: string,
	entrypoint: string,
	c: ResourceCounts,
	thread: [3]u32,
) -> ^sdl.GPUComputePipeline {
	blob, err := os.read_entire_file(msl_path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("scene: failed to read %s", msl_path)
		return nil
	}
	pipeline := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = raw_data(blob),
			code_size = len(blob),
			entrypoint = strings.clone_to_cstring(entrypoint, context.temp_allocator),
			format = {.MSL},
			num_samplers = c.samplers,
			num_readonly_storage_textures = c.ro_tex,
			num_readonly_storage_buffers = c.ro_buf,
			num_readwrite_storage_textures = c.rw_tex,
			num_readwrite_storage_buffers = c.rw_buf,
			num_uniform_buffers = c.ubuf,
			threadcount_x = thread.x,
			threadcount_y = thread.y,
			threadcount_z = thread.z,
		},
	)
	if pipeline == nil {
		fmt.eprintfln("scene: failed to create compute pipeline %s: %s", msl_path, sdl.GetError())
	}
	return pipeline
}

create_graphics_pipeline_raw :: proc(
	gpu: ^sdl.GPUDevice,
	vert_path, frag_path: string,
	entry_vert, entry_frag: string,
	vc, fc: ResourceCounts,
	scene: ^RuntimeScene,
) -> ^sdl.GPUGraphicsPipeline {
	vs := create_shader_raw(gpu, vert_path, entry_vert, .VERTEX, vc)
	if vs == nil do return nil
	defer sdl.ReleaseGPUShader(gpu, vs)
	fs := create_shader_raw(gpu, frag_path, entry_frag, .FRAGMENT, fc)
	if fs == nil do return nil
	defer sdl.ReleaseGPUShader(gpu, fs)

	create_info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vs,
		fragment_shader = fs,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {
			fill_mode  = .FILL,
			cull_mode  = .BACK,
			front_face = .COUNTER_CLOCKWISE,
		},
		target_info = {
			num_color_targets = 1,
			color_target_descriptions = &(sdl.GPUColorTargetDescription {
					format = .R8G8B8A8_UNORM, // the scene texture
				}),
		},
	}
	if scene.uses_model {
		// Model draw: interleaved vertex buffer at slot 0, depth-tested.
		create_info.vertex_input_state = {
			num_vertex_buffers = 1,
			vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
				slot = 0,
				pitch = MODEL_PITCH,
				input_rate = .VERTEX,
			}),
			num_vertex_attributes = u32(len(scene.vertex_attrs)),
			vertex_attributes = raw_data(scene.vertex_attrs),
		}
		create_info.target_info.depth_stencil_format = .D32_FLOAT
		create_info.depth_stencil_state = {
			compare_op = .LESS,
			enable_depth_test = true,
			enable_depth_write = true,
		}
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(gpu, create_info)
	if pipeline == nil {
		fmt.eprintfln("scene: failed to link graphics pipeline: %s", sdl.GetError())
	}
	return pipeline
}

// --------------------------------------------------------------------
// Discovery + goose orchestration

// A scene is a directory under SCENES_DIR: <name>/<name>.slang is the
// entry shader, graph.json its node structure, and any extra .slang files
// are scene-owned modules. This is the entry path for a scene name.
scene_entry_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, name, name)
}

scene_names_on_disk :: proc() -> [dynamic]string {
	names: [dynamic]string
	entries, err := os.read_directory_by_path(SCENES_DIR, 0, context.temp_allocator)
	if err != nil do return names
	for entry in entries {
		if entry.type != .Directory do continue
		if !os.exists(scene_entry_path(entry.name)) do continue
		append(&names, strings.clone(entry.name))
	}
	slice.sort(names[:])
	return names
}

// Writes a goose manifest for the given scenes and runs goose-build so
// their artifacts (msl + refl.json) exist and are fresh.
scenes_build :: proc(names: []string) -> bool {
	os.make_directory(GENERATED_DIR) // fine if it already exists
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"outputDir":"`)
	strings.write_string(&sb, GENERATED_DIR)
	strings.write_string(&sb, `","parameterOutputDir":"`)
	strings.write_string(&sb, GENERATED_DIR)
	strings.write_string(&sb, `",`)
	strings.write_string(&sb, `"package":"generated","gooseImport":"../../../goose/src",`)
	strings.write_string(&sb, `"commonUniforms":true,"targets":["metal"],"shaders":[`)
	for name, i in names {
		if i > 0 do strings.write_string(&sb, ",")
		// No fmt here: Odin's fmt treats '{' as a directive.
		strings.write_string(&sb, `{"name":"`)
		strings.write_string(&sb, name)
		strings.write_string(&sb, `","source":"`)
		strings.write_string(&sb, SCENES_DIR)
		strings.write_string(&sb, `/`)
		strings.write_string(&sb, name)
		strings.write_string(&sb, `/`)
		strings.write_string(&sb, name)
		strings.write_string(&sb, `.slang"}`)
	}
	strings.write_string(&sb, `]}`)
	if os.write_entire_file(SCENES_MANIFEST, transmute([]u8)strings.to_string(sb)) != nil {
		fmt.eprintfln("scenes: failed to write %s", SCENES_MANIFEST)
		return false
	}

	goose_bin := os.get_env("GOOSE", context.temp_allocator)
	if goose_bin == "" do goose_bin = "../goose/goose-build"
	slang := os.get_env("SLANG", context.temp_allocator)
	if slang == "" do slang = "vendor/slang/bin/slangc"
	command := []string{goose_bin, "--manifest", SCENES_MANIFEST, "--slang", slang}
	state, stdout, stderr, process_error := os.process_exec({command = command}, context.temp_allocator)
	if process_error != nil {
		fmt.eprintfln("scenes: failed to run goose-build: %v", process_error)
		return false
	}
	if !state.success {
		if len(stderr) > 0 {
			fmt.eprint(string(stderr))
			build_errors_parse(string(stderr))
		}
		fmt.eprintln("scenes: goose-build failed; keeping previous scene pipelines")
		return false
	}
	if len(build_errors) > 0 {
		build_errors_clear()
		build_errors_version += 1
	}
	return true
}

scene_release :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) {
	if scene.compute != nil do sdl.ReleaseGPUComputePipeline(gpu, scene.compute)
	if scene.graphics != nil do sdl.ReleaseGPUGraphicsPipeline(gpu, scene.graphics)
	for cb in scene.cbuffers do delete(cb.block)
	delete(scene.cbuffers)
	delete(scene.widgets)
	delete(scene.sampler_textures)
	delete(scene.vertex_attrs)
}

// Loads a scene into `out`; on failure `out` is cleaned up and false is
// returned, so callers can keep a previous working version in place
// (e.g. artifacts corrupted by a concurrent instance or a slang error).
scene_load_into :: proc(gpu: ^sdl.GPUDevice, name: string, out: ^RuntimeScene) -> bool {
	out^ = RuntimeScene {
		title  = strings.clone(name),
		source = scene_entry_path(name),
	}
	info, stat_err := os.stat(out.source, context.temp_allocator)
	if stat_err != nil do return false
	out.mtime = info.modification_time

	if !scene_parse_reflection(gpu, out) {
		scene_release(gpu, out)
		return false
	}
	return true
}

scene_load :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, name: string) -> bool {
	scene: RuntimeScene
	if !scene_load_into(gpu, name, &scene) do return false
	append(&sm.scenes, scene)
	return true
}

// Full scan: (re)builds artifacts for every scene on disk and reloads
// only what changed. Preserves the current scene by title.
scene_rescan :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice) {
	names := scene_names_on_disk()
	if len(names) == 0 do return
	scenes_build(names[:]) // depfile-incremental; failures keep old pipelines

	current_title := sm.scenes[sm.current].title if len(sm.scenes) > 0 else ""

	// Drop removed scenes.
	for i := len(sm.scenes) - 1; i >= 0; i -= 1 {
		found := false
		for name in names do if sm.scenes[i].title == name { found = true; break }
		if !found {
			scene_release(gpu, &sm.scenes[i])
			ordered_remove(&sm.scenes, i)
		}
	}

	// Add new, reload changed. A scene that fails to reload keeps its
	// previous working version in place.
	for name in names {
		source := scene_entry_path(name)
		info, stat_err := os.stat(source, context.temp_allocator)
		if stat_err != nil do continue
		idx := -1
		for &s, i in sm.scenes do if s.title == name { idx = i; break }
		if idx >= 0 && sm.scenes[idx].mtime == info.modification_time do continue
		if idx >= 0 {
			candidate: RuntimeScene
			if scene_load_into(gpu, name, &candidate) {
				scene_release(gpu, &sm.scenes[idx])
				ordered_remove(&sm.scenes, idx)
				inject_at(&sm.scenes, idx, candidate)
			}
		} else {
			scene_load(sm, gpu, name)
		}
	}

	// Restore selection.
	sm.current = 0
	if current_title != "" {
		for &s, i in sm.scenes do if s.title == current_title { sm.current = i; break }
	}
}

scene_poll :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice) {
	// Cheap change check: any new/removed file or mtime bump.
	names := scene_names_on_disk()
	changed := len(names) != len(sm.scenes)
	if !changed {
		outer: for name in names {
			for &s in sm.scenes {
				if s.title == name {
					info, stat_err := os.stat(s.source, context.temp_allocator)
					if stat_err != nil || info.modification_time != s.mtime do changed = true
					continue outer
				}
			}
			changed = true
		}
	}
	// common.slang is an implicit dependency of every scene; its mtime
	// bump forces a full reload (goose depfiles track it per scene).
	if !changed {
		info, stat_err := os.stat("src/shaders/common.slang", context.temp_allocator)
		if stat_err == nil && info.modification_time != common_mtime {
			changed = true
			common_mtime = info.modification_time
		}
	}
	if changed do scene_rescan(sm, gpu)
}

common_mtime: time.Time

// --------------------------------------------------------------------
// Per-frame uniform filling

poke_f32 :: proc(block: []u8, offset: int, v: f32) {
	if offset < 0 || offset + 4 > len(block) do return
	(^f32)(rawptr(&block[offset]))^ = v
}

// Writes the iManual uniform field directly (background/model draw
// switching for model-viewer scenes).
scene_set_manual :: proc(scene: ^RuntimeScene, v: f32) {
	for cb in scene.cbuffers {
		for f in cb.fields {
			if f.name == "iManual" {
				poke_f32(cb.block, f.offset, v)
			}
		}
	}
}

// --------------------------------------------------------------------
// Frame submission

GIF_SECONDS :: 5.0
GIF_FPS :: 17
GIF_DIR :: "/tmp/inktober_gif"

// Everything submit_scene_frame needs beyond the scene itself, loaded
// once at startup: shared textures (paper/skybox), the default model,
// and the depth buffer for model-viewer scenes.
SceneResources :: struct {
	depth_tex:       ^sdl.GPUTexture,
	sampler:         ^sdl.GPUSampler,
	paper_textures:  []^sdl.GPUTexture,
	paper_index:     int,
	skybox_textures: []^sdl.GPUTexture,
	skybox_index:    int, // -1 = none
	model:           ^Model,
}

push_scene_uniforms :: proc(cmd: ^sdl.GPUCommandBuffer, scene: ^RuntimeScene, compute: bool) {
	for cb in scene.cbuffers {
		if compute {
			sdl.PushGPUComputeUniformData(cmd, cb.compute_slot, raw_data(cb.block), u32(len(cb.block)))
			continue
		}
		if cb.in_vert {
			sdl.PushGPUVertexUniformData(cmd, cb.vert_slot, raw_data(cb.block), u32(len(cb.block)))
		}
		if cb.in_frag {
			sdl.PushGPUFragmentUniformData(cmd, cb.frag_slot, raw_data(cb.block), u32(len(cb.block)))
		}
	}
}

// Submits one frame of the scene into scene_tex and returns the fence.
// Compute scenes run a compute pass writing the texture; graphics scenes
// run a render pass into it (fullscreen triangle, or the default model
// drawn indexed when the vertex entry takes a stage_in struct).
submit_scene_frame :: proc(
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	width, height: i32,
) -> ^sdl.GPUFence {
	cmd := sdl.AcquireGPUCommandBuffer(gpu)

	// Sampled textures, bound by name (see sampler_textures): the
	// selected paper everywhere except skybox_tex.
	n := len(scene.sampler_textures)
	bindings := make([]sdl.GPUTextureSamplerBinding, max(n, 1), context.temp_allocator)
	for name, i in scene.sampler_textures {
		tex := res.paper_textures[res.paper_index]
		if name == "skybox_tex" &&
		   res.skybox_index >= 0 &&
		   res.skybox_index < len(res.skybox_textures) {
			tex = res.skybox_textures[res.skybox_index]
		}
		bindings[i] = {texture = tex, sampler = res.sampler}
	}

	switch scene.kind {
	case .COMPUTE:
		tex_binding := sdl.GPUStorageTextureReadWriteBinding {
			texture = scene_tex,
			cycle   = false,
		}
		compute_pass := sdl.BeginGPUComputePass(cmd, &tex_binding, 1, nil, 0)
		sdl.BindGPUComputePipeline(compute_pass, scene.compute)
		if n > 0 {
			sdl.BindGPUComputeSamplers(compute_pass, 0, raw_data(bindings), u32(n))
		}
		push_scene_uniforms(cmd, scene, true)
		tx, ty := i32(scene.thread.x), i32(scene.thread.y)
		sdl.DispatchGPUCompute(
			compute_pass,
			u32((width + tx - 1) / tx),
			u32((height + ty - 1) / ty),
			1,
		)
		sdl.EndGPUComputePass(compute_pass)
	case .GRAPHICS:
		color_target := sdl.GPUColorTargetInfo {
			texture     = scene_tex,
			load_op     = .CLEAR,
			clear_color = {0, 0, 0, 1},
			store_op    = .STORE,
		}
		if scene.uses_model {
			// Paper-ish backdrop behind the depth-tested model.
			color_target.clear_color = {0.93, 0.91, 0.86, 1}
		}
		depth_target := sdl.GPUDepthStencilTargetInfo {
			texture     = res.depth_tex,
			load_op     = .CLEAR,
			clear_depth = 1.0,
			store_op    = .DONT_CARE,
		}
		render_pass := sdl.BeginGPURenderPass(
			cmd,
			&color_target,
			1,
			scene.uses_model ? &depth_target : nil,
		)
		sdl.BindGPUGraphicsPipeline(render_pass, scene.graphics)
		if n > 0 {
			sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings), u32(n))
		}
		if scene.uses_model {
			// Model-viewer scenes draw twice with the same pipeline:
			// first a fullscreen background pass (iManual = 1), then the
			// depth-tested model (iManual = 0). The vertex buffer stays
			// bound for the stage_in fetch in both draws.
			vb_binding := sdl.GPUBufferBinding{buffer = res.model.vb, offset = 0}
			sdl.BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1)
			sdl.BindGPUIndexBuffer(
				render_pass,
				{buffer = res.model.ib, offset = 0},
				._32BIT,
			)

			scene_set_manual(scene, 1)
			push_scene_uniforms(cmd, scene, false)
			sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)

			scene_set_manual(scene, 0)
			push_scene_uniforms(cmd, scene, false)
			sdl.DrawGPUIndexedPrimitives(render_pass, res.model.index_count, 1, 0, 0, 0)
		} else {
			push_scene_uniforms(cmd, scene, false)
			sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
		}
		sdl.EndGPURenderPass(render_pass)
	}
	return sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
}

// GIF export (UI "export gif" button): re-renders the active scene at
// GIF_FPS from t=0 to t=GIF_SECONDS, writes each frame as
// /tmp/inktober_gif/frame_NNN.png, then runs the two-pass ffmpeg
// palettegen/paletteuse pipeline to produce exports/<scene>_<datetime>.gif.
// Blocking: the window freezes for the few seconds this takes.
export_gif :: proc(
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	width, height: i32,
	color: bool,
) {
	frames := int(GIF_SECONDS * GIF_FPS)
	os.make_directory(GIF_DIR) // fine if it already exists

	for i in 0 ..< frames {
		time_s := f32(i) / GIF_FPS
		camera := camera_orbit(time_s * 0.4, 0.55, f32(width) / f32(height))
		scene_write_uniforms(
			scene,
			{f32(width), f32(height)},
			time_s,
			color,
			{0, 0}, // no mouse in exports
			false,
			&camera,
		)

		fence := submit_scene_frame(gpu, scene, scene_tex, res, width, height)
		if fence != nil do sdl.ReleaseGPUFence(gpu, fence)

		path := fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)
		if !save_texture_png(gpu, scene_tex, width, height, path) {
			fmt.eprintfln("gif export: failed to write %s", path)
			return
		}
		fmt.printfln("gif frame %d/%d", i + 1, frames)
	}

	out_path := export_path(scene.title, "gif")
	palette := fmt.tprintf("%s/palette.png", GIF_DIR)
	filters :: "fps=17,scale=480:-1:flags=lanczos"
	// %% escapes fmt's % so ffmpeg's frame_%03d.png pattern survives.
	cmdline := fmt.tprintf(
		`ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -vf "%s,palettegen" -y %s` +
		` && ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -i %s` +
		` -lavfi "%s [x]; [x][1:v] paletteuse" -y %s`,
		GIF_DIR,
		filters,
		palette,
		GIF_DIR,
		palette,
		filters,
		out_path,
	)
	status := libc.system(strings.clone_to_cstring(cmdline, context.temp_allocator))
	if status == 0 {
		fmt.printfln("saved %s", out_path)
	} else {
		fmt.eprintfln("gif export: ffmpeg exited with status %d", status)
	}
}

scene_write_uniforms :: proc(
	scene: ^RuntimeScene,
	res: [2]f32,
	time_s: f32,
	color: bool,
	mouse_pos: [2]f32,
	mouse_click: bool,
	camera: ^CameraUniforms,
) {
	for cb in scene.cbuffers {
		for f in cb.fields {
			switch f.name {
			case "iResolution":
				poke_f32(cb.block, f.offset, res.x)
				poke_f32(cb.block, f.offset + 4, res.y)
				poke_f32(cb.block, f.offset + 8, 1)
			case "iTime":
				poke_f32(cb.block, f.offset, time_s)
			case "iFbm":
				poke_f32(cb.block, f.offset, 6)
				poke_f32(cb.block, f.offset + 4, 2.03)
				poke_f32(cb.block, f.offset + 8, 0.5)
			case "iColorMode":
				poke_f32(cb.block, f.offset, color ? 1 : 0)
			case "iMousePos":
				poke_f32(cb.block, f.offset, mouse_pos.x)
				poke_f32(cb.block, f.offset + 4, mouse_pos.y)
			case "iMouseClick":
				poke_f32(cb.block, f.offset, mouse_click ? 1 : 0)
			case "iViewProjection":
				for i in 0 ..< 16 do poke_f32(cb.block, f.offset + i*4, camera.view_projection[i])
			case "iCameraPosition":
				for i in 0 ..< 3 do poke_f32(cb.block, f.offset + i*4, camera.position[i])
			case "iCameraRight":
				for i in 0 ..< 3 do poke_f32(cb.block, f.offset + i*4, camera.right[i])
			case "iCameraUp":
				for i in 0 ..< 3 do poke_f32(cb.block, f.offset + i*4, camera.up[i])
			case "iCameraForward":
				for i in 0 ..< 3 do poke_f32(cb.block, f.offset + i*4, camera.forward[i])
			case "iManual":
				poke_f32(cb.block, f.offset, 1)
			}
		}
	}
	for w in scene.widgets {
		if len(scene.cbuffers) <= w.buf do continue
		block := scene.cbuffers[w.buf].block
		switch w.kind {
		case .SLIDER:
			poke_f32(block, w.offset, w.value[0])
		case .TOGGLE:
			poke_f32(block, w.offset, w.on ? 1 : 0)
		case .COLOR:
			poke_f32(block, w.offset, w.value[0])
			poke_f32(block, w.offset + 4, w.value[1])
			poke_f32(block, w.offset + 8, w.value[2])
		}
	}
}
