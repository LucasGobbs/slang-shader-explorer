// Scene architecture graph, docked in the sidebar's GRAPH mode (F2 jumps
// to it). The graph reflects how the active scene unit is built, it is not
// a material editor: one params node (the uniforms/resources the app
// feeds), one graphics node per vertex+fragment entry pair found in the
// scene's files, one compute node per compute entry. Passes chain in
// declaration order — a graphics node's frame output feeds the next pass's
// first texture input (e.g. phong 3D → blur compute: params → graphics →
// compute). Links are derived from the source on a 120-frame rescan; they
// are not user-editable. The node layout persists in the scene's
// graph.json. All state lives here in Odin; the C++ side only renders.
//
// Pan with two fingers on the trackpad (wheel deltas adjust the editor
// panning); middle-drag also pans (imnodes built-in).
package main

import im "../vendor/odin-imgui"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

foreign import ine "../vendor/imnodes/libine.a"

@(default_calling_convention = "c")
foreign ine {
	ine_create :: proc() -> rawptr ---
	ine_destroy :: proc(ed: rawptr) ---
	ine_editor_begin :: proc(ed: rawptr) ---
	ine_editor_end :: proc(ed: rawptr) ---
	ine_minimap :: proc(ed: rawptr, size_fraction: f32, location: c.int) ---
	ine_begin_node :: proc(ed: rawptr, id: c.int) ---
	ine_end_node :: proc(ed: rawptr) ---
	ine_title_bar_begin :: proc(ed: rawptr) ---
	ine_title_bar_end :: proc(ed: rawptr) ---
	ine_input_attr_begin :: proc(ed: rawptr, id: c.int, shape: c.int) ---
	ine_input_attr_end :: proc(ed: rawptr) ---
	ine_output_attr_begin :: proc(ed: rawptr, id: c.int, shape: c.int) ---
	ine_output_attr_end :: proc(ed: rawptr) ---
	ine_static_attr_begin :: proc(ed: rawptr, id: c.int) ---
	ine_static_attr_end :: proc(ed: rawptr) ---
	ine_link :: proc(ed: rawptr, id: c.int, start_attr: c.int, end_attr: c.int) ---
	ine_set_node_grid_pos :: proc(ed: rawptr, id: c.int, x: f32, y: f32) ---
	ine_get_node_grid_pos :: proc(ed: rawptr, id: c.int, x: ^f32, y: ^f32) ---
	ine_get_panning :: proc(ed: rawptr, x: ^f32, y: ^f32) ---
	ine_reset_panning :: proc(ed: rawptr, x: f32, y: f32) ---
	ine_is_editor_hovered :: proc(ed: rawptr) -> bool ---
	ine_push_color_style :: proc(ed: rawptr, col: c.int, color: u32) ---
	ine_pop_color_style :: proc(ed: rawptr) ---
}

// ImNodesCol_ slots used below.
INE_COL_TITLE_BAR          :: 4
INE_COL_TITLE_BAR_HOVERED  :: 5
INE_COL_TITLE_BAR_SELECTED :: 6
INE_COL_PIN                :: 10
INE_COL_PIN_HOVERED        :: 11

// The three node types. Pins distinguish them too: params = circle,
// graphics = triangle, compute = quad (all filled).
SgPassKind :: enum { PARAMS, GRAPHICS, COMPUTE }

SG_KIND_TAGS := [SgPassKind]string {
	.PARAMS   = "params",
	.GRAPHICS = "graphics",
	.COMPUTE  = "compute",
}

// Colors are ABGR-packed (a<<24|b<<16|g<<8|r) like col32() produces, written
// as constant expressions because global initializers can't call procs.
SG_KIND_COLORS := [SgPassKind]u32 {
	.PARAMS   = 0xFF << 24 | 0xC4 << 16 | 0x71 << 8 | 0x6C, // violet
	.GRAPHICS = 0xFF << 24 | 0x16 << 16 | 0x4B << 8 | 0xCB, // orange
	.COMPUTE  = 0xFF << 24 | 0xD2 << 16 | 0x8B << 8 | 0x26, // blue
}

// imnodes pin shapes: 1 = CircleFilled, 3 = TriangleFilled, 5 = QuadFilled.
SG_KIND_PIN_SHAPES := [SgPassKind]c.int {
	.PARAMS   = 1,
	.GRAPHICS = 3,
	.COMPUTE  = 5,
}

SG_PIN_IN_COLOR  :: 0xFF << 24 | 0xE0 << 16 | 0xE0 << 8 | 0xE0 // white
SG_PIN_OUT_COLOR :: 0xFF << 24 | 0x2E << 16 | 0xE2 << 8 | 0xA6 // green

SgPin :: struct {
	id:    int,
	name:  string, // owned
	input: bool,
}

SgNode :: struct {
	id:     int,
	key:    string, // "params", "gfx:scenes/apple/apple", "comp:...:computeMain"; owned
	title:  string, // display name; owned
	kind:   SgPassKind,
	file:   string, // owning slang file ("" for params); owned
	pins:   [dynamic]SgPin,
	pos:    [2]f32,
	placed: bool,
}

SgLink :: struct { id, from, to: int }

NodeGraph :: struct {
	handle:      rawptr,
	nodes:       [dynamic]SgNode,
	links:       [dynamic]SgLink,
	next_id:     int,
	// Stable imnodes ids per string key ("node:gfx:...", "pin:...:Uniforms",
	// "link:3:7") so rescanning keeps node positions.
	ids:         map[string]int,
	spawn_count: int,
	sync_frame:  int,
	// The scene unit this graph belongs to ("" before the first frame) and
	// the layout loaded from its graph.json (node key -> grid pos).
	scene:       string,
	layout:      map[string][2]f32,
	// A node's "+" button was clicked this frame: open the create popup.
	create_open: bool,
}

// Stable id for a namespaced key.
sg_id :: proc(ng: ^NodeGraph, key: string) -> int {
	if v, ok := ng.ids[key]; ok do return v
	v := ng.next_id
	ng.next_id += 1
	ng.ids[strings.clone(key)] = v
	return v
}

// --- Lightweight .slang interface parsing ---------------------------------
// All parsed strings are slices into the file text, which the caller owns
// for the duration of a sync pass.

SgBindKind :: enum { CBUFFER, TEXTURE, SAMPLER, RWTEXTURE }

SgBinding :: struct {
	name: string,
	kind: SgBindKind,
}

SgEntryKind :: enum { COMPUTE, VERTEX, FRAGMENT }

SgEntry :: struct {
	kind: SgEntryKind,
	name: string,
	line: int,
}

SgFileInfo :: struct {
	text:     string, // owned by the sync pass
	bind_in:  [dynamic]SgBinding,
	bind_out: [dynamic]SgBinding, // RWTexture outputs
	entries:  [dynamic]SgEntry,
}

sg_is_ident :: proc(b: u8) -> bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

sg_last_word :: proc(s: string) -> string {
	t := strings.trim_space(s)
	for i := len(t) - 1; i >= 0; i -= 1 {
		if !sg_is_ident(t[i]) {
			return t[i + 1:]
		}
	}
	return t
}

// Extracts the variable name from a binding declaration line: the
// identifier right before the trailing ';'.
sg_binding_name :: proc(line: string) -> (string, bool) {
	semi := strings.index(line, ";")
	if semi < 0 do return "", false
	name := sg_last_word(line[:semi])
	if name == "" || name == "SamplerState" do return "", false
	return name, true
}

sg_parse_file :: proc(text: string) -> SgFileInfo {
	info: SgFileInfo
	info.text = text
	pending := -1 // SgEntryKind of the last [shader("...")] attribute, -1 none
	for line, lineno in strings.split_lines(text, context.temp_allocator) {
		if line == "" do continue
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "//") do continue
		if strings.has_prefix(trimmed, `[shader("`) {
			rest := trimmed[len(`[shader("`):]
			if end := strings.index(rest, `"`); end > 0 {
				switch rest[:end] {
				case "compute":  pending = int(SgEntryKind.COMPUTE)
				case "vertex":   pending = int(SgEntryKind.VERTEX)
				case "fragment": pending = int(SgEntryKind.FRAGMENT)
				}
			}
			continue
		}
		if line[0] == ' ' || line[0] == '\t' || line[0] == '/' || line[0] == '[' do continue
		rest := line
		if strings.has_prefix(rest, "public ") do rest = rest[len("public "):]
		switch {
		case strings.contains(rest, "RWTexture"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_out, SgBinding{name, .RWTEXTURE})
			}
		case strings.contains(rest, "ConstantBuffer<"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .CBUFFER})
			}
		case strings.contains(rest, "Texture2D<"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .TEXTURE})
			}
		case strings.has_prefix(rest, "SamplerState"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .SAMPLER})
			}
		case strings.contains(rest, "(") && !strings.has_suffix(trimmed, ";"):
			// Top-level function definition: name is the word before '('. A
			// pending [shader("...")] attribute makes it an entry point.
			name := sg_last_word(rest[:strings.index(rest, "(")])
			if pending >= 0 && name != "" {
				append(&info.entries, SgEntry{SgEntryKind(pending), name, lineno})
				pending = -1
			}
		}
	}
	return info
}

sg_free_info :: proc(info: ^SgFileInfo) {
	delete(info.text)
	delete(info.bind_in)
	delete(info.bind_out)
	delete(info.entries)
}

// --- graph.json persistence ------------------------------------------------
// The scene unit's node structure: nodes carry the persisted layout, links
// document the derived structure (regenerated from source on load, so the
// file is descriptive, not authoritative — authored links come with
// codegen).

SgGraphNodeJson :: struct {
	key: string,
	kind: string,
	x:   f32,
	y:   f32,
}

SgGraphLinkJson :: struct {
	from: string,
	to:   string,
}

SgGraphJson :: struct {
	scene: string,
	nodes: []SgGraphNodeJson,
	links: []SgGraphLinkJson,
}

sg_graph_path :: proc(scene: string) -> string {
	return fmt.tprintf("%s/scenes/%s/graph.json", SHADER_DIR, scene)
}

sg_load_layout :: proc(ng: ^NodeGraph, scene: string) {
	data, err := os.read_entire_file(sg_graph_path(scene), context.temp_allocator)
	if err != nil do return
	gj: SgGraphJson
	if json.unmarshal(data, &gj, allocator = context.temp_allocator) != nil do return
	for n in gj.nodes {
		ng.layout[strings.clone(n.key)] = {n.x, n.y}
	}
}

sg_save :: proc(ng: ^NodeGraph) {
	if ng.scene == "" || len(ng.nodes) == 0 do return
	// Reverse lookup: pin id -> "node key:pin" for the link endpoints.
	pin_names := make(map[int]string, 64, context.temp_allocator)
	for &n in ng.nodes {
		for &p in n.pins {
			pin_names[p.id] = fmt.tprintf("%s:%s", n.key, p.name)
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"scene":"`)
	strings.write_string(&sb, ng.scene)
	strings.write_string(&sb, `","nodes":[`)
	for &n, i in ng.nodes {
		if i > 0 do strings.write_byte(&sb, ',')
		x, y: f32
		ine_get_node_grid_pos(ng.handle, c.int(n.id), &x, &y)
		// No braces in fmt formats: Odin's fmt treats '{' as a directive.
		strings.write_string(&sb, `{"key":"`)
		strings.write_string(&sb, n.key)
		strings.write_string(&sb, `","kind":"`)
		strings.write_string(&sb, SG_KIND_TAGS[n.kind])
		fmt.sbprintf(&sb, `","x":%.1f,"y":%.1f`, x, y)
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, `],"links":[`)
	for l, i in ng.links {
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, `{"from":"`)
		strings.write_string(&sb, pin_names[l.from])
		strings.write_string(&sb, `","to":"`)
		strings.write_string(&sb, pin_names[l.to])
		strings.write_string(&sb, `"}`)
	}
	strings.write_string(&sb, `]}`)
	if os.write_entire_file(sg_graph_path(ng.scene), transmute([]u8)strings.to_string(sb)) != nil {
		fmt.eprintfln("[node-graph] failed to write %s", sg_graph_path(ng.scene))
	}
}

sg_clear_graph :: proc(ng: ^NodeGraph) {
	for &n in ng.nodes {
		for &p in n.pins do delete(p.name)
		delete(n.pins)
		delete(n.key)
		delete(n.title)
		delete(n.file)
	}
	clear(&ng.nodes)
	clear(&ng.links)
	ng.spawn_count = 0
	for k, _ in ng.layout do delete(k)
	clear(&ng.layout)
	delete(ng.scene)
	ng.scene = ""
}

// --- Graph construction ----------------------------------------------------

// One render pass found in the scene's files.
SgPassDesc :: struct {
	key:   string,
	title: string,
	file:  string,
	kind:  SgPassKind,
	order: int, // file list index * 10000 + entry line
}

// Templates for passes created from a node's "+" button: a chained pass
// samples the previous pass's frame via input_tex and produces its own
// output. The file lands in the scene unit's directory; the graph picks it
// up on the next sync and chains it (passes order by file name, so
// pass_1 < pass_2 < ...).
SG_TEMPLATE_COMPUTE :: `// Compute pass created from the node graph. Reads the previous pass's
// frame (input_tex) and writes out_tex; replace the passthrough with
// your effect.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 uv = (float2(id.xy) + 0.5) / Uniforms.iResolution.xy;
    out_tex[id.xy] = input_tex.Sample(input_sampler, uv);
}
`

SG_TEMPLATE_GRAPHICS :: `// Graphics pass created from the node graph. Fullscreen triangle sampling
// the previous pass's frame (input_tex); replace the passthrough with
// your shading.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    return input_tex.Sample(input_sampler, uv);
}
`

// Creates a pass file (pass_N.slang) in the current scene's directory from
// the kind's template and forces a graph resync. Returns the new file's
// rel name ("" on failure).
sg_create_pass :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, kind: SgPassKind) -> string {
	dir := fmt.tprintf("%s/scenes/%s", SHADER_DIR, ng.scene)
	source := kind == .GRAPHICS ? SG_TEMPLATE_GRAPHICS : SG_TEMPLATE_COMPUTE
	for n := 1; n < 100; n += 1 {
		name := fmt.tprintf("pass_%d", n)
		path := fmt.tprintf("%s/%s.slang", dir, name)
		if os.exists(path) do continue
		if os.write_entire_file(path, transmute([]u8)source) != nil {
			fmt.eprintfln("[node-graph] failed to write %s", path)
			return ""
		}
		fmt.printfln("[node-graph] created %s", path)
		ied_rescan(ed)
		ng.sync_frame = 0 // force resync on the next panel frame
		return fmt.tprintf("scenes/%s/%s", ng.scene, name)
	}
	return ""
}

sg_add_pin :: proc(ng: ^NodeGraph, node: ^SgNode, name: string, input: bool) {
	key := fmt.tprintf("pin:%s:%s", node.key, name)
	append(&node.pins, SgPin{id = sg_id(ng, key), name = strings.clone(name), input = input})
}

sg_upsert_node :: proc(ng: ^NodeGraph, d: SgPassDesc) -> ^SgNode {
	for &n in ng.nodes {
		if n.key == d.key do return &n
	}
	pos, has_layout := ng.layout[d.key]
	if !has_layout {
		col := ng.spawn_count % 3
		row := ng.spawn_count / 3
		pos = {40 + f32(col) * 240, 40 + f32(row) * 220}
		ng.spawn_count += 1
	}
	append(
		&ng.nodes,
		SgNode {
			id    = sg_id(ng, fmt.tprintf("node:%s", d.key)),
			key   = strings.clone(d.key),
			title = strings.clone(d.title),
			kind  = d.kind,
			file  = strings.clone(d.file),
			pos   = pos,
		},
	)
	return &ng.nodes[len(ng.nodes) - 1]
}

// Rebuilds the architecture graph for the current scene unit: one params
// node plus one node per render pass (graphics = vertex/fragment entries,
// compute = compute entry) found in the scene's files, linked params ->
// pass inputs and pass output -> next pass's first texture input. Runs on
// the first frame of a scene and then every 120 frames; node ids are
// stable across passes so imnodes keeps the user's layout.
sg_sync :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor) {
	ng.sync_frame += 1
	if ng.sync_frame > 1 && ng.sync_frame % 120 != 1 do return

	entry := fmt.tprintf("scenes/%s/%s", ng.scene, ng.scene)
	// The architecture is the scene unit's own files: the entry first,
	// then scene-owned modules sorted by name (pass_1 < pass_2 < ...) so
	// the chain order matches creation order.
	files := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&files, entry)
	prefix := fmt.tprintf("scenes/%s/", ng.scene)
	for f in ed.files {
		if f == entry do continue
		if strings.has_prefix(f, prefix) do append(&files, f)
	}
	slice.sort(files[1:])

	// Parse every file in the closure once.
	infos: map[string]SgFileInfo
	defer {
		for _, &info in infos do sg_free_info(&info)
		delete(infos)
	}
	for f in files {
		path := fmt.tprintf("%s/%s.slang", SHADER_DIR, f)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do continue
		infos[f] = sg_parse_file(string(data))
	}

	// Collect the passes in declaration order (closure order, then entry
	// line inside each file).
	passes := make([dynamic]SgPassDesc, 0, 8, context.temp_allocator)
	for f, file_idx in files {
		info, ok := infos[f]
		if !ok do continue
		base := f
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		gfx_line := -1
		compute_entries := 0
		for e in info.entries {
			if e.kind == .COMPUTE do compute_entries += 1
		}
		pass_count := 0
		for e in info.entries {
			if e.kind == .COMPUTE {
				title := base
				if compute_entries > 1 do title = e.name
				append(
					&passes,
					SgPassDesc {
						key   = fmt.tprintf("comp:%s:%s", f, e.name),
						title = title,
						file  = f,
						kind  = .COMPUTE,
						order = file_idx * 10000 + e.line,
					},
				)
				pass_count += 1
			} else if gfx_line < 0 {
				gfx_line = e.line
			}
		}
		if gfx_line >= 0 {
			append(
				&passes,
				SgPassDesc {
					key   = fmt.tprintf("gfx:%s", f),
					title = base,
					file  = f,
					kind  = .GRAPHICS,
					order = file_idx * 10000 + gfx_line,
				},
			)
		}
		// Passes inside one file keep declaration order.
		// (closure order is already the outer loop's)
		for i := len(passes) - pass_count; i < len(passes); i += 1 {
			for j := i + 1; j < len(passes); j += 1 {
				if passes[j].order < passes[i].order {
					passes[i], passes[j] = passes[j], passes[i]
				}
			}
		}
	}

	// Drop nodes for passes that vanished (file edited, import removed).
	for i := len(ng.nodes) - 1; i >= 0; i -= 1 {
		node := &ng.nodes[i]
		if node.kind == .PARAMS do continue
		alive := false
		for p in passes {
			if p.key == node.key {
				alive = true
				break
			}
		}
		if !alive {
			for &p in node.pins do delete(p.name)
			delete(node.pins)
			delete(node.key)
			delete(node.title)
			delete(node.file)
			ordered_remove(&ng.nodes, i)
		}
	}
	clear(&ng.links)

	// Chain-fed inputs (pass[i]'s first texture input fed by pass[i-1]'s
	// output) come from the previous pass, not from params.
	chain_fed := make(map[string]bool, 8, context.temp_allocator)
	for i := 1; i < len(passes); i += 1 {
		prev_info := infos[passes[i - 1].file]
		prev_has_out := passes[i - 1].kind == .GRAPHICS || len(prev_info.bind_out) > 0
		if !prev_has_out do continue
		info := infos[passes[i].file]
		for b in info.bind_in {
			if b.kind != .TEXTURE do continue
			chain_fed[fmt.tprintf("%s:%s", passes[i].key, b.name)] = true
			break
		}
	}

	// Params node: one output per resource the passes consume from the app
	// (chain-fed inputs excluded). Titled after the scene so the title bar
	// reads "apple · params".
	params := sg_upsert_node(ng, SgPassDesc{key = "params", title = ng.scene, kind = .PARAMS})
	for &p in params.pins do delete(p.name)
	clear(&params.pins)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for pd in passes {
		info := infos[pd.file]
		for b in info.bind_in {
			if chain_fed[fmt.tprintf("%s:%s", pd.key, b.name)] do continue
			if seen[b.name] do continue
			seen[b.name] = true
			sg_add_pin(ng, params, b.name, false)
		}
	}

	// Pass nodes: inputs are their bindings, output is the frame they
	// produce (graphics) or their RWTexture(s) (compute).
	for pd in passes {
		node := sg_upsert_node(ng, pd)
		for &p in node.pins do delete(p.name)
		clear(&node.pins)
		info := infos[pd.file]
		for b in info.bind_in do sg_add_pin(ng, node, b.name, true)
		switch pd.kind {
		case .GRAPHICS:
			sg_add_pin(ng, node, "frame", false)
		case .COMPUTE:
			for b in info.bind_out do sg_add_pin(ng, node, b.name, false)
		case .PARAMS:
		}
		// Params -> pass, matching names (chain-fed inputs are linked from
		// the previous pass instead).
		for &pin in node.pins {
			if !pin.input do continue
			if chain_fed[fmt.tprintf("%s:%s", pd.key, pin.name)] do continue
			from := sg_id(ng, fmt.tprintf("pin:params:%s", pin.name))
			append(
				&ng.links,
				SgLink{id = sg_id(ng, fmt.tprintf("link:%d:%d", from, pin.id)), from = from, to = pin.id},
			)
		}
	}

	// Chain: pass[i-1]'s frame/output feeds pass[i]'s first texture input.
	for i := 1; i < len(passes); i += 1 {
		prev := sg_upsert_node(ng, passes[i - 1])
		cur := sg_upsert_node(ng, passes[i])
		prev_out := -1
		for &p in prev.pins {
			if !p.input {
				prev_out = p.id
				break
			}
		}
		cur_in := -1
		info := infos[passes[i].file]
		for b in info.bind_in {
			if b.kind != .TEXTURE do continue
			for &p in cur.pins {
				if p.input && p.name == b.name {
					cur_in = p.id
					break
				}
			}
			break
		}
		if prev_out >= 0 && cur_in >= 0 {
			append(
				&ng.links,
				SgLink {
					id   = sg_id(ng, fmt.tprintf("link:%d:%d", prev_out, cur_in)),
					from = prev_out,
					to   = cur_in,
				},
			)
		}
	}

	if ng.sync_frame == 1 {
		fmt.printfln("[node-graph] %s: %d nodes, %d links", ng.scene, len(ng.nodes), len(ng.links))
		for &n in ng.nodes {
			fmt.printfln("[node-graph]   %s (%s): %d pins", n.title, SG_KIND_TAGS[n.kind], len(n.pins))
		}
	}
}

// Self-test knob (--graph-test): creates one compute and one graphics pass
// on the starting scene at startup; the panel then shows a 5-node chain.
ing_selftest: bool

ing_init :: proc() -> ^NodeGraph {
	ng := new(NodeGraph)
	ng.handle = ine_create()
	ng.next_id = 1
	return ng
}

// Panel content; renders into the caller's window (the sidebar's GRAPH
// mode panel). The graph follows the active scene unit: switching scenes
// saves the outgoing graph.json and loads the incoming one.
ing_panel :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, scene_title: string) {
	if scene_title != ng.scene {
		sg_save(ng)
		sg_clear_graph(ng)
		ng.scene = strings.clone(scene_title)
		sg_load_layout(ng, scene_title)
	}
	sg_sync(ng, ed)
	if ng.sync_frame > 0 && ng.sync_frame % 600 == 2 do sg_save(ng)
	io := im.GetIO()

	im.TextDisabled("two fingers: pan · drag nodes to rearrange · the graph mirrors the scene's passes")

	ine_editor_begin(ng.handle)

	for &node in ng.nodes {
		if !node.placed {
			ine_set_node_grid_pos(ng.handle, c.int(node.id), node.pos.x, node.pos.y)
			node.placed = true
		}
		tc := SG_KIND_COLORS[node.kind]
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR, tc)
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR_HOVERED, tc)
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR_SELECTED, tc)
		ine_begin_node(ng.handle, c.int(node.id))
		ine_title_bar_begin(ng.handle)
		title := fmt.ctprintf("%s · %s", node.title, SG_KIND_TAGS[node.kind])
		im.TextUnformatted(title)
		ine_title_bar_end(ng.handle)
		// The title bar takes the node's width (not vice versa), so long
		// titles clip: reserve the title's width in the node body.
		im.Dummy({im.CalcTextSize(title).x, 1})
		shape := SG_KIND_PIN_SHAPES[node.kind]
		// Inputs first, then outputs: links flow left to right.
		for want_input in ([?]bool{true, false}) {
			for &pin in node.pins {
				if pin.input != want_input do continue
				pc: u32 = pin.input ? SG_PIN_IN_COLOR : SG_PIN_OUT_COLOR
				ine_push_color_style(ng.handle, INE_COL_PIN, pc)
				ine_push_color_style(ng.handle, INE_COL_PIN_HOVERED, pc)
				if pin.input {
					ine_input_attr_begin(ng.handle, c.int(pin.id), shape)
					im.TextUnformatted(strings_to_c(pin.name))
					ine_input_attr_end(ng.handle)
				} else {
					ine_output_attr_begin(ng.handle, c.int(pin.id), shape)
					im.TextUnformatted(strings_to_c(pin.name))
					ine_output_attr_end(ng.handle)
				}
				ine_pop_color_style(ng.handle)
				ine_pop_color_style(ng.handle)
			}
		}
		// "+" appends a pass to the chain (the popup below asks the kind).
		ine_static_attr_begin(ng.handle, c.int(sg_id(ng, fmt.tprintf("pin:%s:+", node.key))))
		if im.SmallButton("+") {
			ng.create_open = true
		}
		ine_static_attr_end(ng.handle)
		ine_end_node(ng.handle)
		ine_pop_color_style(ng.handle)
		ine_pop_color_style(ng.handle)
		ine_pop_color_style(ng.handle)
	}

	for l in ng.links {
		ine_link(ng.handle, c.int(l.id), c.int(l.from), c.int(l.to))
	}

	ine_minimap(ng.handle, 0.15, 1) // bottom right
	ine_editor_end(ng.handle)

	// Create-pass popup (opened by a node's "+"): the new file lands in the
	// scene's directory and appends to the chain on the next sync.
	if ng.create_open {
		im.OpenPopup("##node_create")
		ng.create_open = false
	}
	if im.BeginPopup("##node_create") {
		im.TextDisabled("create pass")
		if im.Selectable("graphics pass", false, {}) {
			sg_create_pass(ng, ed, .GRAPHICS)
		}
		if im.Selectable("compute pass", false, {}) {
			sg_create_pass(ng, ed, .COMPUTE)
		}
		im.EndPopup()
	}

	// Two-finger trackpad pan: wheel deltas shift the editor panning (the
	// sign follows the OS's natural-scrolling setting).
	if ine_is_editor_hovered(ng.handle) && (io.MouseWheel != 0 || io.MouseWheelH != 0) {
		px, py: f32
		ine_get_panning(ng.handle, &px, &py)
		ine_reset_panning(ng.handle, px - io.MouseWheelH * 60, py - io.MouseWheel * 60)
	}
}
