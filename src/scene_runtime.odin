package main

import "base:runtime"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
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
build_success_version: int

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
// [[texture(1)]], while SDL binds the pass storage texture at Metal
// index 0. Writes land on an unbound texture and are silently discarded
// (black screen, white GPU download, valid-looking MSL). Rule: debug
// writes must still consume the sampled values; samplers first, storage
// after, matching SDL's expectation.
build_errors_parse :: proc(stderr: string) {
	// Runs on the scene build worker: the editor reads build_errors on the
	// main thread under the same mutex.
	sync.mutex_lock(&scene_build_mu)
	defer sync.mutex_unlock(&scene_build_mu)
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

// Runtime scene system: a scene is a directory in SCENES_DIR: a small
// unit owning its files: <name>/<name>.slang is the entry shader,
// graph.json the node structure (see imgui_nodes.odin), and any further
// .slang files are scene-owned modules. Adding a directory needs no code
// change: the watcher (scene_poll) generates a goose manifest for the
// found scenes, runs goose-build, and (re)builds pipelines, uniform
// blocks, and UI widgets from slang's reflection JSON. Scenes are data:
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

// One render pass of a scene: the entry shader plus every scene-owned
// module (pass_1.slang, pass_2.slang, ...), executed in order. A pass
// after the first samples the previous pass's frame through a texture
// named "input_tex".
ScenePass :: struct {
	name:     string, // artifact base in GENERATED_DIR (scene title or "title__mod")
	graph_key: string, // stable graph.json node key
	kind:     SceneKind,
	compute:  ^sdl.GPUComputePipeline,
	graphics: ^sdl.GPUGraphicsPipeline,
	thread:   [3]u32,
	entry:    string, // compute entry; graphics entries below
	entry_vert, entry_frag: string,
	cbuffers: [dynamic]CBuffer,
	// Sampled texture names in sampler-slot order. Bound by name:
	// "input_tex" gets the previous pass's frame, "skybox_tex" the
	// selected skybox; anything else falls back to paper.
	sampler_textures: [dynamic]string,
	debug_compute_buffer: bool,
	debug_fragment_buffer: bool,
	debug_compute_slot: u32,
	debug_fragment_slot: u32,
	debug_watch_labels: [DEBUG_WATCH_COUNT]string,
	// Model-viewer passes: the vertex entry takes a [[stage_in]] struct,
	// so the default model (model.odin) is drawn indexed with depth
	// instead of the fullscreen triangle.
	uses_model:   bool,
	vertex_attrs: [dynamic]sdl.GPUVertexAttribute,
}

RuntimeScene :: struct {
	title:    string,
	source:   string,
	mtime:    time.Time,
	loaded:   bool,
	passes:   [dynamic]ScenePass,
	// Widgets merged from every pass's reflection (deduped by label);
	// values live here, writes fan out to the pass cbuffers by field name.
	widgets:  [dynamic]UiWidget,
	kind:     SceneKind, // first pass's kind
	// Any pass draws the model (camera interaction + backdrop clear).
	uses_model: bool,
	pipeline:       PipelinePlan,
	pipeline_mtime: time.Time,
	pipeline_error: string,
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
		access := ""
		tk := ""
		base_shape := ""
		for p in params {
			if jstr(jget(p, "name")) != name do continue
			access = jstr(jget(p, "access"))
			if access == "" do access = jstr(jget(jget(p, "type"), "access"))
			tk = jkind(jget(p, "type"))
			base_shape = jstr(jget(jget(p, "type"), "baseShape"))
			break
		}
		is_buffer := strings.contains(tk, "tructuredBuffer") || strings.contains(base_shape, "tructuredBuffer")
		read_write := access == "readWrite"
		if is_buffer {
			if read_write {
				c.rw_buf += 1
			} else {
				c.ro_buf += 1
			}
			continue
		}

		switch jkind(binding) {
		case "samplerState":
			c.samplers += 1
		case "constantBuffer":
			// Raw MSL keeps original buffer indices. Gaps count: a sole
			// buffer(1) requires num_uniform_buffers=2 and push slot 1.
			c.ubuf = max(c.ubuf, u32(jint(jget(binding, "index")) + 1))
		case "shaderResource":
			if read_write {
				c.rw_tex += 1
			} else {
				c.ro_tex += 1
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

debug_buffer_slot :: proc(params: []json.Value, entry: json.Value, target: string) -> (u32, bool) {
	rw_slot: u32
	for b in jarr(jget(entry, "bindings")) {
		if jint(jget(jget(b, "binding"), "used")) == 0 do continue
		name := jstr(jget(b, "name"))
		is_buffer := false
		read_write := false
		for p in params {
			if jstr(jget(p, "name")) != name do continue
			type_ := jget(p, "type")
			is_buffer = strings.contains(jkind(type_), "tructuredBuffer") ||
			            strings.contains(jstr(jget(type_, "baseShape")), "tructuredBuffer")
			access := jstr(jget(p, "access"))
			if access == "" do access = jstr(jget(type_, "access"))
			read_write = access == "readWrite"
			break
		}
		if !is_buffer || !read_write do continue
		if name == target do return rw_slot, true
		rw_slot += 1
	}
	return 0, false
}

// Merges the constant buffers of one stage's reflection into the pass:
// same-name cbuffers from the other stage unify, with stage presence
// taken from the entry point's used bindings so graphics pushes only
// where the block is used. Widgets go to the scene-level list, deduped
// by label across passes.
parse_cbuffers :: proc(
	pass: ^ScenePass,
	scene: ^RuntimeScene,
	params: []json.Value,
	entry: json.Value,
	stage: StageKind,
) {
	for p in params {
		binding := jget(p, "binding")
		if jkind(binding) != "constantBuffer" || jkind(jget(p, "type")) != "constantBuffer" do continue
		name := jstr(jget(p, "name"))
		if entry_binding_used(entry, name) == 0 do continue
		cb: ^CBuffer
		for &existing in pass.cbuffers {
			if existing.name == name {
				cb = &existing
				break
			}
		}
		if cb == nil {
			append(&pass.cbuffers, CBuffer {
				name = strings.clone(name),
			})
			cb = &pass.cbuffers[len(pass.cbuffers) - 1]

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
						label = field.name,
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
					case "UiToggle":
						w.kind = .TOGGLE
						if len(args) >= 1 do w.on = jfloat(args[0]) != 0
					case "UiColor":
						w.kind = .COLOR
						w.value = {1, 1, 1}
						if len(args) >= 3 {
							w.value = {jfloat(args[0]), jfloat(args[1]), jfloat(args[2])}
						}
					case:
						continue
					}
					seen := false
					for existing in scene.widgets {
						if existing.label == w.label {
							seen = true
							break
						}
					}
					if !seen do append(&scene.widgets, w)
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
// cbuffers merged into the pass (widgets go to the scene).
scene_parse_stage_refl :: proc(
	pass: ^ScenePass,
	scene: ^RuntimeScene,
	path: string,
	stage: StageKind,
) -> (counts: ResourceCounts, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("scene %s: failed to read %s", scene.title, path)
		return {}, false
	}
	root, parse_err := json.parse(data)
	if parse_err != nil {
		log.errorf("scene %s: failed to parse %s: %v", scene.title, path, parse_err)
		return {}, false
	}
	// The reflection JSON tree is heap-allocated (50KB+ per pass file);
	// without destroying it, every hot reload leaks the whole tree.
	defer json.destroy_value(root)

	entry: json.Value
	for e in jarr(jget(root, "entryPoints")) {
		if entry == nil do entry = e
		#partial switch stage {
		case .COMPUTE:
			pass.entry = strings.clone(jstr(jget(e, "name")))
			tg := jarr(jget(e, "threadGroupSize"))
			if len(tg) == 3 {
				pass.thread = {u32(jint(tg[0])), u32(jint(tg[1])), u32(jint(tg[2]))}
			}
		case .VERTEX:
			pass.entry_vert = strings.clone(jstr(jget(e, "name")))
			// A [[stage_in]] struct means the pass wants the default
			// model drawn indexed (attribute offsets come from the fixed
			// model layout, keyed by attribute location).
			for p in jarr(jget(e, "parameters")) {
				if jkind(jget(p, "binding")) != "varyingInput" do continue
				for f in jarr(jget(jget(p, "type"), "fields")) {
					location := jint(jget(jget(f, "binding"), "index"))
					offset, ok := model_attr_offset(location)
					if !ok {
						log.errorf(
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
					append(&pass.vertex_attrs, sdl.GPUVertexAttribute {
						location    = u32(location),
						buffer_slot = 0,
						format      = format,
						offset      = offset,
					})
				}
				if len(pass.vertex_attrs) > 0 do pass.uses_model = true
			}
		case .FRAGMENT:
			pass.entry_frag = strings.clone(jstr(jget(e, "name")))
		}
	}
	if pass.thread == {} do pass.thread = {8, 8, 1}

	params := jarr(jget(root, "parameters"))
	counts = count_resources(params, entry)
	parse_cbuffers(pass, scene, params, entry, stage)
	if slot, found := debug_buffer_slot(params, entry, "debug_records"); found {
		if stage == .COMPUTE {
			pass.debug_compute_buffer = true
			pass.debug_compute_slot = slot
		} else if stage == .FRAGMENT {
			pass.debug_fragment_buffer = true
			pass.debug_fragment_slot = slot
		}
	}

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
				for len(pass.sampler_textures) <= slot {
					append(&pass.sampler_textures, "")
				}
				pass.sampler_textures[slot] = strings.clone(jstr(jget(tb, "name")))
			}
		}
	}
	return counts, true
}

// Shader format per host platform: MSL on macOS (Metal), SPIR-V elsewhere
// (Vulkan). The baked build (goose.json) emits both; hot-reload requests
// only the host's format. D3D12 (DXIL) is not emitted yet; honest scope.
SCENE_FMT      :: "msl" when ODIN_OS == .Darwin else "spv"
SCENE_FMT_FLAG :: sdl.GPUShaderFormat{.MSL} when ODIN_OS == .Darwin else sdl.GPUShaderFormat{.SPIRV}
SCENE_TARGET   :: "metal" when ODIN_OS == .Darwin else "spirv"

// Builds the pipeline of one pass from its artifacts in GENERATED_DIR
// (<name>.<stage>.<fmt> + .refl.json), where name is the scene title for
// the entry shader or "title__mod" for a scene-owned module.
scene_parse_pass :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene, name: string) -> (ScenePass, bool) {
	pass := ScenePass {
		name = strings.clone(name),
	}
	compute_refl := fmt.tprintf("%s/%s.compute.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)
	vert_refl := fmt.tprintf("%s/%s.vert.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)
	frag_refl := fmt.tprintf("%s/%s.frag.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)

	if os.exists(compute_refl) {
		pass.kind = .COMPUTE
		counts, ok := scene_parse_stage_refl(&pass, scene, compute_refl, .COMPUTE)
		if !ok do return pass, false
		pass.compute = create_compute_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.compute.%s", GENERATED_DIR, name, SCENE_FMT),
			pass.entry,
			counts,
			pass.thread,
		)
		return pass, pass.compute != nil
	}

	if os.exists(vert_refl) && os.exists(frag_refl) {
		pass.kind = .GRAPHICS
		vc, okv := scene_parse_stage_refl(&pass, scene, vert_refl, .VERTEX)
		fc, okf := scene_parse_stage_refl(&pass, scene, frag_refl, .FRAGMENT)
		if !okv || !okf do return pass, false
		pass.graphics = create_graphics_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.vert.%s", GENERATED_DIR, name, SCENE_FMT),
			fmt.tprintf("%s/%s.frag.%s", GENERATED_DIR, name, SCENE_FMT),
			pass.entry_vert,
			pass.entry_frag,
			vc,
			fc,
			&pass,
		)
		return pass, pass.graphics != nil
	}

	log.errorf("scene %s: no reflection artifacts for %s", scene.title, name)
	return pass, false
}

debug_watch_arg_comma :: proc(source: string, start: int) -> int {
	depth := 0
	for i := start; i < len(source); i += 1 {
		switch source[i] {
		case '(', '[', '{':
			depth += 1
		case ')':
			if depth == 0 do return -1
			depth -= 1
		case ']', '}':
			depth = max(depth - 1, 0)
		case ',':
			if depth == 0 do return i
		}
	}
	return -1
}

scene_parse_debug_watch_labels :: proc(pass: ^ScenePass, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	source := string(data)
	markers := []string{"debug_watch_fragment(", "debug_watch_compute("}
	for marker in markers {
		cursor := 0
		for cursor < len(source) {
			rel := strings.index(source[cursor:], marker)
			if rel < 0 do break
			call_start := cursor + rel
			args_start := call_start + len(marker)
			cursor = args_start
			line_start := strings.last_index(source[:call_start], "\n") + 1
			if strings.index(source[line_start:call_start], "//") >= 0 do continue
			first := debug_watch_arg_comma(source, args_start)
			if first < 0 do continue
			second := debug_watch_arg_comma(source, first + 1)
			if second < 0 do continue
			cursor = second + 1
			slot, ok := strconv.parse_int(strings.trim_space(source[args_start:first]))
			if !ok || slot < 0 || slot >= DEBUG_WATCH_COUNT do continue
			label := strings.trim_space(source[first + 1:second])
			if label == "" || pass.debug_watch_labels[slot] != "" do continue
			if len(label) > 48 do label = label[:48]
			pass.debug_watch_labels[slot] = strings.clone(label)
		}
	}
}

// Parses the entry shader plus every scene-owned module (pass_1.slang,
// pass_2.slang, ...) into the scene's ordered pass chain.
scene_parse_reflection :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) -> bool {
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	sources := make([dynamic]string, 0, 4, context.temp_allocator)
	append(&names, scene.title)
	append(&sources, scene.source)
	for mod in scene_module_names(scene.title) {
		append(&names, fmt.tprintf("%s__%s", scene.title, mod))
		append(&sources, fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, scene.title, mod))
	}
	for name, i in names {
		pass, ok := scene_parse_pass(gpu, scene, name)
		if !ok {
			scene_release_pass(gpu, &pass)
			return false
		}
		scene_parse_debug_watch_labels(&pass, sources[i])
		source_key := strings.trim_suffix(strings.trim_prefix(sources[i], "src/shaders/"), ".slang")
		if pass.kind == .COMPUTE {
			pass.graph_key = strings.clone(fmt.tprintf("comp:%s:%s", source_key, pass.entry))
		} else {
			pass.graph_key = strings.clone(fmt.tprintf("gfx:%s", source_key))
		}
		scene.uses_model |= pass.uses_model
		append(&scene.passes, pass)
	}
	if len(scene.passes) == 0 do return false
	scene.kind = scene.passes[0].kind
	return true
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
		log.errorf("scene: failed to read %s", path)
		return nil
	}
	shader := sdl.CreateGPUShader(
		gpu,
		{
			stage = stage,
			format = SCENE_FMT_FLAG,
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
		log.errorf("scene: failed to create shader from %s: %s", path, sdl.GetError())
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
		log.errorf("scene: failed to read %s", msl_path)
		return nil
	}
	pipeline := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = raw_data(blob),
			code_size = len(blob),
			entrypoint = strings.clone_to_cstring(entrypoint, context.temp_allocator),
			format = SCENE_FMT_FLAG,
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
		log.errorf("scene: failed to create compute pipeline %s: %s", msl_path, sdl.GetError())
	}
	return pipeline
}

create_graphics_pipeline_raw :: proc(
	gpu: ^sdl.GPUDevice,
	vert_path, frag_path: string,
	entry_vert, entry_frag: string,
	vc, fc: ResourceCounts,
	pass: ^ScenePass,
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
	if pass.uses_model {
		// Model draw: interleaved vertex buffer at slot 0, depth-tested.
		create_info.vertex_input_state = {
			num_vertex_buffers = 1,
			vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
				slot = 0,
				pitch = MODEL_PITCH,
				input_rate = .VERTEX,
			}),
			num_vertex_attributes = u32(len(pass.vertex_attrs)),
			vertex_attributes = raw_data(pass.vertex_attrs),
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
		log.errorf("scene: failed to link graphics pipeline: %s", sdl.GetError())
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

// Scene-owned module files (every .slang in the scene dir except the
// entry), sorted by name: this is the pass chain order, so chained
// passes name themselves pass_1, pass_2, ... Returned names carry no
// extension.
scene_module_names :: proc(name: string) -> [dynamic]string {
	// Temp-allocated: the caller consumes the list while parsing the
	// scene (same frame), and the per-frame free_all reclaims it.
	mods := make([dynamic]string, context.temp_allocator)
	dir := fmt.tprintf("%s/%s", SCENES_DIR, name)
	entries, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil do return mods
	entry_file := fmt.tprintf("%s.slang", name)
	for entry in entries {
		if entry.type != .Regular do continue
		if !strings.has_suffix(entry.name, ".slang") do continue
		if entry.name == entry_file do continue
		append(&mods, strings.clone(entry.name[:len(entry.name) - len(".slang")], context.temp_allocator))
	}
	slice.sort(mods[:])
	return mods
}

scene_names_on_disk :: proc() -> [dynamic]string {
	// Temp-allocated: callers (scene_poll/rescan) use the list within the
	// frame, and the main loop's per-frame free_all reclaims it: the
	// heap would otherwise grow by ~24 strings every frame forever.
	names := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_directory_by_path(SCENES_DIR, 0, context.temp_allocator)
	if err != nil do return names
	for entry in entries {
		if entry.type != .Directory do continue
		if !os.exists(scene_entry_path(entry.name)) do continue
		append(&names, strings.clone(entry.name, context.temp_allocator))
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
	// Hot-reload emits only the host's shader format (SCENE_TARGET);
	// the baked goose.json build still emits both msl and spv.
	strings.write_string(&sb, `"commonUniforms":true,"targets":["`)
	strings.write_string(&sb, SCENE_TARGET)
	strings.write_string(&sb, `"],"shaders":[`)
	// No fmt here: Odin's fmt treats '{' as a directive.
	write_shader :: proc(sb: ^strings.Builder, name, source: string, first: ^bool) {
		if !first^ do strings.write_byte(sb, ',')
		first^ = false
		strings.write_string(sb, `{"name":"`)
		strings.write_string(sb, name)
		strings.write_string(sb, `","source":"`)
		strings.write_string(sb, source)
		strings.write_string(sb, `"}`)
	}
	first := true
	for name in names {
		entry := fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, name, name)
		write_shader(&sb, name, entry, &first)
		// Scene-owned modules (the pass chain): artifact names are
		// namespaced "scene__mod" so two scenes can both have pass_1.
		for mod in scene_module_names(name) {
			source := fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, name, mod)
			write_shader(&sb, fmt.tprintf("%s__%s", name, mod), source, &first)
		}
	}
	strings.write_string(&sb, `]}`)
	if os.write_entire_file(SCENES_MANIFEST, transmute([]u8)strings.to_string(sb)) != nil {
		log.errorf("scenes: failed to write %s", SCENES_MANIFEST)
		return false
	}

	// Cross-process exclusion: more than one app instance may watch the
	// same src/shaders tree (two dev builds at once), and concurrent
	// goose-build runs corrupt each other's artifacts: reflection files
	// left truncated at 0 bytes, scenes stuck "goose-build failed"
	// forever (seen live with graphics2d). Serialize through an O_EXCL
	// lockfile; if another process holds it, skip this round: the next
	// rescan picks up its artifacts.
	lock, lock_err := os.open(
		"src/generated/scenes/.build.lock",
		{.Write, .Create, .Excl},
	)
	if lock_err == nil {
		defer {
			os.close(lock)
			os.remove("src/generated/scenes/.build.lock")
		}
	} else {
		// Stale lock guard: a crashed builder never releases. Treat a
		// lock older than a minute as stale and take it over.
		if info, stat_err := os.stat("src/generated/scenes/.build.lock", context.temp_allocator);
		   stat_err == nil && time.since(info.modification_time) > time.Minute {
			os.remove("src/generated/scenes/.build.lock")
		}
		log.info("scenes: build lock held by another instance; skipping")
		return true
	}

	goose_bin := os.get_env("GOOSE", context.temp_allocator)
	if goose_bin == "" do goose_bin = "../goose/goose-build"
	slang := os.get_env("SLANG", context.temp_allocator)
	if slang == "" do slang = "vendor/slang/bin/slangc"
	command := []string{goose_bin, "--manifest", SCENES_MANIFEST, "--slang", slang}
	state, stdout, stderr, process_error := os.process_exec({command = command}, context.temp_allocator)
	if process_error != nil {
		log.errorf("scenes: failed to run goose-build: %v", process_error)
		return false
	}
	if !state.success {
		if len(stderr) > 0 {
			fmt.eprint(string(stderr))
			build_errors_parse(string(stderr))
		}
		log.warn("scenes: goose-build failed; keeping previous scene pipelines")
		return false
	}
	sync.mutex_lock(&scene_build_mu)
	if len(build_errors) > 0 {
		build_errors_clear()
		build_errors_version += 1
	}
	sync.mutex_unlock(&scene_build_mu)
	return true
}

scene_release_pass :: proc(gpu: ^sdl.GPUDevice, pass: ^ScenePass) {
	if pass.compute != nil do sdl.ReleaseGPUComputePipeline(gpu, pass.compute)
	if pass.graphics != nil do sdl.ReleaseGPUGraphicsPipeline(gpu, pass.graphics)
	delete(pass.name)
	delete(pass.graph_key)
	for cb in pass.cbuffers do delete(cb.block)
	delete(pass.cbuffers)
	delete(pass.sampler_textures)
	delete(pass.vertex_attrs)
	for label in pass.debug_watch_labels do if label != "" do delete(label)
}

scene_release :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) {
	for &pass in scene.passes do scene_release_pass(gpu, &pass)
	delete(scene.passes)
	delete(scene.widgets)
	pipeline_plan_destroy(&scene.pipeline)
	delete(scene.pipeline_error)
}

// Newest mtime across the scene's entry and module files: the reload key
// (a chained pass edit must rebuild the scene like an entry edit).
scene_latest_mtime :: proc(name: string) -> time.Time {
	latest: time.Time
	if info, err := os.stat(scene_entry_path(name), context.temp_allocator); err == nil {
		latest = info.modification_time
	}
	for mod in scene_module_names(name) {
		path := fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, name, mod)
		if info, err := os.stat(path, context.temp_allocator); err == nil {
			if time.diff(info.modification_time, latest) > 0 {
				latest = info.modification_time
			}
		}
	}
	return latest
}

// Loads a scene into `out`; on failure `out` is cleaned up and false is
// returned, so callers can keep a previous working version in place
// (e.g. artifacts corrupted by a concurrent instance or a slang error).
scene_load_into :: proc(gpu: ^sdl.GPUDevice, name: string, out: ^RuntimeScene) -> bool {
	out^ = RuntimeScene {
		title  = strings.clone(name),
		source = scene_entry_path(name),
	}
	if !os.exists(out.source) do return false
	out.mtime = scene_latest_mtime(name)

	if !scene_parse_reflection(gpu, out) || !pipeline_scene_init(out) {
		scene_release(gpu, out)
		return false
	}
	out.loaded = true
	return true
}

scene_load :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, name: string) -> bool {
	scene: RuntimeScene
	if !scene_load_into(gpu, name, &scene) do return false
	append(&sm.scenes, scene)
	return true
}

// --------------------------------------------------------------------
// Async scene builds: saving a shader must not freeze the UI thread.
// scene_poll only REQUESTS a build; the worker thread runs goose-build
// (process exec, file IO), and scene_build_pump applies the result on the
// main thread (pipeline creation needs the GPU). Requests during a build
// coalesce into one follow-up build. The startup scan stays synchronous;
// the first frame needs pipelines.

scene_build_mu:      sync.Mutex

// Reload/build serialization: scene_build_pump sets scene_applying while
// scene_reload reads generated artifacts; the worker waits for it before
// running goose-build, which rewrites the same files. Without this a fast
// edit sequence makes the pump parse half-written reflection JSON.
scene_applying:      bool
scene_build_apply_cond: sync.Cond

// Scenes whose load failed at a given mtime (name -> mtime, names owned).
// A failed scene is retried only when its source changes again: a broken
// shader otherwise re-runs the failing build every frame, flooding the
// log with the same errors.
scene_failed: map[string]time.Time
scene_build_cond:    sync.Cond
scene_build_req:     bool
scene_build_running: bool
scene_build_done:    bool
scene_build_ok:      bool
scene_build_again:   bool
scene_build_names:   [dynamic]string
scene_build_thread:  ^thread.Thread

scene_build_worker :: proc() {
	for {
		sync.mutex_lock(&scene_build_mu)
		for !scene_build_req {
			sync.cond_wait(&scene_build_cond, &scene_build_mu)
		}
		scene_build_req = false
		scene_build_running = true
		// Snapshot the names under the lock: scene_request_build frees and
		// rebuilds scene_build_names concurrently, and the build itself
		// must wait for any in-flight reload to finish reading artifacts.
		names := make([dynamic]string, 0, len(scene_build_names))
		for n in scene_build_names do append(&names, strings.clone(n))
		for scene_applying {
			sync.cond_wait(&scene_build_apply_cond, &scene_build_mu)
		}
		sync.mutex_unlock(&scene_build_mu)

		ok := scenes_build(names[:])
		for n in names do delete(n)
		delete(names)
		// The worker's temp_allocator is separate from the main thread's:
		// without this, every build's manifest/file/JSON temp allocations
		// accumulate for the process's lifetime (long sessions balloon).
		free_all(context.temp_allocator)

		sync.mutex_lock(&scene_build_mu)
		scene_build_ok = ok
		scene_build_running = false
		scene_build_done = true
		sync.mutex_unlock(&scene_build_mu)
	}
}

// Requests a build on the worker thread (starts it lazily). A request
// while one is in flight coalesces into a single follow-up.
// Edit→pixel latency probe: armed when a build is
// requested, marked when a scene pipeline actually swaps in scene_reload,
// read by main after the next presented frame. Failed/no-op reloads disarm.
latency_pending: bool
latency_tick:    time.Tick
latency_swapped: bool

scene_request_build :: proc(names: []string) {
	if !latency_pending {
		latency_pending = true
		latency_tick = time.tick_now()
	}
	sync.mutex_lock(&scene_build_mu)
	if scene_build_thread == nil {
		scene_build_thread = thread.create_and_start(
			scene_build_worker,
			runtime.default_context(),
		)
	}
	if scene_build_req || scene_build_running {
		scene_build_again = true
		sync.mutex_unlock(&scene_build_mu)
		return
	}
	for n in scene_build_names do delete(n)
	clear(&scene_build_names)
	for n in names do append(&scene_build_names, strings.clone(n))
	scene_build_req = true
	sync.cond_signal(&scene_build_cond)
	sync.mutex_unlock(&scene_build_mu)
	log.infof("[scenes] async build queued (%d scenes)", len(names))
}

// Reports the edit→pixel latency once, after the frame that first renders
// a swapped pipeline. Called by main at the end of each frame.
latency_report :: proc() {
	if latency_pending && latency_swapped {
		ms := f64(time.tick_since(latency_tick)) / f64(time.Millisecond)
		log.infof("[latency] edit->pixel: %.1f ms", ms)
		latency_pending = false
		latency_swapped = false
	}
}

// Applies a finished build: reloads changed scenes on the main thread and
// queues the coalesced follow-up build, if any. Called every frame.
// Monotonic version consumed by the editor to snapshot source text only
// after a build produced a loadable pipeline.
scene_build_pump :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice) {
	sync.mutex_lock(&scene_build_mu)
	if !scene_build_done {
		sync.mutex_unlock(&scene_build_mu)
		return
	}
	scene_build_done = false
	again := scene_build_again
	scene_build_again = false
	sync.mutex_unlock(&scene_build_mu)

	if !scene_build_ok {
		latency_pending = false
		latency_swapped = false
	}
	sync.mutex_lock(&scene_build_mu)
	scene_applying = true
	sync.mutex_unlock(&scene_build_mu)
	scene_reload(sm, gpu, scene_build_names[:])
	sync.mutex_lock(&scene_build_mu)
	scene_applying = false
	sync.cond_broadcast(&scene_build_apply_cond)
	sync.mutex_unlock(&scene_build_mu)
	log.infof("[scenes] async build applied (ok=%v)", scene_build_ok)
	if scene_build_ok && latency_swapped {
		build_success_version += 1
		fx_sfx_play(.BUILD_OK)
	} else if !scene_build_ok {
		fx_sfx_play(.BUILD_ERROR)
		notify(.ERROR, "%s", tr("build failed"))
	}
	if again && len(sm.scenes) > 0 {
		active := [1]string{sm.scenes[sm.current].title}
		scene_request_build(active[:])
	}
}

// Discovers the complete catalog but builds only the selected scene.
scene_rescan :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, start_scene: int) -> bool {
	names := scene_names_on_disk()
	if len(names) == 0 {
		log.errorf("no scene directories found in %s", SCENES_DIR)
		return false
	}
	for name in names {
		append(&sm.scenes, RuntimeScene {
			title = strings.clone(name),
			source = scene_entry_path(name),
		})
	}
	selected := start_scene
	if selected < 0 || selected >= len(sm.scenes) do selected = 0
	sm.current = selected
	if info, err := os.stat("src/shaders/common.slang", context.temp_allocator); err == nil {
		common_mtime = info.modification_time
	}
	return scene_ensure_loaded(sm, gpu, selected)
}

// Builds and loads one catalog entry. Scene-owned pass modules are included
// by scenes_build; Slang resolves imported utils through the module search path.
scene_ensure_loaded :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, index: int) -> bool {
	if index < 0 || index >= len(sm.scenes) {
		log.errorf("scene index out of range: %d", index)
		return false
	}
	if sm.scenes[index].loaded do return true
	name := sm.scenes[index].title
	requested := [1]string{name}
	if !scenes_build(requested[:]) {
		log.errorf("failed to build scene %s", name)
		return false
	}
	current_before := sm.current
	sm.current = index
	scene_reload(sm, gpu, requested[:])
	loaded := index < len(sm.scenes) && sm.scenes[index].loaded
	if !loaded {
		log.errorf("failed to load scene %s after build", name)
		sm.current = current_before
	}
	return loaded
}

// Synchronizes removals against the complete on-disk catalog. Reloads may
// receive only a subset of changed scenes, so removal cannot live there.
scene_drop_removed :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, names: []string) {
	current_title := strings.clone(sm.scenes[sm.current].title) if len(sm.scenes) > 0 else ""
	defer if current_title != "" do delete(current_title)
	for i := len(sm.scenes) - 1; i >= 0; i -= 1 {
		found := false
		for name in names do if sm.scenes[i].title == name { found = true; break }
		if !found {
			scene_release(gpu, &sm.scenes[i])
			ordered_remove(&sm.scenes, i)
		}
	}
	stale := make([dynamic]string, context.temp_allocator)
	for key in scene_failed {
		found := false
		for name in names do if key == name { found = true; break }
		if !found do append(&stale, key)
	}
	for key in stale {
		delete_key(&scene_failed, key)
		delete(key)
	}
	if len(sm.scenes) == 0 {
		sm.current = 0
		return
	}
	sm.current = 0
	if current_title != "" {
		for &s, i in sm.scenes do if s.title == current_title { sm.current = i; break }
	}
}

// Adds newly discovered scenes as unloaded catalog entries. Their shader
// artifacts are built only when the user selects them.
scene_add_new_catalog_entries :: proc(sm: ^SceneManager, names: []string) {
	for name in names {
		found := false
		for &s in sm.scenes do if s.title == name { found = true; break }
		if !found {
			append(&sm.scenes, RuntimeScene {
				title = strings.clone(name),
				source = scene_entry_path(name),
			})
		}
	}
}

// Reloads what changed after a build. Preserves the current scene by
// title; a scene that fails to reload keeps its previous working version.
scene_reload :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice, names: []string) {
	current_title := strings.clone(sm.scenes[sm.current].title) if len(sm.scenes) > 0 else ""
	defer if current_title != "" do delete(current_title)


	// Add new, reload changed. A scene that fails to reload keeps its
	// previous working version in place, and a scene whose source didn't
	// change since the failure is NOT retried (otherwise a broken shader
	// re-runs the failing build every frame, spamming the same errors).
	for name in names {
		if !os.exists(scene_entry_path(name)) do continue
		mtime := scene_latest_mtime(name)
		if failed_at, was_failed := scene_failed[name]; was_failed && failed_at == mtime {
			continue
		}
		idx := -1
		for &s, i in sm.scenes do if s.title == name { idx = i; break }
		if idx >= 0 && sm.scenes[idx].mtime == mtime do continue
		ok: bool
		if idx >= 0 {
			candidate: RuntimeScene
			if scene_load_into(gpu, name, &candidate) {
				scene_release(gpu, &sm.scenes[idx])
				ordered_remove(&sm.scenes, idx)
				inject_at(&sm.scenes, idx, candidate)
				ok = true
			}
		} else {
			ok = scene_load(sm, gpu, name)
		}
		if ok {
			latency_swapped = true
			// Map indexing yields the value, so find the owned key to
			// free it (no delete_key during iteration).
			stored: string
			have_stored := false
			for k in scene_failed {
				if k == name { stored = k; have_stored = true; break }
			}
			if have_stored {
				// delete_key BEFORE delete: hashing the key after freeing
				// it is a use-after-free.
				delete_key(&scene_failed, stored)
				delete(stored)
			}
		} else if !(name in scene_failed) {
			scene_failed[strings.clone(name)] = mtime
			notify(.ERROR, tr("scene '%s' failed to load"), name)
		}
	}


	// A reload that swapped nothing leaves no latency to report (broken
	// scenes keep the previous pipeline by design).
	if latency_pending && !latency_swapped do latency_pending = false

	// Restore selection.
	sm.current = 0
	if current_title != "" {
		for &s, i in sm.scenes do if s.title == current_title { sm.current = i; break }
	}
}

SCENE_POLL_INTERVAL_MS :: u64(100)
scene_poll_started: bool
scene_poll_next_ms: u64

scene_poll :: proc(sm: ^SceneManager, gpu: ^sdl.GPUDevice) {
	// Apply finished async builds first (reloads change sm.scenes).
	if !scene_poll_started {
		scene_poll_started = true
		log.infof("[scenes] watcher active for %s", sm.scenes[sm.current].title)
	}
	scene_build_pump(sm, gpu)
	// Disk scans and stat calls do not need to run at the render rate.
	now_ms := sdl.GetTicks()
	if now_ms < scene_poll_next_ms do return
	scene_poll_next_ms = now_ms + SCENE_POLL_INTERVAL_MS
	names := scene_names_on_disk()
	scene_drop_removed(sm, gpu, names[:])
	scene_add_new_catalog_entries(sm, names[:])
	changed_names := make([dynamic]string, context.temp_allocator)
	if len(sm.scenes) == 0 do return
	active_name := sm.scenes[sm.current].title
	active_mtime := scene_latest_mtime(active_name)
	if failed_at, was_failed := scene_failed[active_name]; !was_failed || failed_at != active_mtime {
		if !sm.scenes[sm.current].loaded || sm.scenes[sm.current].mtime != active_mtime {
			log.infof("[scenes] source change detected: %s", active_name)
			append(&changed_names, active_name)
		}
	}
	// common.slang is imported by every scene. Rebuild only the active
	// scene now; unloaded scenes consume the new common when selected.
	info, stat_err := os.stat("src/shaders/common.slang", context.temp_allocator)
	if stat_err == nil && info.modification_time != common_mtime {
		common_mtime = info.modification_time
		clear(&changed_names)
		append(&changed_names, active_name)
		failed_keys := make([dynamic]string, context.temp_allocator)
		for key in scene_failed do append(&failed_keys, key)
		for key in failed_keys {
			delete_key(&scene_failed, key)
			delete(key)
		}
	}
	if len(changed_names) > 0 do scene_request_build(changed_names[:])
}

common_mtime: time.Time

// --------------------------------------------------------------------
// Per-frame uniform filling

poke_f32 :: proc(block: []u8, offset: int, v: f32) {
	if offset < 0 || offset + 4 > len(block) do return
	(^f32)(rawptr(&block[offset]))^ = v
}

poke_u32 :: proc(block: []u8, offset: int, v: u32) {
	if offset < 0 || offset + 4 > len(block) do return
	(^u32)(rawptr(&block[offset]))^ = v
}

scene_set_manual :: proc(pass: ^ScenePass, v: f32) {
	for cb in pass.cbuffers {
		for f in cb.fields {
			if f.name == "iManual" do poke_f32(cb.block, f.offset, v)
		}
	}
}

scene_set_debug_pass :: proc(pass: ^ScenePass, pass_index: u32) {
	for cb in pass.cbuffers {
		for f in cb.fields {
			if f.name == "iDebugPass" do poke_u32(cb.block, f.offset, pass_index)
		}
	}
}

scene_has_debug_watches :: proc(scene: ^RuntimeScene) -> bool {
	for pass in scene.passes {
		if pass.debug_compute_buffer || pass.debug_fragment_buffer do return true
	}
	return false
}

// --------------------------------------------------------------------
// Frame submission

GIF_FPS :: 17
GIF_DIR :: "/tmp/inktober_gif"

SceneResources :: struct {
	depth_tex:         ^sdl.GPUTexture,
	sampler:           ^sdl.GPUSampler,
	paper_textures:    []^sdl.GPUTexture,
	paper_index:       int,
	skybox_textures:   []^sdl.GPUTexture,
	skybox_index:      int,
	model:             ^Model,
	pass_tex:          []^sdl.GPUTexture,
	black_texture:     ^sdl.GPUTexture,
	debug_watch_buffer: ^sdl.GPUBuffer,
}

push_scene_uniforms :: proc(cmd: ^sdl.GPUCommandBuffer, pass: ^ScenePass, compute: bool) {
	for cb in pass.cbuffers {
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

scene_pass_texture :: proc(
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	pass_index: int,
) -> ^sdl.GPUTexture {
	if pass_index == scene.pipeline.output_pass do return scene_tex
	if pass_index >= 0 && pass_index < len(res.pass_tex) do return res.pass_tex[pass_index]
	return nil
}

submit_scene_frame :: proc(
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	width, height: i32,
) -> ^sdl.GPUFence {
	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	if cmd == nil {
		log.errorf("scene: failed to acquire command buffer: %s", sdl.GetError())
		return nil
	}

	for pass_index in scene.pipeline.order {
		pass := &scene.passes[pass_index]
		out_tex := scene_pass_texture(scene, scene_tex, res, pass_index)
		if out_tex == nil {
			log.errorf("scene: no output texture for pass %s", pass.name)
			return nil
		}
		scene_set_debug_pass(pass, u32(pass_index))
		n := len(pass.sampler_textures)
		bindings := make([]sdl.GPUTextureSamplerBinding, max(n, 1), context.temp_allocator)
		for name, slot in pass.sampler_textures {
			tex := res.paper_textures[res.paper_index]
			if producer := pipeline_plan_source(&scene.pipeline, pass_index, name); producer >= 0 {
				tex = scene_pass_texture(scene, scene_tex, res, producer)
			} else {
				switch name {
				case "skybox_tex":
					if res.skybox_index >= 0 && res.skybox_index < len(res.skybox_textures) {
						tex = res.skybox_textures[res.skybox_index]
					}
				case "input_tex":
					tex = res.black_texture
				}
			}
			bindings[slot] = {texture = tex, sampler = res.sampler}
		}

		switch pass.kind {
		case .COMPUTE:
			tex_binding := sdl.GPUStorageTextureReadWriteBinding {texture = out_tex, cycle = false}
			compute_pass: ^sdl.GPUComputePass
			if pass.debug_compute_buffer && res.debug_watch_buffer != nil {
				buffer_binding := sdl.GPUStorageBufferReadWriteBinding {buffer = res.debug_watch_buffer, cycle = false}
				compute_pass = sdl.BeginGPUComputePass(cmd, &tex_binding, 1, &buffer_binding, 1)
			} else {
				compute_pass = sdl.BeginGPUComputePass(cmd, &tex_binding, 1, nil, 0)
			}
			sdl.BindGPUComputePipeline(compute_pass, pass.compute)
			if n > 0 do sdl.BindGPUComputeSamplers(compute_pass, 0, raw_data(bindings), u32(n))
			push_scene_uniforms(cmd, pass, true)
			tx, ty := i32(pass.thread.x), i32(pass.thread.y)
			sdl.DispatchGPUCompute(compute_pass, u32((width + tx - 1) / tx), u32((height + ty - 1) / ty), 1)
			sdl.EndGPUComputePass(compute_pass)
		case .GRAPHICS:
			color_target := sdl.GPUColorTargetInfo {
				texture = out_tex, load_op = .CLEAR, clear_color = {0, 0, 0, 1}, store_op = .STORE,
			}
			if pass.uses_model do color_target.clear_color = {0.93, 0.91, 0.86, 1}
			depth_target := sdl.GPUDepthStencilTargetInfo {
				texture = res.depth_tex, load_op = .CLEAR, clear_depth = 1.0, store_op = .DONT_CARE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, pass.uses_model ? &depth_target : nil)
			sdl.BindGPUGraphicsPipeline(render_pass, pass.graphics)
			if n > 0 do sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings), u32(n))
			if pass.debug_fragment_buffer && res.debug_watch_buffer != nil {
				sdl.BindGPUFragmentStorageBuffers(render_pass, pass.debug_fragment_slot, &res.debug_watch_buffer, 1)
			}
			if pass.uses_model {
				vb_binding := sdl.GPUBufferBinding{buffer = res.model.vb, offset = 0}
				sdl.BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1)
				sdl.BindGPUIndexBuffer(render_pass, {buffer = res.model.ib, offset = 0}, ._32BIT)
				scene_set_manual(pass, 1)
				push_scene_uniforms(cmd, pass, false)
				sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
				scene_set_manual(pass, 0)
				push_scene_uniforms(cmd, pass, false)
				sdl.DrawGPUIndexedPrimitives(render_pass, res.model.index_count, 1, 0, 0, 0)
			} else {
				push_scene_uniforms(cmd, pass, false)
				sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
			}
			sdl.EndGPURenderPass(render_pass)
		}
	}
	return sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
}

// GIF export (EXPORT panel's "export gif" button): re-renders the active
// scene at GIF_FPS from t=start_s to t=end_s, writes each frame as
// /tmp/inktober_gif/frame_NNN.png, then runs ffmpeg.
export_gif :: proc(
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	width, height: i32,
	color: bool,
	start_s, end_s: f32,
) {
	frames := max(1, int((end_s - start_s) * GIF_FPS))
	os.make_directory(GIF_DIR)
	for i in 0 ..< 100000 {
		if err := os.remove(fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)); err != nil do break
	}
	for i in 0 ..< frames {
		time_s := start_s + f32(i)/GIF_FPS
		camera := camera_orbit(time_s * 0.4, 0.55, f32(width) / f32(height))
		scene_write_uniforms(
			scene,
			{f32(width), f32(height)},
			time_s,
			color,
			{0, 0},
			false,
			&camera,
			false,
			{0, 0},
			0,
		)
		fence := submit_scene_frame(gpu, scene, scene_tex, res, width, height)
		if fence == nil {
			log.errorf("gif export: failed to submit frame %d", i)
			break
		}
		sdl.ReleaseGPUFence(gpu, fence)
		path := fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)
		if !save_texture_png(gpu, scene_tex, width, height, path) do break
		log.infof("gif frame %d/%d", i + 1, frames)
	}

	out_path := export_path(scene.title, "gif")
	palette := fmt.tprintf("%s/palette.png", GIF_DIR)
	filters :: "fps=17,scale=480:-1:flags=lanczos"
	cmdline := fmt.tprintf(
		`ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -vf "%s,palettegen" -y %s` +
		` && ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -i %s` +
		` -lavfi "%s [x]; [x][1:v] paletteuse" -y %s`,
		GIF_DIR, filters, palette, GIF_DIR, palette, filters, out_path,
	)
	status := libc.system(strings.clone_to_cstring(cmdline, context.temp_allocator))
	if status == 0 {
		log.infof("saved %s", out_path)
	} else {
		log.errorf("gif export: ffmpeg exited with status %d", status)
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
	debug_enabled: bool,
	debug_pixel_top: [2]i32,
	debug_frame: u32,
) {
	for &pass in scene.passes {
		for cb in pass.cbuffers {
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
				case "iDebugPixel":
					poke_u32(cb.block, f.offset, u32(max(debug_pixel_top[0], 0)))
					debug_y := debug_pixel_top[1]
					if pass.kind == .GRAPHICS do debug_y = i32(res.y) - 1 - debug_y
					poke_u32(cb.block, f.offset + 4, u32(max(debug_y, 0)))
				case "iDebugEnabled":
					poke_u32(cb.block, f.offset, debug_enabled ? 1 : 0)
				case "iDebugFrame":
					poke_u32(cb.block, f.offset, debug_frame)
				}
			}
		}
	}
	for &w in scene.widgets {
		for &pass in scene.passes {
			for cb in pass.cbuffers {
				for f in cb.fields {
					if f.name != w.label do continue
					switch w.kind {
					case .SLIDER: poke_f32(cb.block, f.offset, w.value[0])
					case .TOGGLE: poke_f32(cb.block, f.offset, w.on ? 1 : 0)
					case .COLOR:
						poke_f32(cb.block, f.offset, w.value[0])
						poke_f32(cb.block, f.offset + 4, w.value[1])
						poke_f32(cb.block, f.offset + 8, w.value[2])
					}
				}
			}
		}
	}
}
