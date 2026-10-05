// Scene architecture graph, docked in the sidebar's GRAPH mode (F2 jumps
// to it). The graph reflects how the active scene unit is built, it is not
// a material editor: a params node per uniform block the app feeds, an
// image node (the app's textures + samplers) when any pass samples one, a
// 3d object node (the selected model's vertex stream, entering passes
// through the stage_in ModelVertex parameter) when any pass draws the
// model, one graphics node per vertex+fragment entry pair
// found in the scene's files, one compute node per compute entry, and a
// terminal "show 2d" node (the frame the viewport presents). Passes chain
// in declaration order: a graphics node's frame output feeds the next
// pass's first texture input (e.g. phong 3D → blur compute: params →
// graphics → compute). Links are derived from the source on a 120-frame
// rescan; they are not user-editable. The node layout persists in the
// scene's graph.json. All state lives here in Odin; the C++ side only
// renders.
//
// Pan with two fingers on the trackpad (wheel deltas adjust the editor
// panning); middle-drag also pans (imnodes built-in).
package main

import im "../vendor/odin-imgui"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

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
	ine_is_link_created :: proc(ed: rawptr, start_attr, end_attr: ^c.int) -> bool ---
	ine_is_link_destroyed :: proc(ed: rawptr, link_id: ^c.int) -> bool ---
	ine_push_attribute_flag :: proc(ed: rawptr, flag: c.int) ---
	ine_pop_attribute_flag :: proc(ed: rawptr) ---
	ine_set_node_grid_pos :: proc(ed: rawptr, id: c.int, x: f32, y: f32) ---
	ine_get_node_grid_pos :: proc(ed: rawptr, id: c.int, x: ^f32, y: ^f32) ---
	ine_get_panning :: proc(ed: rawptr, x: ^f32, y: ^f32) ---
	ine_reset_panning :: proc(ed: rawptr, x: f32, y: f32) ---
	ine_is_editor_hovered :: proc(ed: rawptr) -> bool ---
	ine_is_node_hovered :: proc(ed: rawptr, node_id: ^c.int) -> bool ---
	ine_push_color_style :: proc(ed: rawptr, col: c.int, color: u32) ---
	ine_pop_color_style :: proc(ed: rawptr) ---
	ine_screen_to_grid :: proc(ed: rawptr, sx, sy: f32, gx, gy: ^f32) ---
}

// ImNodesCol_ slots used below.
INE_COL_TITLE_BAR          :: 4
INE_COL_TITLE_BAR_HOVERED  :: 5
INE_COL_TITLE_BAR_SELECTED :: 6
INE_COL_PIN                :: 10
INE_COL_PIN_HOVERED        :: 11

// The node types. Pins distinguish them too: params = circle, graphics =
// triangle, compute = quad (all filled); show = circle outline,
// 3d object = triangle outline, image = quad outline. SHOW is the terminal
// "show 2d" node (the frame the viewport presents); OBJECT3D feeds the
// selected model's vertex stream (the stage_in ModelVertex parameter) to
// model passes; IMAGE feeds the app's textures (paper/skybox) and
// samplers.
SgPassKind :: enum { PARAMS, GRAPHICS, COMPUTE, SHOW, OBJECT3D, IMAGE }

SG_KIND_TAGS := [SgPassKind]string {
	.PARAMS   = "params",
	.GRAPHICS = "graphics",
	.COMPUTE  = "compute",
	.SHOW     = "output",
	.OBJECT3D = "mesh",
	.IMAGE    = "texture",
}

// Colors are ABGR-packed (a<<24|b<<16|g<<8|r) like col32() produces, written
// as constant expressions because global initializers can't call procs.
SG_KIND_COLORS := [SgPassKind]u32 {
	.PARAMS   = 0xFF << 24 | 0xC4 << 16 | 0x71 << 8 | 0x6C, // violet
	.GRAPHICS = 0xFF << 24 | 0x16 << 16 | 0x4B << 8 | 0xCB, // orange
	.COMPUTE  = 0xFF << 24 | 0xD2 << 16 | 0x8B << 8 | 0x26, // blue
	.SHOW     = 0xFF << 24 | 0x57 << 16 | 0xA8 << 8 | 0xE8, // safelight amber
	.OBJECT3D = 0xFF << 24 | 0x5C << 16 | 0xA0 << 8 | 0x58, // green
	.IMAGE    = 0xFF << 24 | 0xA5 << 16 | 0xA3 << 8 | 0x4F, // teal
}

// imnodes pin shapes: 0 = Circle, 1 = CircleFilled, 2 = Triangle,
// 3 = TriangleFilled, 4 = Quad, 5 = QuadFilled.
SG_KIND_PIN_SHAPES := [SgPassKind]c.int {
	.PARAMS   = 1,
	.GRAPHICS = 3,
	.COMPUTE  = 5,
	.SHOW     = 0,
	.OBJECT3D = 2,
	.IMAGE    = 4,
}

SG_PIN_IN_COLOR  :: 0xFF << 24 | 0xE0 << 16 | 0xE0 << 8 | 0xE0 // white
SG_PIN_OUT_COLOR :: 0xFF << 24 | 0x2E << 16 | 0xE2 << 8 | 0xA6 // green

// imnodes color slots for node body/outline (the title trio starts at 4).
INE_COL_NODE_BG        :: 0
INE_COL_NODE_BG_HOVER  :: 1
INE_COL_NODE_BG_SELECT :: 2
INE_COL_NODE_OUTLINE   :: 3
INE_COL_LINK           :: 7
INE_COL_LINK_HOVER     :: 8
INE_COL_LINK_SELECT    :: 9

// Body tint for a kind: the kind's hue darkened and fully OPAQUE, no
// canvas bleeding through nodes. `bright` scales the kind color.
sg_kind_body :: proc(kind: SgPassKind, bright: f32) -> u32 {
	c := SG_KIND_COLORS[kind]
	r := u32(f32(c & 0xFF) * bright)
	g := u32(f32(c >> 8 & 0xFF) * bright)
	b := u32(f32(c >> 16 & 0xFF) * bright)
	return 0xFF << 24 | b << 16 | g << 8 | r
}

// Type icon in the title bar: a 16px glyph drawn in the 20px slot at the
// title's left, in dark-on-color (like the traffic-light glyphs). Each
// kind gets a distinct mark so node types read by shape as well as color.
sg_draw_kind_icon :: proc(dl: ^im.DrawList, kind: SgPassKind, pos: im.Vec2, col: u32) {
	cx := pos.x + 10
	cy := pos.y + 8
	switch kind {
	case .PARAMS:
		// Sliders: three rails with knobs.
		knobs := [3]f32{-1.5, 2, -3}
		for k, i in knobs {
			y := cy - 4 + f32(i) * 4
			im.DrawList_AddLine(dl, {cx - 5, y}, {cx + 5, y}, col, 1.1)
			im.DrawList_AddCircleFilled(dl, {cx + k, y}, 1.6, col)
		}
	case .GRAPHICS:
		// Triangle.
		im.DrawList_AddTriangle(dl, {cx, cy - 5}, {cx - 5, cy + 4}, {cx + 5, cy + 4}, col, 1.2)
	case .COMPUTE:
		// 3x3 thread grid.
		for r in 0 ..< 3 {
			for c in 0 ..< 3 {
				x := cx - 5 + f32(c) * 5
				y := cy - 5 + f32(r) * 5
				im.DrawList_AddRectFilled(dl, {x, y}, {x + 3, y + 3}, col)
			}
		}
	case .SHOW:
		// Monitor: screen outline with a stand.
		im.DrawList_AddRect(dl, {cx - 5, cy - 5}, {cx + 5, cy + 2}, col, 1, 1.2)
		im.DrawList_AddLine(dl, {cx, cy + 2}, {cx, cy + 5}, col, 1.2)
	case .OBJECT3D:
		// Cube: back square offset from the front one, joined corners.
		im.DrawList_AddRect(dl, {cx - 5, cy - 1}, {cx + 1, cy + 5}, col, 0, 1.1)
		im.DrawList_AddRect(dl, {cx - 1, cy - 5}, {cx + 5, cy + 1}, col, 0, 1.1)
		im.DrawList_AddLine(dl, {cx - 5, cy - 1}, {cx - 1, cy - 5}, col, 1.1)
		im.DrawList_AddLine(dl, {cx + 1, cy + 5}, {cx + 5, cy + 1}, col, 1.1)
	case .IMAGE:
		// Picture: frame with a mountain and a sun dot.
		im.DrawList_AddRect(dl, {cx - 5, cy - 4}, {cx + 5, cy + 5}, col, 1, 1.1)
		im.DrawList_AddTriangleFilled(dl, {cx - 4, cy + 4}, {cx, cy - 1}, {cx + 4, cy + 4}, col)
		im.DrawList_AddCircleFilled(dl, {cx + 2.5, cy - 2}, 1, col)
	}
}

SgPin :: struct {
	id:    int,
	name:  string, // owned; identity (links, save keys)
	// Display text when set (params node shows "name (type)"); identity
	// stays `name`. Owned.
	label: string,
	input: bool,
	kind:  SgBindKind,
}

SgNode :: struct {
	id:     int,
	key:    string, // "params", "gfx:scenes/apple/apple", "comp:...:computeMain"; owned
	title:  string, // display name; owned
	kind:   SgPassKind,
	file:   string, // owning slang file ("" for params); owned
	pins:   [dynamic]SgPin,
	pos:    [2]f32, // spawn/layout-loaded position (initial placement)
	cur:    [2]f32, // last known grid position (barycenter ordering input)
	pref:   [2]f32, // layered position from sg_compute_layout (initial placement)
	// True when pos came from the cascade spawn (no saved layout, no
	// right-click point): sg_compute_layout replaces it with the layered
	// pref until the node is placed. User positions are never touched.
	auto_pos: bool,
	layer:  int, // depth: right of every node linking into it
	placed: bool,
	// Index in the scene's pass chain (-1: no preview): the node's preview
	// shows this pass's output texture (params/resource nodes stay -1;
	// "show" uses the final index, i.e. scene_tex).
	pass_idx: int,
}

// Wire flavor, set from the link's semantics at creation (sg_sync):
// decides the decoration style drawn over the imnodes base link: the
// frame chain flows, texture/mesh feeds are dashed, uniforms dotted.
SgLinkFlavor :: enum { FRAME, UNIFORM, TEXTURE, MESH }

SgLink :: struct {
	id, from, to: int,
	flavor:       SgLinkFlavor,
	col:          u32, // source node's kind color, for the wire decoration
	editable:      bool,
}

// A user-authored resource node (created via right-click): an image file
// feeding texture+sampler pins, or a model file feeding the ModelVertex
// stream. Persisted in graph.json (the "file" field), unlike the derived
// nodes which regenerate from source.
SgPendingLinkAction :: enum { NONE, CONNECT, DISCONNECT }

SgUserNode :: struct {
	path: string, // asset-relative ("assets/parchment.jpg"); owned
	kind: SgPassKind, // .IMAGE or .OBJECT3D
}

sg_user_key :: proc(kind: SgPassKind, path: string) -> string {
	prefix := kind == .OBJECT3D ? "uobj:" : "uimg:"
	return fmt.tprintf("%s%s", prefix, path)
}

// File name without directory or extension, for the node title.
sg_base_title :: proc(path: string) -> string {
	base := path
	if slash := strings.last_index(base, "/"); slash >= 0 do base = base[slash + 1:]
	if dot := strings.last_index(base, "."); dot > 0 do base = base[:dot]
	return base
}

// File name with extension ("parchment.jpg"), shown in the node body.
sg_file_name :: proc(path: string) -> string {
	if slash := strings.last_index(path, "/"); slash >= 0 do return path[slash + 1:]
	return path
}

// Small lightning bolt marking an app-injected pin, drawn centered
// INSIDE the pin socket's shape where a link would attach.
sg_draw_injected :: proc(dl: ^im.DrawList, cx, cy: f32) {
	col := im.GetColorU32Vec4({0.91, 0.66, 0.34, 1}) // safelight amber
	im.DrawList_AddLine(dl, {cx + 1.6, cy - 3}, {cx - 1.2, cy + 0.4}, col, 1.1)
	im.DrawList_AddLine(dl, {cx - 1.2, cy + 0.4}, {cx + 1.6, cy + 0.4}, col, 1.1)
	im.DrawList_AddLine(dl, {cx + 1.6, cy + 0.4}, {cx - 1.2, cy + 3.6}, col, 1.1)
}

// --- Wire decorations -------------------------------------------------------
// Styled wires drawn over imnodes' dimmed solid link (see the link loop in
// ing_panel). Every flavor draws on the same cubic bezier imnodes uses,
// sampled once per link per frame.

// [2]f32 -> im.Vec2 (the draw list takes Vec2; the wire math is arrays).
sg_v :: proc(p: [2]f32) -> im.Vec2 {
	return {p.x, p.y}
}

// Replace the alpha channel of an ABGR-packed color.
sg_alpha :: proc(col: u32, a: u32) -> u32 {
	return a << 24 | (col & 0x00FF_FFFF)
}

// Cubic bezier evaluation (matches the link curve imnodes draws).
sg_bezier_at :: proc(p0, p1, p2, p3: [2]f32, t: f32) -> [2]f32 {
	u := 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
}

// The control points imnodes uses for links: horizontal handles at a
// quarter of the endpoint distance, from output pin `a` to input pin `b`.
sg_link_bezier :: proc(a, b: [2]f32) -> (p0, p1, p2, p3: [2]f32) {
	d := b - a
	h := 0.25 * math.sqrt(d.x * d.x + d.y * d.y)
	off := [2]f32{h, 0}
	return a, a + off, b - off, b
}

// Point at arc length s along a sampled polyline.
sg_poly_at :: proc(pts: [][2]f32, s: f32) -> [2]f32 {
	rem := s
	for i in 1 ..< len(pts) {
		d := pts[i] - pts[i - 1]
		l := math.sqrt(d.x * d.x + d.y * d.y)
		if rem <= l {
			return l > 1e-4 ? pts[i - 1] + d * (rem / l) : pts[i - 1]
		}
		rem -= l
	}
	return pts[len(pts) - 1]
}

// Dashes along a sampled polyline; `offset` shifts the pattern along the
// wire (animate it for a marching-ant effect).
sg_draw_dashed :: proc(dl: ^im.DrawList, pts: [][2]f32, col: u32, thick, dash, gap, offset: f32) {
	total := f32(0)
	for i in 1 ..< len(pts) {
		d := pts[i] - pts[i - 1]
		total += math.sqrt(d.x * d.x + d.y * d.y)
	}
	period := dash + gap
	for s := -math.mod(offset, period); s < total; s += period {
		a := max(s, 0)
		b := min(s + dash, total)
		// Chord each dash in short steps so it follows the curve.
		for t0 := a; t0 < b; t0 += 4 {
			t1 := min(t0 + 4, b)
			im.DrawList_AddLine(dl, sg_v(sg_poly_at(pts, t0)), sg_v(sg_poly_at(pts, t1)), col, thick)
		}
	}
}

// One link's wire decoration, styled by flavor: the frame chain gets dots
// marching toward the consumer (the frame flowing through the passes),
// texture/mesh feeds get marching dashes, uniforms a static dotted line
// (constant for the frame: no flow). Colors come from the source node's
// kind. `a`/`b` are the screen-space socket centers.
sg_draw_link_wire :: proc(dl: ^im.DrawList, l: SgLink, a, b: [2]f32, now: f64) {
	SEG :: 32
	pts: [SEG + 1][2]f32
	p0, p1, p2, p3 := sg_link_bezier(a, b)
	for i in 0 ..= SEG {
		pts[i] = sg_bezier_at(p0, p1, p2, p3, f32(i) / SEG)
	}
	switch l.flavor {
	case .FRAME:
		// Faint solid underlay, then three dots flowing from the source
		// pass to the consumer, each with a soft glow.
		im.DrawList_AddPolyline(dl, (^im.Vec2)(&pts[0]), SEG + 1, sg_alpha(l.col, 0x30), 1.2)
		phase := f32(now * 0.45)
		for k in 0 ..< 3 {
			t := phase + f32(k) / 3
			t -= math.floor(t)
			p := sg_bezier_at(p0, p1, p2, p3, t)
			im.DrawList_AddCircleFilled(dl, sg_v(p), 4.5, sg_alpha(l.col, 0x30))
			im.DrawList_AddCircleFilled(dl, sg_v(p), 2.4, sg_alpha(l.col, 0xF0))
		}
	case .TEXTURE:
		sg_draw_dashed(dl, pts[:], sg_alpha(l.col, 0xC0), 1.4, 7, 5, f32(now * 24))
	case .MESH:
		sg_draw_dashed(dl, pts[:], sg_alpha(l.col, 0xC0), 1.6, 12, 7, f32(now * 16))
	case .UNIFORM:
		total := f32(0)
		for i in 1 ..= SEG {
			d := pts[i] - pts[i - 1]
			total += math.sqrt(d.x * d.x + d.y * d.y)
		}
		for s := f32(0); s <= total; s += 7 {
			im.DrawList_AddCircleFilled(dl, sg_v(sg_poly_at(pts[:], s)), 1.3, sg_alpha(l.col, 0xB0))
		}
	}
}

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
	// Node previews (the pass output thumbnail inside each pass node);
	// toggled in the GRAPH panel header.
	show_previews: bool,
	// Right-click creation: the new node spawns at the clicked grid point
	// (consumed by sg_upsert_node when the created pass's node appears).
	create_pos:     [2]f32,
	create_pos_set: bool,
	// User-authored resource nodes (image/3d object with a chosen file)
	// and the pending file-pick/create-delete state.
	user_nodes:   [dynamic]SgUserNode,
	file_pick:    SgPassKind, // kind being file-picked this popup
	delete_key:   string, // user node key pending delete via context menu (owned)
	save_pending: bool, // persist graph.json after the next sync
	saved_links: [dynamic]SgGraphLinkJson,
	graph_mtime: time.Time,
	graph_authoritative: bool,
	pipeline_error: string,
	pending_action: SgPendingLinkAction,
	pending_from, pending_to, pending_link_id: int,
	// Trackpad pan momentum: while the fingers scroll, deltas move the
	// panning 1:1 and the gesture velocity is sampled here; on release
	// the velocity glides on with exponential friction (the "ice").
	pan_vel: [2]f32,
	// Layered layout: node index pairs per link (rebuilt each sync by
	// sg_compute_layout for depth + barycenter ordering).
	link_pairs: [dynamic][2]int,
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

SgBindKind :: enum { CBUFFER, TEXTURE, SAMPLER, RWTEXTURE, BUFFER }

SgBinding :: struct {
	name: string,
	kind: SgBindKind,
	// CBUFFER only: the generic argument (`ConstantBuffer<HelloParams>`
	// -> "HelloParams"), for display. Slice into the file text.
	type_name: string,
}

SgEntryKind :: enum { COMPUTE, VERTEX, FRAGMENT }

SgEntry :: struct {
	kind: SgEntryKind,
	name: string,
	line: int,
}

SgFileInfo :: struct {
	text:       string, // owned by the sync pass
	bind_in:    [dynamic]SgBinding,
	bind_out:   [dynamic]SgBinding, // RWTexture outputs
	entries:    [dynamic]SgEntry,
	uses_model: bool, // a vertex entry takes the ModelVertex stage_in struct
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
				append(&info.bind_out, SgBinding{name, .RWTEXTURE, ""})
			}
		case strings.contains(rest, "ConstantBuffer<"):
			if name, ok := sg_binding_name(rest); ok {
				tname := ""
				if lt := strings.index(rest, "<"); lt >= 0 {
					if gt := strings.index(rest[lt + 1:], ">"); gt > 0 {
						tname = rest[lt + 1:][:gt]
					}
				}
				append(&info.bind_in, SgBinding{name, .CBUFFER, tname})
			}
		case strings.contains(rest, "Texture2D<"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .TEXTURE, ""})
			}
		case strings.has_prefix(rest, "SamplerState"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .SAMPLER, ""})
			}
		case strings.contains(rest, "(") && !strings.has_suffix(trimmed, ";"):
			// Top-level function definition: name is the word before '('. A
			// pending [shader("...")] attribute makes it an entry point.
			name := sg_last_word(rest[:strings.index(rest, "(")])
			if pending >= 0 && name != "" {
				// A vertex entry taking ModelVertex: the runtime feeds the
				// selected model's vertex stream (modelview-style).
				if SgEntryKind(pending) == .VERTEX && strings.contains(rest, "ModelVertex") {
					info.uses_model = true
				}
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

sg_node_pin :: proc(ng: ^NodeGraph, pin_id: int) -> (^SgNode, ^SgPin, bool) {
	for &node in ng.nodes {
		for &pin in node.pins {
			if pin.id == pin_id do return &node, &pin, true
		}
	}
	return nil, nil, false
}

sg_pin_endpoint :: proc(ng: ^NodeGraph, pin_id: int) -> string {
	node, pin, ok := sg_node_pin(ng, pin_id)
	if !ok do return "?"
	return pipeline_endpoint(node.key, pin.name)
}

sg_resolve_endpoint :: proc(ng: ^NodeGraph, endpoint: string) -> int {
	for &node in ng.nodes {
		for &pin in node.pins {
			if endpoint == pipeline_endpoint(node.key, pin.name) do return pin.id
		}
	}
	return -1
}

sg_is_pass_kind :: proc(kind: SgPassKind) -> bool {
	return kind == .GRAPHICS || kind == .COMPUTE
}

sg_node_id_for_pin :: proc(ng: ^NodeGraph, pin_id: int) -> int {
	for &node in ng.nodes {
		for pin in node.pins do if pin.id == pin_id do return node.id
	}
	return -1
}

sg_path_exists :: proc(ng: ^NodeGraph, from_node, to_node: int) -> bool {
	queue := make([dynamic]int, 0, len(ng.nodes), context.temp_allocator)
	seen := make(map[int]bool, len(ng.nodes), context.temp_allocator)
	append(&queue, from_node)
	seen[from_node] = true
	for cursor := 0; cursor < len(queue); cursor += 1 {
		current := queue[cursor]
		if current == to_node do return true
		for link in ng.links {
			if !link.editable do continue
			a := sg_node_id_for_pin(ng, link.from)
			b := sg_node_id_for_pin(ng, link.to)
			if a != current || b < 0 || seen[b] do continue
			seen[b] = true
			append(&queue, b)
		}
	}
	return false
}

sg_validate_connection :: proc(ng: ^NodeGraph, a, b: int) -> (from, to: int, error_message: string, ok: bool) {
	from_id, to_id := a, b
	an, ap, aok := sg_node_pin(ng, from_id)
	bn, bp, bok := sg_node_pin(ng, to_id)
	if !aok || !bok do return -1, -1, "unknown pin", false
	if ap.input == bp.input do return -1, -1, "connect one output to one input", false
	if ap.input {
		an, bn = bn, an
		ap, bp = bp, ap
		from_id, to_id = to_id, from_id
	}
	if !sg_is_pass_kind(an.kind) do return -1, -1, "pipeline edges must start at a pass output", false
	if !sg_is_pass_kind(bn.kind) && bn.kind != .SHOW do return -1, -1, "pipeline edges must end at a pass or viewport", false
	if bp.kind != .TEXTURE do return -1, -1, "pipeline edges require a texture input", false
	if ap.kind != .TEXTURE && ap.kind != .RWTEXTURE do return -1, -1, "pipeline edges require a texture output", false
	if an.id == bn.id do return -1, -1, "a pass cannot feed itself", false
	for link in ng.links {
		if link.from == from_id && link.to == to_id do return -1, -1, "link already exists", false
		if link.editable && link.to == to_id do return -1, -1, "input already has a producer", false
	}
	if bn.kind != .SHOW && sg_path_exists(ng, bn.id, an.id) {
		return -1, -1, "connection would create a cycle", false
	}
	return from_id, to_id, "", true
}

sg_append_pipeline_link :: proc(ng: ^NodeGraph, from, to: int) {
	node, _, ok := sg_node_pin(ng, from)
	if !ok do return
	append(
		&ng.links,
		SgLink {
			id = sg_id(ng, fmt.tprintf("link:%d:%d", from, to)),
			from = from,
			to = to,
			flavor = .FRAME,
			col = SG_KIND_COLORS[node.kind],
			editable = true,
		},
	)
}

sg_remove_pipeline_link :: proc(ng: ^NodeGraph, link_id: int) -> bool {
	for link, i in ng.links {
		if link.id != link_id || !link.editable do continue
		ordered_remove(&ng.links, i)
		return true
	}
	return false
}

// --- graph.json persistence ------------------------------------------------
// Nodes carry presentation/layout state; links are the authoritative runtime
// topology. Shader reflection still owns the available typed ports.

sg_graph_path :: proc(scene: string) -> string {
	return pipeline_graph_path(scene)
}

sg_clear_saved_links :: proc(ng: ^NodeGraph) {
	for &link in ng.saved_links {
		delete(link.from)
		delete(link.to)
	}
	clear(&ng.saved_links)
}

sg_load_layout :: proc(ng: ^NodeGraph, scene: string) -> bool {
	path := sg_graph_path(scene)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	doc: SgGraphJson
	if json.unmarshal(data, &doc, allocator = context.temp_allocator) != nil {
		delete(ng.pipeline_error)
		ng.pipeline_error = strings.clone("invalid graph.json")
		return false
	}
	if doc.version != 0 && doc.version != PIPELINE_SCHEMA_VERSION {
		delete(ng.pipeline_error)
		ng.pipeline_error = strings.clone(fmt.tprintf("unsupported graph schema version %d", doc.version))
		return false
	}
	ng.graph_authoritative = doc.version == PIPELINE_SCHEMA_VERSION

	for k, _ in ng.layout do delete(k)
	clear(&ng.layout)
	for un in ng.user_nodes do delete(un.path)
	clear(&ng.user_nodes)
	sg_clear_saved_links(ng)
	for n in doc.nodes {
		ng.layout[strings.clone(n.key)] = {n.x, n.y}
		if n.file != "" {
			kind := SgPassKind.IMAGE
			if strings.has_prefix(n.key, "uobj:") do kind = .OBJECT3D
			append(&ng.user_nodes, SgUserNode{path = strings.clone(n.file), kind = kind})
		}
	}
	for link in doc.links {
		append(
			&ng.saved_links,
			SgGraphLinkJson{from = strings.clone(link.from), to = strings.clone(link.to)},
		)
	}
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
		ng.graph_mtime = info.modification_time
	}
	delete(ng.pipeline_error)
	ng.pipeline_error = ""
	return true
}

sg_reload_if_changed :: proc(ng: ^NodeGraph) {
	if ng.scene == "" do return
	info, err := os.stat(sg_graph_path(ng.scene), context.temp_allocator)
	if err != nil || time.diff(info.modification_time, ng.graph_mtime) == 0 do return
	if !sg_load_layout(ng, ng.scene) do return
	for &node in ng.nodes {
		if pos, ok := ng.layout[node.key]; ok {
			node.pos = pos
			node.cur = pos
			node.placed = false
			node.auto_pos = false
		}
	}
	ng.sync_frame = 0
}

sg_save :: proc(ng: ^NodeGraph) {
	if ng.scene == "" || len(ng.nodes) == 0 do return
	pin_names := make(map[int]string, 64, context.temp_allocator)
	for &n in ng.nodes {
		for &p in n.pins do pin_names[p.id] = fmt.tprintf("%s:%s", n.key, p.name)
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"version":`)
	fmt.sbprintf(&sb, "%d", PIPELINE_SCHEMA_VERSION)
	strings.write_string(&sb, `,"scene":"`)
	strings.write_string(&sb, ng.scene)
	strings.write_string(&sb, `","nodes":[`)
	for &n, i in ng.nodes {
		if i > 0 do strings.write_byte(&sb, ',')
		x, y: f32
		ine_get_node_grid_pos(ng.handle, c.int(n.id), &x, &y)
		strings.write_string(&sb, `{"key":"`)
		strings.write_string(&sb, n.key)
		strings.write_string(&sb, `","kind":"`)
		strings.write_string(&sb, SG_KIND_TAGS[n.kind])
		fmt.sbprintf(&sb, `","x":%.1f,"y":%.1f`, x, y)
		if strings.has_prefix(n.key, "uimg:") || strings.has_prefix(n.key, "uobj:") {
			strings.write_string(&sb, `,"file":"`)
			strings.write_string(&sb, n.key[5:])
			strings.write_byte(&sb, '"')
		}
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, `],"links":[`)
	for link, i in ng.links {
		from, from_ok := pin_names[link.from]
		to, to_ok := pin_names[link.to]
		if !from_ok || !to_ok do continue
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, `{"from":"`)
		strings.write_string(&sb, from)
		strings.write_string(&sb, `","to":"`)
		strings.write_string(&sb, to)
		strings.write_string(&sb, `"}`)
	}
	strings.write_string(&sb, `]}`)
	path := sg_graph_path(ng.scene)
	if os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) != nil {
		log.errorf("[node-graph] failed to write %s", path)
		return
	}
	ng.graph_authoritative = true
	sg_clear_saved_links(ng)
	for link in ng.links {
		from, from_ok := pin_names[link.from]
		to, to_ok := pin_names[link.to]
		if !from_ok || !to_ok do continue
		append(&ng.saved_links, SgGraphLinkJson{from = strings.clone(from), to = strings.clone(to)})
	}
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
		ng.graph_mtime = info.modification_time
	}
}

sg_clear_graph :: proc(ng: ^NodeGraph) {
	for &n in ng.nodes {
		for &p in n.pins { delete(p.name); delete(p.label) }
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
	for un in ng.user_nodes do delete(un.path)
	clear(&ng.user_nodes)
	sg_clear_saved_links(ng)
	delete(ng.pipeline_error)
	ng.pipeline_error = ""
	ng.graph_mtime = {}
	ng.graph_authoritative = false
	ng.pending_action = .NONE
	if ng.delete_key != "" {
		delete(ng.delete_key)
		ng.delete_key = ""
	}
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
			log.errorf("[node-graph] failed to write %s", path)
			return ""
		}
		log.infof("[node-graph] created %s", path)
		ied_rescan(ed)
		ng.sync_frame = 0 // force resync on the next panel frame
		return fmt.tprintf("scenes/%s/%s", ng.scene, name)
	}
	return ""
}

sg_add_pin :: proc(ng: ^NodeGraph, node: ^SgNode, name: string, kind: SgBindKind, input: bool) {
	key := fmt.tprintf("pin:%s:%s", node.key, name)
	append(&node.pins, SgPin{id = sg_id(ng, key), name = strings.clone(name), input = input, kind = kind})
}

// Files with the given extension inside a directory, as asset-relative
// paths ("<dir>/<file>"), sorted. Temp-allocated (rebuilt per frame the
// picker is open).
sg_asset_files :: proc(dir, ext: string) -> [dynamic]string {
	files := make([dynamic]string, 0, 8, context.temp_allocator)
	entries, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil do return files
	for entry in entries {
		if entry.type != .Regular do continue
		if !strings.has_suffix(entry.name, ext) do continue
		append(&files, fmt.tprintf("%s/%s", dir, entry.name))
	}
	slice.sort(files[:])
	return files
}

// Every pickable image: assets root plus the skybox directory.
sg_image_files :: proc() -> [dynamic]string {
	files := make([dynamic]string, 0, 8, context.temp_allocator)
	for dir in ([?]string{"assets", "assets/skybox"}) {
		entries, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
		if err != nil do continue
		for entry in entries {
			if entry.type != .Regular do continue
			lower := strings.to_lower(entry.name, context.temp_allocator)
			is_image :=
				strings.has_suffix(lower, ".jpg") ||
				strings.has_suffix(lower, ".jpeg") ||
				strings.has_suffix(lower, ".png")
			if !is_image do continue
			append(&files, fmt.tprintf("%s/%s", dir, entry.name))
		}
	}
	slice.sort(files[:])
	return files
}

// Registers a user-authored resource node for an asset; the next sync
// upserts it (at the right-clicked grid point) and graph.json persists it.
sg_create_user_node :: proc(ng: ^NodeGraph, kind: SgPassKind, path: string) {
	key := sg_user_key(kind, path)
	for un in ng.user_nodes {
		if sg_user_key(un.kind, un.path) == key do return // already on the canvas
	}
	append(&ng.user_nodes, SgUserNode{path = strings.clone(path), kind = kind})
	log.infof("[node-graph] created %s node for %s", SG_KIND_TAGS[kind], path)
	ng.sync_frame = 0 // force resync on the next panel frame
	ng.save_pending = true
}

// Removes the user node pending deletion (delete_key), by key.
sg_delete_user_node :: proc(ng: ^NodeGraph) {
	if ng.delete_key == "" do return
	for un, i in ng.user_nodes {
		if sg_user_key(un.kind, un.path) == ng.delete_key {
			delete(un.path)
			ordered_remove(&ng.user_nodes, i)
			break
		}
	}
	delete(ng.delete_key)
	ng.delete_key = ""
	ng.sync_frame = 0 // the sweep drops the node
	ng.save_pending = true
}

sg_upsert_node :: proc(ng: ^NodeGraph, d: SgPassDesc) -> ^SgNode {
	for &n in ng.nodes {
		if n.key == d.key do return &n
	}
	pos, has_layout := ng.layout[d.key]
	auto_pos := false
	if !has_layout {
		if ng.create_pos_set {
			// Right-click creation: spawn at the clicked grid point.
			pos = ng.create_pos
			ng.create_pos_set = false
		} else {
			// Cascade placeholder; sg_compute_layout replaces it with
			// the layered position before the node is first placed.
			col := ng.spawn_count % 3
			row := ng.spawn_count / 3
			pos = {40 + f32(col) * 240, 40 + f32(row) * 220}
			ng.spawn_count += 1
			auto_pos = true
		}
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
			cur   = pos,
			auto_pos = auto_pos,
			// Only pass nodes get a preview (the pass loop assigns pi);
			// params/resource nodes keep the no-preview sentinel.
			pass_idx = -1,
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

	// Inputs fed by saved pass edges must not receive the default image.
	chain_fed := make(map[string]bool, 8, context.temp_allocator)
	has_saved_pipeline := false
	for link in ng.saved_links {
		source_is_pass := false
		for pass in passes {
			if strings.has_prefix(link.from, fmt.tprintf("%s:", pass.key)) {
				source_is_pass = true
				break
			}
		}
		if !source_is_pass do continue
		if link.to == "show2d:frame" {
			has_saved_pipeline = true
			continue
		}
		for pass in passes {
			prefix := fmt.tprintf("%s:", pass.key)
			if !strings.has_prefix(link.to, prefix) do continue
			input_name := link.to[len(prefix):]
			for binding in infos[pass.file].bind_in {
				if binding.kind == .TEXTURE && binding.name == input_name {
					chain_fed[link.to] = true
					has_saved_pipeline = true
				}
			}
		}
	}
	if !has_saved_pipeline {
		for i := 1; i < len(passes); i += 1 {
			for binding in infos[passes[i].file].bind_in {
				if binding.kind != .TEXTURE do continue
				chain_fed[pipeline_endpoint(passes[i].key, binding.name)] = true
				break
			}
		}
	}

	// User-authored resource nodes (created via right-click, persisted in
	// graph.json): rebuilt like the structural nodes so their pins exist
	// for linking.
	for un in ng.user_nodes {
		key := sg_user_key(un.kind, un.path)
		node := sg_upsert_node(ng, SgPassDesc{key = key, title = sg_base_title(un.path), kind = un.kind})
		for &p in node.pins { delete(p.name); delete(p.label) }
		clear(&node.pins)
		#partial switch un.kind {
		case .IMAGE:
			sg_add_pin(ng, node, "texture", .TEXTURE, false)
			sg_add_pin(ng, node, "sampler", .SAMPLER, false)
		case .OBJECT3D:
			sg_add_pin(ng, node, "ModelVertex", .BUFFER, false)
		}
	}
	sg_user_alive :: proc(ng: ^NodeGraph, key: string) -> bool {
		for un in ng.user_nodes {
			if sg_user_key(un.kind, un.path) == key do return true
		}
		return false
	}

	// Which resource nodes this scene needs: the 3d object node when any
	// pass draws the model, the image node when any pass samples an
	// app-fed texture or sampler.
	need_object3d := false
	need_image := false
	for pd in passes {
		info := infos[pd.file]
		if info.uses_model do need_object3d = true
		for b in info.bind_in {
			if b.kind != .TEXTURE && b.kind != .SAMPLER do continue
			if chain_fed[fmt.tprintf("%s:%s", pd.key, b.name)] do continue
			need_image = true
		}
	}

	// Drop nodes for passes that vanished (file edited, import removed),
	// and resource nodes the scene no longer needs. Params and the show
	// node are structural: they outlive pass edits.
	for i := len(ng.nodes) - 1; i >= 0; i -= 1 {
		node := &ng.nodes[i]
		alive := false
		switch node.kind {
		case .PARAMS, .SHOW:
			alive = true
		case .OBJECT3D:
			alive = strings.has_prefix(node.key, "uobj:") ? sg_user_alive(ng, node.key) : need_object3d
		case .IMAGE:
			alive = strings.has_prefix(node.key, "uimg:") ? sg_user_alive(ng, node.key) : need_image
		case .GRAPHICS, .COMPUTE:
			for p in passes {
				if p.key == node.key {
					alive = true
					break
				}
			}
		}
		if !alive {
			for &p in node.pins { delete(p.name); delete(p.label) }
			delete(node.pins)
			delete(node.key)
			delete(node.title)
			delete(node.file)
			ordered_remove(&ng.nodes, i)
		}
	}
	clear(&ng.links)

	// Uniforms node: SceneUniforms ("Uniforms") plus one output per
	// uniform block the passes consume from the app, labeled with the
	// block's struct type ("Uniforms (SceneUniforms)"). SceneUniforms is
	// app-injected into every pass: it carries the injected mark (and no
	// link) on both ends.
	params := sg_upsert_node(ng, SgPassDesc{key = "params", title = "Uniforms", kind = .PARAMS})
	for &p in params.pins { delete(p.name); delete(p.label) }
	clear(&params.pins)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for pd in passes {
		info := infos[pd.file]
		for b in info.bind_in {
			if b.kind != .CBUFFER do continue
			if seen[b.name] do continue
			seen[b.name] = true
			sg_add_pin(ng, params, b.name, b.kind, false)
			if b.type_name != "" {
				pin := &params.pins[len(params.pins) - 1]
				pin.label = strings.clone(fmt.tprintf("%s (%s)", b.name, b.type_name))
			}
		}
	}

	// Resource nodes: the selected model's geometry and the app's
	// textures/samplers. Pins are fixed; links fan out by kind below.
	object3d: ^SgNode
	if need_object3d {
		object3d = sg_upsert_node(ng, SgPassDesc{key = "object3d", title = "3d object", kind = .OBJECT3D})
		for &p in object3d.pins do delete(p.name)
		clear(&object3d.pins)
		// The mesh leaves as the vertex stream the pass's stage_in
		// parameter consumes (ModelVertex).
		sg_add_pin(ng, object3d, "ModelVertex", .BUFFER, false)
	}
	image: ^SgNode
	if need_image {
		image = sg_upsert_node(ng, SgPassDesc{key = "image", title = "image", kind = .IMAGE})
		for &p in image.pins { delete(p.name); delete(p.label) }
		clear(&image.pins)
		sg_add_pin(ng, image, "texture", .TEXTURE, false)
		sg_add_pin(ng, image, "sampler", .SAMPLER, false)
	}

	// Pass nodes: inputs are their bindings (plus vertex/index buffer for
	// model passes), output is the frame they produce (graphics) or their
	// RWTexture(s) (compute).
	for pd, pi in passes {
		node := sg_upsert_node(ng, pd)
		node.pass_idx = pi
		for &p in node.pins { delete(p.name); delete(p.label) }
		clear(&node.pins)
		info := infos[pd.file]
		for b in info.bind_in do sg_add_pin(ng, node, b.name, b.kind, true)
		if info.uses_model {
			// The mesh input is not a vk::binding: it enters the vertex
			// entry through the stage_in ModelVertex parameter, so it is
			// a pin of the node like the bindings are.
			sg_add_pin(ng, node, "ModelVertex", .BUFFER, true)
		}
		switch pd.kind {
		case .GRAPHICS:
			sg_add_pin(ng, node, "frame", .TEXTURE, false)
		case .COMPUTE:
			for b in info.bind_out do sg_add_pin(ng, node, b.name, b.kind, false)
		case .PARAMS, .SHOW, .OBJECT3D, .IMAGE:
			// Pins are assigned outside this loop.
		}
		// Resource nodes -> pass: uniforms from params, textures/samplers
		// from image, geometry from 3d object (chain-fed texture inputs
		// are linked from the previous pass instead).
		for &pin in node.pins {
			if !pin.input do continue
			if chain_fed[fmt.tprintf("%s:%s", pd.key, pin.name)] do continue
			// SceneUniforms is app-injected: marked on the pin, no link.
			if pin.kind == .CBUFFER && pin.name == "Uniforms" do continue
			from := -1
			flavor := SgLinkFlavor.UNIFORM
			src_kind := SgPassKind.PARAMS
			switch pin.kind {
			case .CBUFFER:
				from = sg_id(ng, fmt.tprintf("pin:params:%s", pin.name))
			case .TEXTURE:
				from = sg_id(ng, "pin:image:texture")
				flavor = .TEXTURE
				src_kind = .IMAGE
			case .SAMPLER:
				from = sg_id(ng, "pin:image:sampler")
				flavor = .TEXTURE
				src_kind = .IMAGE
			case .BUFFER:
				from = sg_id(ng, fmt.tprintf("pin:object3d:%s", pin.name))
				flavor = .MESH
				src_kind = .OBJECT3D
			case .RWTEXTURE:
			}
			if from < 0 do continue
			append(
				&ng.links,
				SgLink {
					id     = sg_id(ng, fmt.tprintf("link:%d:%d", from, pin.id)),
					from   = from,
					to     = pin.id,
					flavor = flavor,
					col    = SG_KIND_COLORS[src_kind],
				},
			)
		}
	}

	// The viewport is a real pipeline sink. Its incoming edge and all
	// pass-to-pass texture edges come from graph.json when present.
	show := sg_upsert_node(ng, SgPassDesc{key = "show2d", title = "show 2d", kind = .SHOW})
	show.pass_idx = len(passes) - 1
	for &pin in show.pins { delete(pin.name); delete(pin.label) }
	clear(&show.pins)
	sg_add_pin(ng, show, "frame", .TEXTURE, true)

	if has_saved_pipeline {
		for saved in ng.saved_links {
			from := sg_resolve_endpoint(ng, saved.from)
			to := sg_resolve_endpoint(ng, saved.to)
			if from < 0 || to < 0 do continue
			source_node, _, source_ok := sg_node_pin(ng, from)
			target_node, _, target_ok := sg_node_pin(ng, to)
			if !source_ok || !target_ok || !sg_is_pass_kind(source_node.kind) ||
			   (!sg_is_pass_kind(target_node.kind) && target_node.kind != .SHOW) {
				continue
			}
			normalized_from, normalized_to, error_message, ok := sg_validate_connection(ng, from, to)
			if !ok {
				delete(ng.pipeline_error)
				ng.pipeline_error = strings.clone(error_message)
				continue
			}
			sg_append_pipeline_link(ng, normalized_from, normalized_to)
			if target_node, _, target_ok := sg_node_pin(ng, normalized_to); target_ok && target_node.kind == .SHOW {
				if source_node, _, source_ok := sg_node_pin(ng, normalized_from); source_ok {
					show.pass_idx = source_node.pass_idx
				}
			}
		}
	} else if !ng.graph_authoritative {
		// Migration/default: the previous declaration-order chain.
		for i := 1; i < len(passes); i += 1 {
			previous := sg_upsert_node(ng, passes[i - 1])
			current := sg_upsert_node(ng, passes[i])
			previous_output := -1
			for pin in previous.pins do if !pin.input { previous_output = pin.id; break }
			current_input := -1
			for pin in current.pins {
				if pin.input && pin.kind == .TEXTURE { current_input = pin.id; break }
			}
			if previous_output >= 0 && current_input >= 0 do sg_append_pipeline_link(ng, previous_output, current_input)
		}
		if len(passes) > 0 {
			last := sg_upsert_node(ng, passes[len(passes) - 1])
			for pin in last.pins {
				if !pin.input { sg_append_pipeline_link(ng, pin.id, show.pins[0].id); break }
			}
		}
		ng.save_pending = true
	}

	sg_compute_layout(ng)

	if ng.sync_frame == 1 {
		log.infof("[node-graph] %s: %d nodes, %d links", ng.scene, len(ng.nodes), len(ng.links))
		for &n in ng.nodes {
			log.infof("[node-graph]   %s (%s): %d pins", n.title, SG_KIND_TAGS[n.kind], len(n.pins))
		}
	}
}

// --- Layered layout --------------------------------------------------------
// Nodes hold a preferred position: sources on the left, every node to the
// right of the nodes linking into it (topological depth), and within a
// depth layer ordered top-to-bottom by the barycenter of its inputs.
// There is NO simulation: pref only seeds the initial placement of nodes
// that have no user-chosen position; after that imnodes owns positions
// and sg_save persists them.

SG_LAYOUT_X0    :: 40.0
SG_LAYOUT_Y0    :: 40.0
SG_LAYOUT_X_GAP :: 300.0
SG_LAYOUT_Y_GAP :: 260.0 // fits nodes with previews (~220px tall)

// Rebuilds link endpoint pairs and the preferred positions from the
// current graph. Runs at the end of every sync. Positions are owned by
// the user: pref only seeds nodes that have no saved/right-click
// position yet (auto_pos) and have never been placed.
sg_compute_layout :: proc(ng: ^NodeGraph) {
	// Refresh the cached positions of placed nodes so the barycenter
	// ordering below sees where the user actually left things.
	for &node in ng.nodes {
		if node.placed {
			ine_get_node_grid_pos(ng.handle, c.int(node.id), &node.cur.x, &node.cur.y)
		}
	}

	clear(&ng.link_pairs)
	for l in ng.links {
		ai, bi := -1, -1
		for &node, i in ng.nodes {
			for &p in node.pins {
				if p.id == l.from do ai = i
				if p.id == l.to do bi = i
			}
		}
		if ai >= 0 && bi >= 0 do append(&ng.link_pairs, [2]int{ai, bi})
	}

	// Depth: 0 for sources, 1 + max(source depths) otherwise. The links
	// form a DAG, so relaxation converges.
	for &n in ng.nodes do n.layer = 0
	for _ in 0 ..< len(ng.nodes) {
		changed := false
		for pair in ng.link_pairs {
			target := &ng.nodes[pair[1]]
			if target.layer < ng.nodes[pair[0]].layer + 1 {
				target.layer = ng.nodes[pair[0]].layer + 1
				changed = true
			}
		}
		if !changed do break
	}

	// Within each layer: order by the barycenter of the inputs' current
	// y (fewer crossings), then slot top-to-bottom.
	max_layer := 0
	for &n in ng.nodes do max_layer = max(max_layer, n.layer)
	for layer in 0 ..= max_layer {
		Entry :: struct {
			i: int,
			b: f32,
		}
		entries := make([dynamic]Entry, 0, 8, context.temp_allocator)
		for &n, i in ng.nodes {
			if n.layer != layer do continue
			sum := 0.0
			cnt := 0
			for pair in ng.link_pairs {
				if pair[1] != i do continue
				sum += f64(ng.nodes[pair[0]].cur.y)
				cnt += 1
			}
			append(&entries, Entry{i = i, b = cnt > 0 ? f32(sum / f64(cnt)) : 0})
		}
		slice.sort_by(entries[:], proc(a, b: Entry) -> bool { return a.b < b.b })
		for e, slot in entries {
			ng.nodes[e.i].pref = {
				SG_LAYOUT_X0 + f32(layer) * SG_LAYOUT_X_GAP,
				SG_LAYOUT_Y0 + f32(slot) * SG_LAYOUT_Y_GAP,
			}
		}
	}

	// Nodes without a user-chosen position adopt the layered layout:
	// once, before their first placement. After that the position belongs
	// to the user (imnodes owns it; sg_save persists it).
	for &node in ng.nodes {
		if node.auto_pos && !node.placed {
			node.pos = node.pref
			node.cur = node.pref
		}
	}
}

// Self-test knob (--graph-test): creates one compute and one graphics pass
// on the starting scene at startup; the panel then shows a 5-node chain.
ing_selftest: bool

// Node previews: one stable texture per reflected pass plus the selected
// viewport output. Set from main before the graph panel renders.
ing_pass_tex:   []^sdl.GPUTexture
ing_scene_tex:  ^sdl.GPUTexture
ing_output_pass: int
ing_n_passes:   int
ing_provenance_valid: [DEBUG_WATCH_MAX_PASSES]bool
ing_provenance_path: [DEBUG_WATCH_MAX_PASSES]bool
ing_provenance_rgba: [DEBUG_WATCH_MAX_PASSES][4]f32

sg_preview_tex :: proc(i: int) -> ^sdl.GPUTexture {
	if i < 0 || ing_scene_tex == nil do return nil
	if i == ing_output_pass do return ing_scene_tex
	if i < len(ing_pass_tex) do return ing_pass_tex[i]
	return nil
}

ing_runtime_pipeline_error: string

ing_init :: proc() -> ^NodeGraph {
	ng := new(NodeGraph)
	ng.handle = ine_create()
	ng.next_id = 1
	ng.show_previews = true
	return ng
}

// Panel content; renders into the caller's window (the sidebar's GRAPH
// mode panel). The graph follows the active scene unit: switching scenes
// saves the outgoing graph.json and loads the incoming one. `maximized`
// toggles the maximized panel width (the overlay button, top-right).
ing_panel :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, scene_title: string, maximized: ^bool) {
	if scene_title != ng.scene {
		sg_save(ng)
		sg_clear_graph(ng)
		ng.scene = strings.clone(scene_title)
		sg_load_layout(ng, scene_title)
	} else {
		sg_reload_if_changed(ng)
	}
	sg_sync(ng, ed)
	if ng.sync_frame > 0 && ng.sync_frame % 600 == 2 do sg_save(ng)
	if ng.save_pending {
		sg_save(ng)
		ng.save_pending = false
	}
	io := im.GetIO()
	im.Checkbox(trc("previews"), &ng.show_previews)
	if ng.pipeline_error != "" || ing_runtime_pipeline_error != "" {
		message := ng.pipeline_error if ng.pipeline_error != "" else ing_runtime_pipeline_error
		im.TextColored({0.95, 0.42, 0.36, 1}, "pipeline: %s", strings_to_c(message))
		im.TextDisabled(trc("last valid pipeline remains active"))
	}
	ine_editor_begin(ng.handle)
	// Injected-pin bolt positions, collected while rendering the nodes and
	// drawn after ine_editor_end: imnodes paints pin shapes at EndNodeEditor.
	inject_marks := make([dynamic][2]f32, 0, 16, context.temp_allocator)
	// Pin id -> screen-space socket center for wire decorations.
	pin_pos := make(map[int][2]f32, 64, context.temp_allocator)

	for &node in ng.nodes {
		if !node.placed {
			ine_set_node_grid_pos(ng.handle, c.int(node.id), node.pos.x, node.pos.y)
			node.placed = true
		}
		tc := SG_KIND_COLORS[node.kind]
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR, tc)
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR_HOVERED, tc)
		ine_push_color_style(ng.handle, INE_COL_TITLE_BAR_SELECTED, tc)
		// Body tinted with the kind's color at low alpha; the output node
		// also gets the bright safelight outline so it reads as the sink.
		ine_push_color_style(ng.handle, INE_COL_NODE_BG, sg_kind_body(node.kind, 0.30))
		ine_push_color_style(ng.handle, INE_COL_NODE_BG_HOVER, sg_kind_body(node.kind, 0.40))
		ine_push_color_style(ng.handle, INE_COL_NODE_BG_SELECT, sg_kind_body(node.kind, 0.50))
		if node.kind == .SHOW {
			ine_push_color_style(ng.handle, INE_COL_NODE_OUTLINE, tc)
		}
		ine_begin_node(ng.handle, c.int(node.id))
		ine_title_bar_begin(ng.handle)
		icon_col := im.GetColorU32Vec4({0, 0, 0, 0.55})
		icon_pos := im.GetCursorScreenPos()
		sg_draw_kind_icon(im.GetWindowDrawList(), node.kind, icon_pos, icon_col)
		im.SetCursorPosX(icon_pos.x + 20)
		// tr() falls back to the key, so user-file titles pass through
		// unchanged; only the fixed node names translate. The raw tag
		// (untranslated) is what graph.json persists.
		title := fmt.ctprintf("%s · %s", tr(node.title), tr(SG_KIND_TAGS[node.kind]))
		im.TextUnformatted(title)
		ine_title_bar_end(ng.handle)
		// The title bar takes the node's width (not vice versa), so long
		// titles clip: reserve the widest text in the node body: title
		// (plus its icon) OR longest pin name, since pins longer than the
		// title clip too (inputs on the right edge, outputs on the left).
		node_w := im.CalcTextSize(title).x + 20
		for &pin in node.pins {
			text := pin.label if pin.label != "" else pin.name
			pin_w := im.CalcTextSize(strings_to_c(text)).x
			if pin_w > node_w do node_w = pin_w
		}
		im.Dummy({node_w, 1})
		// User-authored resource nodes show the asset they feed.
		if strings.has_prefix(node.key, "uimg:") || strings.has_prefix(node.key, "uobj:") {
			im.TextDisabled(strings_to_c(sg_file_name(node.key[5:])))
		}
		shape := SG_KIND_PIN_SHAPES[node.kind]
		// Inputs first, then outputs: links flow left to right.
		for want_input in ([?]bool{true, false}) {
			for &pin in node.pins {
				if pin.input != want_input do continue
				pc: u32 = pin.input ? SG_PIN_IN_COLOR : SG_PIN_OUT_COLOR
				ine_push_color_style(ng.handle, INE_COL_PIN, pc)
				ine_push_color_style(ng.handle, INE_COL_PIN_HOVERED, pc)
				injected := pin.kind == .CBUFFER && pin.name == "Uniforms"
				text := pin.label if pin.label != "" else pin.name
				if pin.input {
					ine_input_attr_begin(ng.handle, c.int(pin.id), shape)
					ine_push_attribute_flag(ng.handle, 1)
					im.TextUnformatted(strings_to_c(text))
					ine_pop_attribute_flag(ng.handle)
					ine_input_attr_end(ng.handle)
					rmin := im.GetItemRectMin()
					rmax := im.GetItemRectMax()
					pin_pos[pin.id] = {rmin.x - 8, (rmin.y + rmax.y) / 2}
					if injected do append(&inject_marks, pin_pos[pin.id])
				} else {
					ine_output_attr_begin(ng.handle, c.int(pin.id), shape)
					im.TextUnformatted(strings_to_c(text))
					ine_output_attr_end(ng.handle)
					rmin := im.GetItemRectMin()
					rmax := im.GetItemRectMax()
					pin_pos[pin.id] = {rmax.x + 8, (rmin.y + rmax.y) / 2}
					if injected do append(&inject_marks, pin_pos[pin.id])
				}
				ine_pop_color_style(ng.handle)
				ine_pop_color_style(ng.handle)
			}
		}
		// Pass preview: the frame this pass produced (previous frame's
		// content: the graph renders before this frame's submit).
		if ng.show_previews && node.pass_idx >= 0 {
			if tex := sg_preview_tex(node.pass_idx); tex != nil {
				ine_static_attr_begin(
					ng.handle,
					c.int(sg_id(ng, fmt.tprintf("pin:%s:prev", node.key))),
				)
				w := f32(128)
				h := w * io.DisplaySize.y / io.DisplaySize.x
				im.Image(im.TextureRef{_TexID = u64(uintptr(tex))}, {w, h})
				ine_static_attr_end(ng.handle)
			}
		}
		if node.pass_idx >= 0 && node.pass_idx < DEBUG_WATCH_MAX_PASSES &&
		   ing_provenance_valid[node.pass_idx] && ing_provenance_path[node.pass_idx] {
			ine_static_attr_begin(ng.handle, c.int(sg_id(ng, fmt.tprintf("pin:%s:provenance", node.key))))
			value := ing_provenance_rgba[node.pass_idx]
			im.TextColored(
				{value[0], value[1], value[2], 1},
				"pixel  %.3f  %.3f  %.3f  %.3f",
				value[0], value[1], value[2], value[3],
			)
			ine_static_attr_end(ng.handle)
		}
		// "+" appends a pass to the chain (the popup below asks the kind).
		ine_static_attr_begin(ng.handle, c.int(sg_id(ng, fmt.tprintf("pin:%s:+", node.key))))
		if im.SmallButton("+") {
			ng.create_open = true
		}
		ine_static_attr_end(ng.handle)
		ine_end_node(ng.handle)
		// Pop title trio + body trio (+ the SHOW outline when pushed).
		for _ in 0 ..< (node.kind == .SHOW ? 7 : 6) {
			ine_pop_color_style(ng.handle)
		}
	}

	// The native solid link drops to a faint base; the flavored wire
	// decorations drawn after ine_editor_end carry the visual weight.
	ine_push_color_style(ng.handle, INE_COL_LINK, 0x40 << 24 | 0x66 << 16 | 0x66 << 8 | 0x66)
	ine_push_color_style(ng.handle, INE_COL_LINK_HOVER, 0x60 << 24 | 0x88 << 16 | 0x88 << 8 | 0x88)
	ine_push_color_style(ng.handle, INE_COL_LINK_SELECT, 0x60 << 24 | 0x88 << 16 | 0x88 << 8 | 0x88)
	for l in ng.links {
		ine_link(ng.handle, c.int(l.id), c.int(l.from), c.int(l.to))
	}
	ine_pop_color_style(ng.handle)
	ine_pop_color_style(ng.handle)
	ine_pop_color_style(ng.handle)

	ine_minimap(ng.handle, 0.15, 1) // bottom right
	ine_editor_end(ng.handle)

	// Wire decorations over the dimmed base links: one styled wire per
	// link on the same bezier imnodes drew, anchored at the pin socket
	// centers captured while rendering the nodes.
	{
		wdl := im.GetWindowDrawList()
		now := im.GetTime()
		for l in ng.links {
			a, aok := pin_pos[l.from]
			b, bok := pin_pos[l.to]
			if !aok || !bok do continue
			sg_draw_link_wire(wdl, l, a, b, now)
		}
	}

	// Link gestures are staged. The JSON changes only after confirmation.
	created_a, created_b: c.int
	if ine_is_link_created(ng.handle, &created_a, &created_b) {
		from, to, error_message, ok := sg_validate_connection(ng, int(created_a), int(created_b))
		if ok {
			ng.pending_action = .CONNECT
			ng.pending_from, ng.pending_to = from, to
			ng.pending_link_id = -1
		} else {
			delete(ng.pipeline_error)
			ng.pipeline_error = strings.clone(error_message)
			notify(.ERROR, "pipeline: %s", error_message)
		}
	}
	destroyed_id: c.int
	if ng.pending_action == .NONE && ine_is_link_destroyed(ng.handle, &destroyed_id) {
		for link in ng.links {
			if link.id != int(destroyed_id) || !link.editable do continue
			ng.pending_action = .DISCONNECT
			ng.pending_from, ng.pending_to = link.from, link.to
			ng.pending_link_id = link.id
			break
		}
	}
	if ng.pending_action != .NONE do im.OpenPopup("##pipeline_change")
	if im.BeginPopup("##pipeline_change", {}) {
		action := "connect" if ng.pending_action == .CONNECT else "disconnect"
		im.TextUnformatted(fmt.ctprintf("%s pipeline edge", action))
		im.Separator()
		im.TextDisabled(strings_to_c(sg_pin_endpoint(ng, ng.pending_from)))
		im.TextUnformatted("→")
		im.TextDisabled(strings_to_c(sg_pin_endpoint(ng, ng.pending_to)))
		im.Spacing()
		im.TextDisabled(trc("invalid changes keep the last valid pipeline"))
		if im.Button(trc("apply")) {
			if ng.pending_action == .CONNECT {
				sg_append_pipeline_link(ng, ng.pending_from, ng.pending_to)
			} else {
				sg_remove_pipeline_link(ng, ng.pending_link_id)
			}
			delete(ng.pipeline_error)
			ng.pipeline_error = ""
			ng.save_pending = true
			sg_compute_layout(ng)
			ng.pending_action = .NONE
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button(trc("cancel")) {
			ng.pending_action = .NONE
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// Node drag trail: soft motes in the node's kind color while a node
	// moves (hovered node + left button held + fast cursor). Must run
	// AFTER ine_editor_end: imnodes asserts scope == None on queries.
	if io.MouseDown[im.MouseButton.Left] {
		moved := io.MouseDelta.x * io.MouseDelta.x + io.MouseDelta.y * io.MouseDelta.y
		nid: c.int
		if moved > 64 && ine_is_node_hovered(ng.handle, &nid) {
			for &n in ng.nodes {
				if c.int(n.id) != nid do continue
				px, py: f32
				ine_get_panning(ng.handle, &px, &py)
				kind_col := SG_KIND_COLORS[n.kind]
				fx_trail(&fx_settings^, {n.pos.x + px, n.pos.y + py}, kind_col)
				break
			}
		}
	}

	// Bolts over the pin shapes (see inject_marks above).
	for m in inject_marks {
		sg_draw_injected(im.GetWindowDrawList(), m.x, m.y)
	}

	// Click on a node opens its file's tab in the code editor (params
	// jumps to the scene's entry shader; resource nodes have no file).
	// Gated on release-without-drag so moving a node doesn't switch tabs.
	if im.IsMouseReleased(.Left) && !im.IsMouseDragging(.Left) {
		nid: c.int
		if ine_is_node_hovered(ng.handle, &nid) {
			for &n in ng.nodes {
				if c.int(n.id) != nid do continue
				target := n.file
				if target == "" && n.kind == .PARAMS {
					target = fmt.tprintf("scenes/%s/%s", ng.scene, ng.scene)
				}
				if target != "" {
					ied_load_named(ed, target)
					ed.open = true
				}
				break
			}
		}
	}

	// Maximize toggle, top-right over the canvas. FlattenChildren (bit 11,
	// not in the binding's ButtonFlag enum) lets the button receive clicks
	// although the imnodes child covers the area.
	{
		wp := im.GetWindowPos()
		ws := im.GetWindowSize()
		bx := wp.x + ws.x - 30
		by := wp.y + 8
		im.SetCursorScreenPos({bx, by})
		flatten := transmute(im.ButtonFlags)(i32(1) << 11)
		if im.InvisibleButton("##graph_max", {22, 22}, flatten) {
			maximized^ = !maximized^
		}
		hov := im.IsItemHovered()
		dl := im.GetWindowDrawList()
		col := im.GetColorU32Vec4(hov ? im.Vec4{0.87, 0.88, 0.90, 1} : im.Vec4{0.55, 0.57, 0.62, 1})
		if hov {
			im.DrawList_AddRectFilled(dl, {bx, by}, {bx + 22, by + 22}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 5)
		}
		// Glyph: maximize = square near the corner; restore = smaller
		// centered square.
		if maximized^ {
			im.DrawList_AddRect(dl, {bx + 7, by + 7}, {bx + 15, by + 15}, col, 0, 1.4)
		} else {
			im.DrawList_AddRect(dl, {bx + 5, by + 5}, {bx + 17, by + 17}, col, 0, 1.4)
		}
	}

	// Right-click on empty canvas: open the create popup and spawn the new
	// node at the clicked grid point (consumed by sg_upsert_node).
	if im.IsWindowHovered({.ChildWindows}) && im.IsMouseClicked(.Right) {
		nid: c.int
		if ine_is_node_hovered(ng.handle, &nid) {
			// Right-click on a user-authored node: context menu (delete).
			for &n in ng.nodes {
				if c.int(n.id) != nid do continue
				if strings.has_prefix(n.key, "uimg:") || strings.has_prefix(n.key, "uobj:") {
					if ng.delete_key != "" do delete(ng.delete_key)
					ng.delete_key = strings.clone(n.key)
					im.OpenPopup("##node_user_menu")
				}
				break
			}
		} else {
			gx, gy: f32
			ine_screen_to_grid(ng.handle, io.MousePos.x, io.MousePos.y, &gx, &gy)
			ng.create_pos = {gx, gy}
			ng.create_pos_set = true
			ng.create_open = true
		}
	}

	// Create-node popup (opened by a node's "+" or canvas right-click):
	// passes write a file into the scene's directory and append to the
	// chain on the next sync; image/3d object open the file picker.
	if ng.create_open {
		im.OpenPopup("##node_create")
		ng.create_open = false
	}
	if im.BeginPopup("##node_create") {
		im.TextDisabled(trc("create pass"))
		if im.Selectable(trc("graphics pass"), false, {}) {
			sg_create_pass(ng, ed, .GRAPHICS)
		}
		if im.Selectable(trc("compute pass"), false, {}) {
			sg_create_pass(ng, ed, .COMPUTE)
		}
		im.TextDisabled(trc("create resource"))
		if im.Selectable(trc("image"), false, {}) {
			ng.file_pick = .IMAGE
			im.OpenPopup("##node_pick_file")
		}
		if im.Selectable(trc("3d object"), false, {}) {
			ng.file_pick = .OBJECT3D
			im.OpenPopup("##node_pick_file")
		}
		im.EndPopup()
	}

	// File picker for resource nodes: image nodes take an image from
	// assets/ (root or skybox), 3d object nodes a model from
	// assets/models/. The node spawns at the right-clicked grid point.
	if im.BeginPopup("##node_pick_file") {
		im.TextDisabled(trc("choose model") if ng.file_pick == .OBJECT3D else trc("choose image"))
		if ng.file_pick == .OBJECT3D {
			for path in sg_asset_files("assets/models", ".glb") {
				if im.Selectable(strings_to_c(path), false, {}) {
					sg_create_user_node(ng, .OBJECT3D, path)
					im.CloseCurrentPopup()
				}
			}
		} else {
			for path in sg_image_files() {
				if im.Selectable(strings_to_c(path), false, {}) {
					sg_create_user_node(ng, .IMAGE, path)
					im.CloseCurrentPopup()
				}
			}
		}
		im.EndPopup()
	}

	// User-node context menu.
	if im.BeginPopup("##node_user_menu") {
		if im.Selectable(trc("delete node"), false, {}) {
			sg_delete_user_node(ng)
		}
		im.EndPopup()
	}

	// Two-finger trackpad pan, momentum model ("ice"): while the fingers
	// scroll, deltas move the panning 1:1 (interactive, no lag) and the
	// gesture velocity is sampled; after release the velocity glides on
	// with exponential friction until it dies. The sign is "viewport
	// moves with the fingers" (scroll-down drags the graph down/left),
	// the inverse of document scrolling. The hover test is ImGui's, not
	// imnodes' IsEditorHovered: that one is evaluated with the editor
	// child popped (current window is the panel again), and reports false
	// over the canvas: gating on it killed every pan. ChildWindows counts
	// the canvas child (and the minimap) as part of the panel.
	if im.IsWindowHovered({.ChildWindows}) && (io.MouseWheel != 0 || io.MouseWheelH != 0) {
		d := [2]f32{io.MouseWheelH * 60, io.MouseWheel * 60}
		cur: [2]f32
		ine_get_panning(ng.handle, &cur.x, &cur.y)
		// Velocity sample of the gesture (smoothed against jitter, capped
		// so a hitch can't fling the canvas away).
		dt := max(io.DeltaTime, 1e-4)
		sample := [2]f32{d.x / dt, d.y / dt}
		speed := math.sqrt(sample.x * sample.x + sample.y * sample.y)
		if speed > sg_pan_max_speed {
			sample *= sg_pan_max_speed / speed
		}
		ng.pan_vel = ng.pan_vel * 0.4 + sample * 0.6
		ine_reset_panning(ng.handle, cur.x + d.x, cur.y + d.y)
		if pan_test_debug {
			log.infof(
				"[pan-debug] PANNED by (%.0f, %.0f) vel (%.0f, %.0f)",
				d.x, d.y, ng.pan_vel.x, ng.pan_vel.y,
			)
		}
	} else if ng.pan_vel != {} {
		// Inertia: friction eases the velocity to zero.
		dt := io.DeltaTime
		cur: [2]f32
		ine_get_panning(ng.handle, &cur.x, &cur.y)
		ine_reset_panning(ng.handle, cur.x + ng.pan_vel.x * dt, cur.y + ng.pan_vel.y * dt)
		ng.pan_vel *= math.exp(-sg_pan_friction * dt)
		if abs(ng.pan_vel.x) < 1 && abs(ng.pan_vel.y) < 1 do ng.pan_vel = {}
	}
}

// Glide tuning, adjustable in the settings popup: the velocity decays
// exp(-sg_pan_friction * dt) after release (lower = icier, higher =
// tighter) and the momentum sample is capped at sg_pan_max_speed px/s.
sg_pan_friction:  f32 = 10
sg_pan_max_speed: f32 = 1000


// Set by --pan-test (main.odin): logs the pan vector as wheel deltas move it.
pan_test_debug: bool
