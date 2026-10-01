package main

import goose "../.."
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Shaders compile on a thread pool; this serializes console output so
// progress lines and Slang diagnostics from concurrent tasks do not
// interleave mid-line.
log_mutex: sync.Mutex

log_printfln :: proc(format: string, args: ..any) {
	sync.lock(&log_mutex)
	defer sync.unlock(&log_mutex)
	fmt.printfln(format, ..args)
}

GENERATOR_SCHEMA :: "5"

ManifestShader :: struct {
	name:   string,
	source: string,
}

Manifest :: struct {
	output_dir:           string `json:"outputDir"`,
	parameter_output_dir: string `json:"parameterOutputDir"`,
	package_name:         string `json:"package"`,
	goose_import:         string `json:"gooseImport"`,
	shaders:              []ManifestShader,
	// Optional subset of MANIFEST_TARGETS by slang target name
	// ("metal" | "hlsl" | "spirv"); empty means all three.
	targets:              []string `json:"targets"`,
}

manifest_targets :: proc(manifest: Manifest) -> []TargetSpec {
	selected: [dynamic]TargetSpec
	if len(manifest.targets) == 0 {
		for target in MANIFEST_TARGETS {
			append(&selected, target)
		}
		return selected[:]
	}
	for name in manifest.targets {
		found := false
		for target in MANIFEST_TARGETS {
			if target.slang_target == name {
				append(&selected, target)
				found = true
				break
			}
		}
		if !found do fatal("Goose manifest has unknown target: %s", name)
	}
	return selected[:]
}

ManifestEntryPoint :: struct {
	name:  string,
	stage: string,
}

ModuleReflection :: struct {
	entry_points: []ManifestEntryPoint `json:"entryPoints"`,
}

ManifestOptions :: struct {
	path:       string,
	slang:      string,
	hot_reload: bool,
}

TargetSpec :: struct {
	platform:     goose.Platform,
	slang_target: string,
	extension:    string,
	condition:    string,
}

MANIFEST_TARGETS :: [3]TargetSpec {
	{platform = .Metal, slang_target = "metal", extension = "msl", condition = "ODIN_OS == .Darwin"},
	{platform = .Direct3D, slang_target = "hlsl", extension = "hlsl", condition = "ODIN_OS == .Windows"},
	{platform = .Vulkan, slang_target = "spirv", extension = "spv"},
}

parse_manifest_options :: proc() -> (ManifestOptions, bool) {
	options: ManifestOptions
	args := os.args[1:]
	has_manifest := false
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if argument == "--hot-reload" {
			options.hot_reload = true
			continue
		}
		if argument != "--manifest" && argument != "--slang" do continue
		if index + 1 >= len(args) do fatal("missing value for %s", argument)
		index += 1
		value := args[index]
		switch argument {
		case "--manifest":
			options.path = value
			has_manifest = true
		case "--slang":
			options.slang = value
		}
	}
	if !has_manifest do return {}, false
	if options.slang == "" do fatal("--slang is required with --manifest")
	return options, true
}

// Compiles the whole module without an entry point so the reflection JSON
// lists every entry point in the source. Metal accepts a discarded module
// artifact; each entry point is then compiled for every target separately.
// Also emits a make-style depfile so freshness tracking sees every module
// the source imports, not just the source file itself.
run_slang_discovery :: proc(slang_path, source, reflection, deps: string) {
	command := []string {
		slang_path,
		source,
		"-target",
		"metal",
		"-reflection-json",
		reflection,
		"-depfile",
		deps,
		"-o",
		"/dev/null",
	}
	log_printfln("goose: %s -> %s", source, reflection)
	run_slang_command(command, source)
}

run_slang :: proc(slang_path, source, entrypoint, target, output, reflection: string) {
	command := []string {
		slang_path,
		source,
		"-entry",
		entrypoint,
		"-target",
		target,
		"-reflection-json",
		reflection,
		"-o",
		output,
	}
	log_printfln("goose: %s %s [%s] -> %s", source, entrypoint, target, output)
	run_slang_command(command, source)
}

run_slang_command :: proc(command: []string, source: string) {
	state, stdout, stderr, process_error := os.process_exec(
		{command = command},
		context.temp_allocator,
	)
	if len(stdout) > 0 || len(stderr) > 0 {
		sync.lock(&log_mutex)
		if len(stdout) > 0 do fmt.print(string(stdout))
		if len(stderr) > 0 do fmt.eprint(string(stderr))
		sync.unlock(&log_mutex)
	}
	if process_error != nil do fatal("failed to execute Slang: %v", process_error)
	if !state.success do fatal("Slang failed for %s", source)
}

manifest_module_reflection_path :: proc(manifest: Manifest, shader: ManifestShader) -> string {
	return filepath.join(
		{manifest.output_dir, fmt.tprintf("%s.refl.json", shader.name)},
		context.temp_allocator,
	) or_else ""
}

manifest_deps_path :: proc(manifest: Manifest, shader: ManifestShader) -> string {
	return filepath.join(
		{manifest.output_dir, fmt.tprintf("%s.deps", shader.name)},
		context.temp_allocator,
	) or_else ""
}

// Parses make-style depfile syntax: `target: dep1 dep2 \` with optional
// line continuations and backslash-escaped spaces. Returns the dependency
// paths; the target side is ignored.
manifest_parse_depfile :: proc(data: string, allocator := context.temp_allocator) -> []string {
	text, _ := strings.replace_all(data, "\\\r\n", " ", context.temp_allocator)
	text, _ = strings.replace_all(text, "\\\n", " ", context.temp_allocator)
	colon := strings.index_byte(text, ':')
	if colon < 0 do return nil

	deps: [dynamic]string
	deps.allocator = allocator
	field: [dynamic]u8
	defer delete(field)
	flush := proc(deps: ^[dynamic]string, field: ^[dynamic]u8) {
		if len(field) == 0 do return
		append(deps, strings.clone(string(field[:]), deps.allocator))
		clear(field)
	}
	for i := colon + 1; i < len(text); i += 1 {
		c := text[i]
		if c == '\\' && i + 1 < len(text) && text[i + 1] == ' ' {
			append(&field, ' ')
			i += 1
			continue
		}
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			flush(&deps, &field)
			continue
		}
		append(&field, c)
	}
	flush(&deps, &field)
	return deps[:]
}

manifest_stage_paths :: proc(
	manifest: Manifest,
	shader: ManifestShader,
	stage: string,
	target: TargetSpec,
) -> (
	artifact: string,
	reflection: string,
) {
	stage_suffix := stage
	if stage == "vertex" do stage_suffix = "vert"
	if stage == "fragment" do stage_suffix = "frag"
	base := filepath.join(
		{manifest.output_dir, fmt.tprintf("%s.%s", shader.name, stage_suffix)},
		context.temp_allocator,
	) or_else ""
	artifact = fmt.tprintf("%s.%s", base, target.extension)
	reflection = fmt.tprintf("%s.%s.refl.json", base, target.extension)
	return
}

compile_manifest_stage :: proc(
	manifest: Manifest,
	shader: ManifestShader,
	stage, entrypoint: string,
	target: TargetSpec,
	slang_path: string,
) -> string {
	output, reflection := manifest_stage_paths(manifest, shader, stage, target)
	run_slang(
		slang_path,
		shader.source,
		entrypoint,
		target.slang_target,
		output,
		reflection,
	)
	manifest_normalize_mtime(output, reflection)
	return reflection
}

manifest_try_entry_points :: proc(reflection: string) -> ([]ManifestEntryPoint, bool) {
	data, read_error := os.read_entire_file(reflection, context.temp_allocator)
	if read_error != nil do return nil, false
	document: ModuleReflection
	unmarshal_error := json.unmarshal(data, &document, allocator = context.temp_allocator)
	if unmarshal_error != nil do return nil, false
	return document.entry_points, true
}

manifest_load_entry_points :: proc(reflection, source: string) -> []ManifestEntryPoint {
	entries, ok := manifest_try_entry_points(reflection)
	if !ok do fatal("failed to read reflection %s", reflection)
	if len(entries) == 0 do fatal("%s: no entry points found", source)
	seen: map[string]bool
	defer delete(seen)
	for entry in entries {
		if entry.stage != "vertex" && entry.stage != "fragment" && entry.stage != "compute" {
			fatal("%s: unsupported stage %s", reflection, entry.stage)
		}
		if entry.stage in seen {
			fatal(
				"%s: multiple %s entry points; only one per stage is supported",
				reflection,
				entry.stage,
			)
		}
		seen[entry.stage] = true
	}
	return entries
}

// slangc may skip rewriting an unchanged artifact while always rewriting its
// reflection. Keep their mtimes aligned so freshness remains stable.
manifest_normalize_mtime :: proc(artifact, reflection: string) {
	artifact_time, artifact_error := os.last_write_time_by_name(artifact)
	reflection_time, reflection_error := os.last_write_time_by_name(reflection)
	if artifact_error != nil || reflection_error != nil do return
	if time.diff(artifact_time, reflection_time) <= 0 do return
	data, read_error := os.read_entire_file(artifact, context.temp_allocator)
	if read_error != nil do return
	_ = os.write_entire_file(artifact, data)
}

manifest_shader_fresh :: proc(
	manifest_path: string,
	manifest: Manifest,
	targets: []TargetSpec,
	shader: ManifestShader,
	parameter_output: string,
	hot_reload: bool,
) -> bool {
	parameter_data, read_error := os.read_entire_file(parameter_output, context.temp_allocator)
	if read_error != nil do return false
	schema_marker := fmt.tprintf("goose-schema: %s", GENERATOR_SCHEMA)
	if !strings.contains(string(parameter_data), schema_marker) do return false
	// Baked and hot-reload glue differ without any input mtime changing;
	// the marker forces regeneration when the mode flips.
	if strings.contains(string(parameter_data), "// goose-hot-reload") != hot_reload do return false

	latest_input, manifest_error := os.last_write_time_by_name(manifest_path)
	if manifest_error != nil do return false
	source_time, source_error := os.last_write_time_by_name(shader.source)
	if source_error != nil do return false
	if time.diff(latest_input, source_time) > 0 do latest_input = source_time

	// Imported Slang modules are inputs too: slangc records them in the
	// depfile emitted during discovery. A missing depfile or missing
	// dependency means the shader has never been built correctly.
	deps_data, deps_error := os.read_entire_file(
		manifest_deps_path(manifest, shader),
		context.temp_allocator,
	)
	if deps_error != nil do return false
	for dep in manifest_parse_depfile(string(deps_data)) {
		dep_time, dep_error := os.last_write_time_by_name(dep)
		if dep_error != nil do return false
		if time.diff(latest_input, dep_time) > 0 do latest_input = dep_time
	}

	module_reflection := manifest_module_reflection_path(manifest, shader)
	entries, entries_ok := manifest_try_entry_points(module_reflection)
	if !entries_ok || len(entries) == 0 do return false

	outputs: [dynamic]string
	defer delete(outputs)
	append(&outputs, parameter_output, module_reflection)
	for target in targets {
		for entry in entries {
			artifact, reflection := manifest_stage_paths(manifest, shader, entry.stage, target)
			append(&outputs, artifact, reflection)
		}
	}
	for output in outputs {
		output_time, output_error := os.last_write_time_by_name(output)
		if output_error != nil do return false
		if time.diff(output_time, latest_input) > 0 do return false
	}
	return true
}

manifest_generate_content :: proc(
	manifest: Manifest,
	targets: []TargetSpec,
	shader: ManifestShader,
	parameter_output: string,
	reflections: [][dynamic]string,
	hot_reload: bool,
) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(
		&builder,
		`// Generated by goose/tools/build. Do not edit.
// goose-schema: %s
%spackage %s

import goose "%s"

`,
		GENERATOR_SCHEMA,
		"// goose-hot-reload\n" if hot_reload else "",
		manifest.package_name,
		manifest.goose_import,
	)
	if hot_reload {
		strings.write_string(&builder, "import \"core:fmt\"\nimport \"core:os\"\n\n")
	}
	for target, index in targets {
		if index == 0 {
			fmt.sbprintf(&builder, "when %s {{\n", target.condition)
		} else if target.condition != "" {
			fmt.sbprintf(&builder, "} else when %s {{\n", target.condition)
		} else {
			strings.write_string(&builder, "} else {\n")
		}
		body := generate_body(
			Options {
				name         = shader.name,
				package_name = manifest.package_name,
				goose_import = manifest.goose_import,
				output       = parameter_output,
				reflections  = reflections[index],
				platform     = target.platform,
				platform_set = true,
				hot_reload   = hot_reload,
			},
		)
		strings.write_string(&builder, body)
		delete(body)
	}
	strings.write_string(&builder, "}\n")
	return strings.clone(strings.to_string(builder)) or_else ""
}

build_manifest :: proc(options: ManifestOptions) {
	data, read_error := os.read_entire_file(options.path, context.temp_allocator)
	if read_error != nil do fatal("failed to read Goose manifest %s: %v", options.path, read_error)
	manifest: Manifest
	unmarshal_error := json.unmarshal(data, &manifest, allocator = context.temp_allocator)
	if unmarshal_error != nil do fatal("failed to parse Goose manifest %s: %v", options.path, unmarshal_error)
	if manifest.output_dir == "" || manifest.parameter_output_dir == "" do fatal("Goose manifest output paths are required")
	if manifest.package_name == "" || manifest.goose_import == "" do fatal("Goose manifest package settings are required")
	if len(manifest.shaders) == 0 do fatal("Goose manifest has no shaders")
	_ = os.mkdir_all(manifest.output_dir)
	_ = os.mkdir_all(manifest.parameter_output_dir)

	// One pool task per shader: slangc invocations dominate the build and
	// are independent between shaders, so they run concurrently. The pool
	// hands tasks to idle workers dynamically, which keeps a slow shader
	// from pinning a fixed chunk of queued work behind it.
	targets := manifest_targets(manifest)
	works := make([]ShaderWork, len(manifest.shaders), context.temp_allocator)
	pool: thread.Pool
	thread.pool_init(
		&pool,
		context.allocator,
		min(len(manifest.shaders), os.get_processor_core_count()),
	)
	thread.pool_start(&pool)
	for shader, index in manifest.shaders {
		if shader.name == "" || shader.source == "" do fatal("Goose shader name and source are required")
		works[index] = ShaderWork {
			manifest_path = options.path,
			manifest      = &manifest,
			targets       = targets,
			shader        = shader,
			slang         = options.slang,
			hot_reload    = options.hot_reload,
		}
		thread.pool_add_task(&pool, context.allocator, build_shader_task, &works[index])
	}
	// The main thread also processes tasks, then blocks until the pool drains.
	thread.pool_finish(&pool)
	thread.pool_destroy(&pool)
}

// Shared read-only inputs for one shader's pool task. `manifest` points at
// the build_manifest stack frame, which outlives the pool.
ShaderWork :: struct {
	manifest_path: string,
	manifest:      ^Manifest,
	targets:       []TargetSpec,
	shader:        ManifestShader,
	slang:         string,
	hot_reload:    bool,
}

build_shader_task :: proc(task: thread.Task) {
	work := cast(^ShaderWork)task.data
	build_shader(work.manifest_path, work.manifest^, work.targets, work.shader, work.slang, work.hot_reload)
}

build_shader :: proc(
	manifest_path: string,
	manifest: Manifest,
	targets: []TargetSpec,
	shader: ManifestShader,
	slang: string,
	hot_reload: bool,
) {
	parameter_output := filepath.join(
		{
			manifest.parameter_output_dir,
			fmt.tprintf("%s_shader_parameters.odin", shader.name),
		},
		context.temp_allocator,
	) or_else ""
	if manifest_shader_fresh(
		manifest_path,
		manifest,
		targets,
		shader,
		parameter_output,
		hot_reload,
	) {
		log_printfln("goose: %s up to date", shader.name)
		return
	}

	module_reflection := manifest_module_reflection_path(manifest, shader)
	run_slang_discovery(
		slang,
		shader.source,
		module_reflection,
		manifest_deps_path(manifest, shader),
	)
	entries := manifest_load_entry_points(module_reflection, shader.source)
	reflections := make([][dynamic]string, len(targets), context.temp_allocator)
	for target, target_index in targets {
		for entry in entries {
			append_elem(
				&reflections[target_index],
				compile_manifest_stage(
					manifest,
					shader,
					entry.stage,
					entry.name,
					target,
					slang,
				),
			)
		}
	}

	content := manifest_generate_content(
		manifest,
		targets,
		shader,
		parameter_output,
		reflections,
		hot_reload,
	)
	write_error := os.write_entire_file(parameter_output, content)
	if write_error != nil do fatal("failed to write %s: %v", parameter_output, write_error)
	delete(content)
	for target_reflections in reflections do delete(target_reflections)
}

try_build_manifest :: proc() -> bool {
	options, ok := parse_manifest_options()
	if !ok do return false
	build_manifest(options)
	return true
}
