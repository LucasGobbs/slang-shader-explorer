package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:log"
import "core:strings"
import "core:time"

PIPELINE_SCHEMA_VERSION :: 1

// graph.json is both the node-editor document and the runtime pipeline
// manifest. Node positions are presentation state; links are semantic.
// Shader reflection remains authoritative for pass interfaces and pin types.
SgGraphNodeJson :: struct {
	key:  string,
	kind: string,
	x:    f32,
	y:    f32,
	// Set only on user-authored resource nodes ("uimg:"/"uobj:" keys).
	file: string,
}

SgGraphLinkJson :: struct {
	from: string,
	to:   string,
}

SgGraphJson :: struct {
	version: int,
	scene:   string,
	nodes:   []SgGraphNodeJson,
	links:   []SgGraphLinkJson,
}

PipelineRoute :: struct {
	producer:      int,
	consumer:      int,
	consumer_input: string, // owned
}

PipelinePlan :: struct {
	order:       [dynamic]int,
	routes:      [dynamic]PipelineRoute,
	output_pass: int,
}

pipeline_graph_path :: proc(scene: string) -> string {
	return fmt.tprintf("%s/%s/graph.json", SCENES_DIR, scene)
}

pipeline_plan_destroy :: proc(plan: ^PipelinePlan) {
	for &route in plan.routes do delete(route.consumer_input)
	delete(plan.routes)
	delete(plan.order)
	plan^ = {}
}

pipeline_endpoint :: proc(node_key, pin_name: string) -> string {
	return fmt.tprintf("%s:%s", node_key, pin_name)
}

pipeline_find_pass_endpoint :: proc(
	scene: ^RuntimeScene,
	endpoint: string,
) -> (pass_index: int, pin_name: string, found: bool) {
	for &pass, i in scene.passes {
		prefix := fmt.tprintf("%s:", pass.graph_key)
		if strings.has_prefix(endpoint, prefix) {
			return i, endpoint[len(prefix):], true
		}
	}
	return -1, "", false
}

pipeline_pass_has_input :: proc(pass: ^ScenePass, name: string) -> bool {
	for input_name in pass.sampler_textures {
		if input_name == name do return true
	}
	return false
}

pipeline_default_input :: proc(pass: ^ScenePass) -> string {
	for name in pass.sampler_textures {
		if name == "input_tex" do return name
	}
	for name in pass.sampler_textures {
		if name != "" do return name
	}
	return ""
}

pipeline_plan_default :: proc(scene: ^RuntimeScene) -> PipelinePlan {
	plan: PipelinePlan
	plan.output_pass = len(scene.passes) - 1
	for i in 0 ..< len(scene.passes) do append(&plan.order, i)
	for i := 1; i < len(scene.passes); i += 1 {
		input_name := pipeline_default_input(&scene.passes[i])
		if input_name == "" do continue
		append(
			&plan.routes,
			PipelineRoute {
				producer = i - 1,
				consumer = i,
				consumer_input = strings.clone(input_name),
			},
		)
	}
	return plan
}

pipeline_plan_build :: proc(
	scene: ^RuntimeScene,
	doc: ^SgGraphJson,
) -> (plan: PipelinePlan, error_message: string, ok: bool) {
	n := len(scene.passes)
	if n == 0 do return {}, "pipeline has no reflected passes", false
	if doc.scene != "" && doc.scene != scene.title {
		return {}, fmt.tprintf("graph scene '%s' does not match '%s'", doc.scene, scene.title), false
	}
	if doc.version != 0 && doc.version != PIPELINE_SCHEMA_VERSION {
		return {}, fmt.tprintf("unsupported graph schema version %d", doc.version), false
	}

	indegree := make([]int, n, context.temp_allocator)
	authoritative := doc.version == PIPELINE_SCHEMA_VERSION
	outdegree := make([]int, n, context.temp_allocator)
	adj := make([][dynamic]int, n, context.temp_allocator)
	incoming := make(map[string]bool, n * 2, context.temp_allocator)
	output_seen := false
	plan.output_pass = -1
	pass_edges := 0

	for link in doc.links {
		producer, output_pin, producer_ok := pipeline_find_pass_endpoint(scene, link.from)
		if !producer_ok do continue // params/assets are app-injected resources

		if link.to == "show2d:frame" {
			if output_seen {
				pipeline_plan_destroy(&plan)
				return {}, "pipeline has more than one viewport output", false
			}
			if output_pin == "" {
				pipeline_plan_destroy(&plan)
				return {}, fmt.tprintf("invalid output endpoint '%s'", link.from), false
			}
			plan.output_pass = producer
			output_seen = true
			continue
		}

		consumer, input_name, consumer_ok := pipeline_find_pass_endpoint(scene, link.to)
		if !consumer_ok do continue
		if producer == consumer {
			pipeline_plan_destroy(&plan)
			return {}, fmt.tprintf("self-cycle at %s", scene.passes[producer].name), false
		}
		if !pipeline_pass_has_input(&scene.passes[consumer], input_name) {
			pipeline_plan_destroy(&plan)
			return {}, fmt.tprintf("%s has no sampled texture input '%s'", scene.passes[consumer].name, input_name), false
		}
		input_key := fmt.tprintf("%d:%s", consumer, input_name)
		if incoming[input_key] {
			pipeline_plan_destroy(&plan)
			return {}, fmt.tprintf("input %s.%s has more than one producer", scene.passes[consumer].name, input_name), false
		}
		incoming[input_key] = true
		append(
			&plan.routes,
			PipelineRoute {
				producer = producer,
				consumer = consumer,
				consumer_input = strings.clone(input_name),
			},
		)
		append(&adj[producer], consumer)
		indegree[consumer] += 1
		outdegree[producer] += 1
		pass_edges += 1
	}

	// Legacy documents without semantic links migrate to declaration order.
	if !authoritative && !output_seen && pass_edges == 0 {
		pipeline_plan_destroy(&plan)
		return pipeline_plan_default(scene), "", true
	}
	if plan.output_pass < 0 {
		pipeline_plan_destroy(&plan)
		return {}, "pipeline has no viewport output", false
	}

	// Stable Kahn sort: original reflection order breaks ties.
	removed := make([]bool, n, context.temp_allocator)
	for len(plan.order) < n {
		picked := -1
		for i in 0 ..< n {
			if !removed[i] && indegree[i] == 0 {
				picked = i
				break
			}
		}
		if picked < 0 {
			pipeline_plan_destroy(&plan)
			return {}, "pipeline graph contains a cycle", false
		}
		removed[picked] = true
		append(&plan.order, picked)
		for consumer in adj[picked] do indegree[consumer] -= 1
	}
	return plan, "", true
}

pipeline_plan_load :: proc(scene: ^RuntimeScene) -> (PipelinePlan, string, bool) {
	path := pipeline_graph_path(scene.title)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return pipeline_plan_default(scene), "", true
	}
	doc: SgGraphJson
	if parse_error := json.unmarshal(data, &doc, allocator = context.temp_allocator); parse_error != nil {
		return {}, fmt.tprintf("could not parse %s", path), false
	}
	return pipeline_plan_build(scene, &doc)
}

pipeline_plan_source :: proc(plan: ^PipelinePlan, consumer: int, input_name: string) -> int {
	for route in plan.routes {
		if route.consumer == consumer && route.consumer_input == input_name do return route.producer
	}
	return -1
}

pipeline_plan_path :: proc(plan: ^PipelinePlan, pass_count: int) -> [DEBUG_WATCH_MAX_PASSES]bool {
	path: [DEBUG_WATCH_MAX_PASSES]bool
	if plan.output_pass < 0 || plan.output_pass >= min(pass_count, DEBUG_WATCH_MAX_PASSES) do return path
	path[plan.output_pass] = true
	changed := true
	for changed {
		changed = false
		for route in plan.routes {
			if route.consumer >= DEBUG_WATCH_MAX_PASSES || route.producer >= DEBUG_WATCH_MAX_PASSES do continue
			if path[route.consumer] && !path[route.producer] {
				path[route.producer] = true
				changed = true
			}
		}
	}
	return path
}

pipeline_plan_equal :: proc(a, b: ^PipelinePlan) -> bool {
	if a.output_pass != b.output_pass || len(a.order) != len(b.order) || len(a.routes) != len(b.routes) do return false
	for value, i in a.order do if b.order[i] != value do return false
	for route in a.routes {
		found := false
		for other in b.routes {
			if route.producer == other.producer && route.consumer == other.consumer &&
			   route.consumer_input == other.consumer_input {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

pipeline_scene_init :: proc(scene: ^RuntimeScene) -> bool {
	candidate, _, ok := pipeline_plan_load(scene)
	if !ok do return false
	scene.pipeline = candidate
	path := pipeline_graph_path(scene.title)
	if info, err := os.stat(path, context.temp_allocator); err == nil {
		scene.pipeline_mtime = info.modification_time
	}
	return true
}

// JSON-only edits do not require recompiling shaders. Invalid candidates keep
// the last known-good plan and surface one error per file modification.
pipeline_scene_refresh :: proc(scene: ^RuntimeScene) {
	path := pipeline_graph_path(scene.title)
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil do return
	if time.diff(info.modification_time, scene.pipeline_mtime) == 0 do return
	scene.pipeline_mtime = info.modification_time

	candidate, error_message, ok := pipeline_plan_load(scene)
	if !ok {
		delete(scene.pipeline_error)
		scene.pipeline_error = strings.clone(error_message)
		log.warnf("pipeline rejected for %s: %s; keeping last valid plan", scene.title, error_message)
		notify(.ERROR, "pipeline: %s", error_message)
		return
	}
	if pipeline_plan_equal(&scene.pipeline, &candidate) {
		pipeline_plan_destroy(&candidate)
		delete(scene.pipeline_error)
		scene.pipeline_error = ""
		return
	}
	pipeline_plan_destroy(&scene.pipeline)
	scene.pipeline = candidate
	delete(scene.pipeline_error)
	scene.pipeline_error = ""
	notify(.INFO, "pipeline updated: %s", scene.title)
	log.infof("pipeline updated for %s: %d passes, %d routes", scene.title, len(scene.pipeline.order), len(scene.pipeline.routes))
}
