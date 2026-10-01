package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import goose "../vendor/goose/src"

// Watches src/shaders for .slang edits. On change, reruns goose-build (its
// depfile freshness recompiles only affected scenes), then rebuilds
// pipelines by re-calling the runtime-loading glue procs. Requires
// hot-reload glue (`make run` / `make debug`, --hot-reload) and the
// project root as working directory.
//
// Constraint: blob code is reloaded, reflection is not. Edits that change
// entry point names, bindings, or uniform layouts need an app restart.

HOT_RELOAD_DEBOUNCE_MS :: 200
SHADER_DIR :: "src/shaders"

HotReload :: struct {
	mtimes:        map[string]time.Time,
	initialized:   bool,
	pending:       bool,
	pending_since: u64,
}

hot_reload_scan :: proc(hr: ^HotReload) -> bool {
	entries, read_error := os.read_directory_by_path(SHADER_DIR, 0, context.temp_allocator)
	if read_error != nil do return false

	changed := false
	current: map[string]bool
	defer delete(current)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".slang") do continue
		current[entry.fullpath] = true
		mod_time := entry.modification_time
		known, exists := hr.mtimes[entry.fullpath]
		if !exists {
			if hr.initialized do changed = true // new file after startup
		} else if known != mod_time {
			changed = true
		}
		if !exists || known != mod_time {
			hr.mtimes[strings.clone(entry.fullpath)] = mod_time
		}
	}
	// A deleted file invalidates the build too; slangc will fail and the
	// previous pipelines stay in place.
	removed: [dynamic]string
	defer delete(removed)
	for path in hr.mtimes {
		if path not_in current {
			changed = true
			append(&removed, path)
		}
	}
	for path in removed {
		delete_key(&hr.mtimes, path)
		delete(path)
	}
	hr.initialized = true
	return changed
}

hot_reload_build :: proc() -> bool {
	slang := os.get_env("SLANG", context.temp_allocator)
	if slang == "" {
		slang = "vendor/slang/bin/slangc"
	}
	command := []string {
		"vendor/goose/goose-build",
		"--manifest",
		"goose.json",
		"--slang",
		slang,
		"--hot-reload",
	}
	state, stdout, stderr, process_error := os.process_exec(
		{command = command},
		context.temp_allocator,
	)
	if len(stdout) > 0 do fmt.print(string(stdout))
	if process_error != nil {
		fmt.eprintfln("hot reload: failed to run goose-build: %v", process_error)
		return false
	}
	if !state.success {
		if len(stderr) > 0 do fmt.eprint(string(stderr))
		fmt.eprintln("hot reload: shader build failed, keeping previous pipelines")
		return false
	}
	return true
}

hot_reload_scene :: proc(gpu: ^sdl.GPUDevice, scene: ^Scene) {
	pipeline := create_compute_pipeline(gpu, scene.glue)
	if pipeline == nil do return

	old := scene.pipeline
	scene.pipeline = pipeline
	sdl.ReleaseGPUComputePipeline(gpu, old)
	fmt.printfln("hot reload: %s", scene.title)
}

hot_reload_poll :: proc(hr: ^HotReload, gpu: ^sdl.GPUDevice, scenes: []Scene) {
	when !HOT_RELOAD do return

	if hot_reload_scan(hr) {
		hr.pending = true
		hr.pending_since = sdl.GetTicks()
	}
	if hr.pending && sdl.GetTicks() - hr.pending_since >= HOT_RELOAD_DEBOUNCE_MS {
		hr.pending = false
		if !hot_reload_build() do return
		for &scene in scenes {
			hot_reload_scene(gpu, &scene)
		}
	}
}

// Runtime-loaded blobs are owned by the caller; baked blobs point into
// static #load data and must never be freed.
free_blob_if_hot :: proc(glue: goose.GraphicsParameters) {
	when HOT_RELOAD {
		if glue.code.blob.size > 0 {
			delete(glue.code.blob.data[:glue.code.blob.size])
		}
	}
}
