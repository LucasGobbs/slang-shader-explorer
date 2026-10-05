// Integrated ImGui shader editor (Dear ImGui + goossens' ImGuiColorTextEdit
// via the ite C wrapper): a floating window toggled with F1, separate from
// the sidebar. Its tabs follow the active scene: the scene file plus every
// module it transitively imports. Cmd+S is the application-wide save
// (every dirty tab, shader files are the app's only persistent state);
// the scene watcher rebuilds on write. Cmd+click jumps to the definition
// (current file first, then the other .slang files, e.g. common.slang).
package main

import im "../vendor/odin-imgui"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

foreign import ite "../vendor/ImGuiColorTextEdit/libite.a"

@(default_calling_convention = "c")
foreign ite {
	ite_create :: proc() -> rawptr ---
	ite_destroy :: proc(ed: rawptr) ---
	ite_set_text :: proc(ed: rawptr, utf8: cstring) ---
	ite_get_text :: proc(ed: rawptr) -> cstring ---
	ite_render :: proc(ed: rawptr, title: cstring, width: f32, height: f32) -> bool ---
	ite_set_tab_size :: proc(ed: rawptr, size: c.size_t) ---
	ite_set_leading_whitespace_only :: proc(ed: rawptr, on: bool) ---
	ite_get_undo_index :: proc(ed: rawptr) -> c.size_t ---
	ite_is_mouse_over_text :: proc(ed: rawptr, x: f32, y: f32) -> bool ---
	ite_get_word_at_mouse :: proc(ed: rawptr, x: f32, y: f32, buf: cstring, cap: c.size_t) -> c.size_t ---
	ite_goto_line :: proc(ed: rawptr, line: c.size_t) ---
	ite_get_cursor_line :: proc(ed: rawptr) -> c.size_t ---
	ite_get_cursor_col :: proc(ed: rawptr) -> c.size_t ---
	ite_set_cursor_pos :: proc(ed: rawptr, line: c.size_t, col: c.size_t) ---
	ite_duplicate_line :: proc(ed: rawptr) ---
	ite_set_glass :: proc(ed: rawptr, on: bool, alpha: f32) ---
	ite_set_fade :: proc(ed: rawptr, alpha: f32) ---
	ite_set_palette_u32 :: proc(ed: rawptr, colors: [^]u32, count: c.size_t) ---
	ite_use_dark_palette :: proc(ed: rawptr) ---
	ite_use_light_palette :: proc(ed: rawptr) ---
	ite_clear_diagnostics :: proc(ed: rawptr) ---
	ite_add_squiggle :: proc(ed: rawptr, line: c.size_t, col: c.size_t, msg: cstring) ---
	ite_add_squiggle_range :: proc(ed: rawptr, sl: c.size_t, sc: c.size_t, el: c.size_t, ec: c.size_t, msg: cstring) ---
	ite_add_error_marker :: proc(ed: rawptr, line: c.size_t, msg: cstring) ---
	ite_install_context_menu :: proc(ed: rawptr) ---
	ite_take_goto_word :: proc(ed: rawptr, buf: cstring, cap: c.size_t) -> bool ---
	ite_take_rename_word :: proc(ed: rawptr, buf: cstring, cap: c.size_t) -> bool ---
	ite_enable_completion :: proc(ed: rawptr, fn: IteCompletionFn, user: rawptr) ---
	ite_set_change_callback :: proc(ed: rawptr, fn: IteChangeFn, user: rawptr) ---
}

IteCompletionFn :: #type proc "c" (search_term: cstring, line: c.size_t, col: c.size_t, user: rawptr, buf: [^]u8, cap: c.size_t) -> c.int
IteChangeFn :: #type proc "c" (user: rawptr)

// Debug/self-test knobs (set from os.args in main).
ied_debug_clicks: bool
ied_selftest:     bool
ied_selftest_frame: int
// Self-test only: overrides the hovered word so the docs tooltip can be
// exercised without mouse input.
ied_debug_hover_word: string
// Cmd/Shift tracked from raw SDL key events (io.KeySuper proved unreliable).
ied_gui_held:   bool
ied_shift_held: bool

SHADER_DIR :: "src/shaders"

// One open document (a tab). `text` stashes the buffer while the tab is not
// the visible one so switching preserves unsaved edits; `dirty` is sticky
// because the component's undo index resets on every SetText.
OpenDoc :: struct {
	file:   int,   // index into ImGuiEditor.files
	text:   string, // owned; valid once loaded == true
	loaded: bool,
	dirty:  bool,
	last_good: string, // owned; source text from the last loadable pipeline
}

ImGuiEditor :: struct {
	handle:      rawptr,
	open:        bool, // floating window visible (F1 toggles)
	files:       [dynamic]string, // relative to SHADER_DIR, no .slang ("apple" -> "scenes/apple")
	current:     int,        // index into files of the visible document (-1: none)
	open_docs:   [dynamic]OpenDoc,
	current_open: int,       // index into open_docs of the visible document (-1: none)
	status:      string,
	saved_undo:  c.size_t,
	font_size:   f32, // code font in points; the UI font is Ui.font_size
	last_scene:  string,
	bg_transparent: bool,
	// Glass mode transparency (component palette + window frame alpha);
	// edited in the settings gear popup.
	glass_alpha: f32,
	theme:       EditorTheme,
	// Deferred goto-definition: the component moves the cursor to the click
	// point during Render of the same frame, clobbering an immediate jump,
	// so the word is recorded on click and the jump runs next frame.
	goto_word:   string,
	goto_pending: bool,
	// Diagnostics push caching.
	err_version: int,
	err_file:    int,
	// Live LSP sync: the component's change callback marks the document
	// dirty (works for typing AND programmatic SetText, unlike undo-index
	// deltas which SetText resets); the frame counter debounces ~300ms.
	lsp_dirty: bool,
	lsp_change_frames: int,
	lsp_diag_version: int,
	build_success_version: int,
	// Hover symbol docs: the word under the mouse is tracked while it
	// dwells (~0.4 s), then resolved once into a signature + doc comment
	// (ied_lookup_symbol) shown as a tooltip. Once shown, the tooltip
	// pins in place and stays alive while the mouse is inside it, so
	// long docs can actually be scrolled.
	hover_word:  string, // owned
	hover_dwell: int,
	hover_sig:   string, // owned; "" = unresolved/hidden
	hover_doc:   string, // owned
	hover_shown: bool,
	hover_pin:   im.Vec2, // pinned tooltip position
	hover_rect:  [4]f32, // last tooltip rect (min.xy, max.xy), padded
	hover_grace: f32,    // countdown while crossing from word to tooltip
	// The window docks to the right edge until the user drags its title
	// bar somewhere else; after that ImGui owns the position. F1 and
	// theater mode reset this, re-docking the window.
	moved:        bool,
	dock_display: [2]f32, // DisplaySize the dock position was forced for
	// FX motion state: open/close spring, the tab-switch crossfade
	// overlay, and the status row's fade-in.
	open_anim:    Anim,
	tab_flash:    f32,
	last_open_tab: int,
	status_fade:  f32,
	last_status:  string, // owned
	// Fixed backing for `status` (no temp-allocator string, so the
	// per-frame free_all in main never frees memory the UI still shows).
	status_buf: [256]u8,
	// Context-menu "Rename symbol": the word to rename (owned), popup open
	// request, and the InputText buffer for the new name.
	rename_word: string,
	rename_open: bool,
	rename_buf:  [64]u8,
	// Navigation history (Option+'-' jumps back): cursor positions worth
	// returning to: goto-definition origins and moves larger than a few
	// lines. Keeps the last 32 (at least the 10 requested).
	nav_history:  [dynamic]NavPos,
	nav_snapshot: NavPos,
	nav_valid:    bool,
	// Typing-FX (power mode): text area origin for caret particle bursts.
	text_pos:      [2]f32,
	line_h:        f32, // the component's real line height (from ImGui)
	char_w:        f32, // measured glyph advance of the editor font
	type_burst_ns: i64,
	// Ice scroll: wheel velocity that glides with exponential friction.
	scroll_vel: f32,
}

NavPos :: struct {
	file: int, // index into ImGuiEditor.files
	line: int,
	col:  int,
}

// Component change callback: marks the document as needing an LSP sync,
// and fires the typing-FX burst at the caret (throttled, a keystroke
// storm reads as a spray, not a machine gun).
ied_on_change :: proc "c" (user: rawptr) {
	context = runtime.default_context()
	ed := (^ImGuiEditor)(user)
	ed.lsp_dirty = true
	ed.lsp_change_frames = 0
	if fx_settings == nil || !fx_on(fx_settings) || !fx_settings.particles do return
	now := time.to_unix_nanoseconds(time.now())
	if now-ed.type_burst_ns < 90 * i64(time.Millisecond) do return
	ed.type_burst_ns = now
	// Caret in pixels: real line metric from the component (the guessed
	// 1.15× font size drifted a full line by mid-file), centered on the
	// line, past the line-number gutter on X.
	at := [2]f32 {
		ed.text_pos.x + ed.char_w * 4 + f32(ite_get_cursor_col(ed.handle)) * ed.char_w,
		ed.text_pos.y + (f32(ite_get_cursor_line(ed.handle)) + 0.5) * ed.line_h,
	}
	fx_burst(fx_settings, at, 6, 6, 90)
	log.debugf("[typefx] line %d text_pos=(%.0f,%.0f) line_h=%.0f -> y %.0f", int(ite_get_cursor_line(ed.handle)), ed.text_pos.x, ed.text_pos.y, ed.line_h, at.y)
	// Soft keypress click alongside the ink (ASMR set, random variant).
	fx_sfx_play(.TYPE)
}

EditorTheme :: enum {
	DARK,
	LIGHT,
	MONOKAI,
	SOLARIZED,
}

// Short labels: the toolbar combo is narrow so the row always fits the
// panel (long names pushed it past the right edge).
THEME_NAMES := [EditorTheme]string{
	.DARK      = "dark",
	.LIGHT     = "light",
	.MONOKAI   = "monokai",
	.SOLARIZED = "solarized",
}

// ImU32 is ABGR: (a<<24)|(b<<16)|(g<<8)|r.
col32 :: proc(r, g, b: u32, a: u32 = 255) -> u32 {
	return (a << 24) | (b << 16) | (g << 8) | r
}

// Palette slots, component Color enum order: text, keyword, declaration,
// number, string, punctuation, preprocessor, identifier, knownIdentifier,
// comment, background, cursor, selection, whitespace, matchingBracketBackground,
// matchingBracketActive, matchingBracketLevel1..3, matchingBracketError,
// lineNumber, currentLineNumber, currentLineHighlight, currentLineHighlightBorder.
theme_monokai :: proc() -> [24]u32 {
	return [24]u32{
	col32(0xF8, 0xF8, 0xF2), // text
	col32(0xF9, 0x26, 0x72), // keyword
	col32(0x66, 0xD9, 0xEF), // declaration
	col32(0xAE, 0x81, 0xFF), // number
	col32(0xE6, 0xDB, 0x74), // string
	col32(0xF8, 0xF8, 0xF2), // punctuation
	col32(0xF9, 0x26, 0x72), // preprocessor
	col32(0xF8, 0xF8, 0xF2), // identifier
	col32(0x66, 0xD9, 0xEF), // knownIdentifier
	col32(0x75, 0x71, 0x5E), // comment
	col32(0x27, 0x28, 0x22), // background
	col32(0xF8, 0xF8, 0xF0), // cursor
	col32(0x49, 0x48, 0x3E), // selection
	col32(0x3B, 0x3A, 0x32), // whitespace
	col32(0x49, 0x48, 0x3E), // matchingBracketBackground
	col32(0xA6, 0xE2, 0x2E), // matchingBracketActive
	col32(0xA6, 0xE2, 0x2E), // matchingBracketLevel1
	col32(0x66, 0xD9, 0xEF), // matchingBracketLevel2
	col32(0xFD, 0x97, 0x1F), // matchingBracketLevel3
	col32(0xF9, 0x26, 0x72), // matchingBracketError
	col32(0x75, 0x71, 0x5E), // lineNumber
	col32(0xF8, 0xF8, 0xF2), // currentLineNumber
	col32(0x3E, 0x3D, 0x32), // currentLineHighlight
	col32(0x3E, 0x3D, 0x32), // currentLineHighlightBorder
	}
}

theme_solarized :: proc() -> [24]u32 {
	return [24]u32{
	col32(0x83, 0x94, 0x96), // text (base0)
	col32(0x85, 0x99, 0x00), // keyword (green)
	col32(0x26, 0x8B, 0xD2), // declaration (blue)
	col32(0xD3, 0x36, 0x82), // number (magenta)
	col32(0x2A, 0xA1, 0x98), // string (cyan)
	col32(0x83, 0x94, 0x96), // punctuation
	col32(0xCB, 0x4B, 0x16), // preprocessor (orange)
	col32(0x83, 0x94, 0x96), // identifier
	col32(0x26, 0x8B, 0xD2), // knownIdentifier
	col32(0x58, 0x6E, 0x75), // comment (base01)
	col32(0x00, 0x2B, 0x36), // background (base03)
	col32(0x93, 0xA1, 0xA1), // cursor (base1)
	col32(0x07, 0x36, 0x42), // selection (base02)
	col32(0x07, 0x36, 0x42), // whitespace
	col32(0x07, 0x36, 0x42), // matchingBracketBackground
	col32(0xB5, 0x89, 0x00), // matchingBracketActive (yellow)
	col32(0xB5, 0x89, 0x00), // matchingBracketLevel1
	col32(0x26, 0x8B, 0xD2), // matchingBracketLevel2
	col32(0xCB, 0x4B, 0x16), // matchingBracketLevel3
	col32(0xDC, 0x32, 0x2F), // matchingBracketError (red)
	col32(0x58, 0x6E, 0x75), // lineNumber
	col32(0x93, 0xA1, 0xA1), // currentLineNumber
	col32(0x07, 0x36, 0x42), // currentLineHighlight
	col32(0x07, 0x36, 0x42), // currentLineHighlightBorder
	}
}

ied_apply_theme :: proc(ed: ^ImGuiEditor) {
	switch ed.theme {
	case .DARK:
		ite_use_dark_palette(ed.handle)
	case .LIGHT:
		ite_use_light_palette(ed.handle)
	case .MONOKAI:
		p := theme_monokai()
		ite_set_palette_u32(ed.handle, &p[0], len(p))
	case .SOLARIZED:
		p := theme_solarized()
		ite_set_palette_u32(ed.handle, &p[0], len(p))
	}
	// Glass mode's saved palette is stale after a theme swap; re-entering
	// glass re-saves from the new theme (wrapper resets the flag).
}

// The slangd instance backing autocomplete (nil when unavailable, the
// editor then just never pops suggestions).
ied_lsp: ^Lsp

// Render-thread callback for the autocomplete popup: syncs the document to
// slangd and returns matching completion items, newline-separated.
ied_completion_cb :: proc "c" (search_term: cstring, line: c.size_t, col: c.size_t, user: rawptr, buf: [^]u8, cap: c.size_t) -> c.int {
	context = runtime.default_context()
	ed := (^ImGuiEditor)(user)
	if ied_lsp == nil || ed.current < 0 do return 0
	uri := ied_current_uri(ed)
	text := string(ite_get_text(ed.handle))
	items := lsp_complete(ied_lsp, uri, text, int(line), int(col))
	if len(items) == 0 do return 0
	n := 0
	off := 0
	term := strings.to_lower(string(search_term), context.temp_allocator)
	for item in items {
		// slangd ranks server-side; we only hard-filter by the typed prefix.
		if term != "" && !strings.has_prefix(strings.to_lower(item.label, context.temp_allocator), term) do continue
		if n >= 24 do break // keep the popup tight
		need := len(item.label) + 1
		if off + need >= int(cap) do break
		copy(buf[off:cap], item.label)
		off += len(item.label)
		buf[off] = '\n'
		off += 1
		n += 1
	}
	return c.int(n)
}

ied_init :: proc() -> ^ImGuiEditor {
	ed := new(ImGuiEditor)
	ed.handle = ite_create()
	ite_set_tab_size(ed.handle, 4)
	ite_set_leading_whitespace_only(ed.handle, true)
	ite_install_context_menu(ed.handle)
	ed.current = -1
	ed.current_open = -1
	ed.err_file = -1
	ed.font_size = 16
	ed.glass_alpha = 0.55
	ed.open = true
	ed.theme = .MONOKAI
	ied_apply_theme(ed)
	ed.last_open_tab = -1
	ed.status_fade = 1

	// slangd autocomplete (LSP): graceful no-op when the server is absent.
	if ied_lsp == nil {
		ied_lsp = lsp_start()
	}
	if ied_lsp != nil {
		ite_enable_completion(ed.handle, ied_completion_cb, ed)
		ite_set_change_callback(ed.handle, ied_on_change, ed)
	}

	ied_scan_dir(ed, "")
	ied_scan_scene_dirs(ed)
	log.infof("[imgui-editor] %d shaders under %s", len(ed.files), SHADER_DIR)
	return ed
}

// Scene units are directories under scenes/: scans each subdirectory's
// .slang files as "scenes/<unit>/<file>".
ied_scan_scene_dirs :: proc(ed: ^ImGuiEditor) {
	dir_path := fmt.tprintf("%s/scenes", SHADER_DIR)
	dir_handle, open_err := os.open(dir_path)
	if open_err != nil do return
	entries, dir_err := os.read_dir(dir_handle, -1, context.temp_allocator)
	os.close(dir_handle)
	if dir_err != nil do return
	for entry in entries {
		if entry.type != .Directory do continue
		ied_scan_dir(ed, fmt.tprintf("scenes/%s", entry.name))
	}
}

ied_scan_dir :: proc(ed: ^ImGuiEditor, sub: string) {
	dir := SHADER_DIR
	if sub != "" {
		dir = fmt.tprintf("%s/%s", SHADER_DIR, sub)
	}
	dir_handle, open_err := os.open(dir)
	if open_err != nil do return
	entries, dir_err := os.read_dir(dir_handle, -1, context.allocator)
	os.close(dir_handle)
	if dir_err != nil do return
	for entry in entries {
		if entry.type == .Directory {
			// Scenes live in per-scene folders (scenes/apple/apple.slang):
			// recurse so FILES and tabs see them.
			next := entry.name
			if sub != "" {
				next = fmt.tprintf("%s/%s", sub, entry.name)
			}
			ied_scan_dir(ed, next)
			continue
		}
		if !strings.has_suffix(entry.name, ".slang") do continue
		name := strings.trim_suffix(entry.name, ".slang")
		if sub != "" {
			name = fmt.tprintf("%s/%s", sub, name)
		}
		// Dedupe: rescans append only newly discovered files, keeping
		// OpenDoc.file indices stable.
		exists := false
		for f in ed.files {
			if f == name {
				exists = true
				break
			}
		}
		if exists do continue
		append(&ed.files, strings.clone(name))
	}
}

// Rediscover shader files (template-created scenes, files added
// externally). Deleted files stay listed: removing entries would
// invalidate OpenDoc.file indices.
ied_rescan :: proc(ed: ^ImGuiEditor) {
	ied_scan_dir(ed, "")
	ied_scan_scene_dirs(ed)
}

ied_file_path :: proc(ed: ^ImGuiEditor, idx: int) -> string {
	return fmt.tprintf("%s/%s.slang", SHADER_DIR, ed.files[idx])
}

ied_current_uri :: proc(ed: ^ImGuiEditor) -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.tprintf("file://%s/%s", cwd, ied_file_path(ed, ed.current))
}

// Make open_docs[open_idx] the visible document, loading its buffer from the
// stash (or disk on first open). Does NOT stash the outgoing document: use
// ied_switch for user-driven tab switches.
ied_show :: proc(ed: ^ImGuiEditor, open_idx: int) {
	doc := &ed.open_docs[open_idx]
	if !doc.loaded {
		data, err := os.read_entire_file(ied_file_path(ed, doc.file), context.allocator)
		if err != nil {
			ed.status = fmt.bprintf(ed.status_buf[:], tr("could not read %s"), ied_file_path(ed, doc.file))
			return
		}
		doc.text = strings.clone(string(data))
		doc.loaded = true
		if doc.last_good == "" do doc.last_good = strings.clone(doc.text)
	}
	ed.current_open = open_idx
	ed.current = doc.file
	ite_set_text(ed.handle, strings.clone_to_cstring(doc.text, context.temp_allocator))
	ed.saved_undo = ite_get_undo_index(ed.handle)
	// Force a re-sync of the freshly shown document to slangd.
	ed.lsp_dirty = true
	ed.lsp_change_frames = 18
}

// Switch the visible document to open_docs[open_idx], stashing the outgoing
// buffer so unsaved edits survive the round-trip.
ied_switch :: proc(ed: ^ImGuiEditor, open_idx: int) {
	if open_idx < 0 || open_idx >= len(ed.open_docs) || open_idx == ed.current_open do return
	if ed.current_open >= 0 && ed.current_open < len(ed.open_docs) {
		out := &ed.open_docs[ed.current_open]
		delete(out.text)
		out.text = strings.clone(string(ite_get_text(ed.handle)))
		out.loaded = true
		out.dirty = out.dirty || ite_get_undo_index(ed.handle) != ed.saved_undo
	}
	ied_show(ed, open_idx)
}

// Open file idx in a tab (or switch to its tab when already open).
ied_load :: proc(ed: ^ImGuiEditor, idx: int) {
	if idx < 0 || idx >= len(ed.files) do return
	for doc, i in ed.open_docs {
		if doc.file == idx {
			ied_switch(ed, i)
			return
		}
	}
	append(&ed.open_docs, OpenDoc{file = idx})
	ied_switch(ed, len(ed.open_docs) - 1)
}

// Close the tab open_docs[open_idx]; shows a neighbor when the closed tab was
// the visible one.
ied_close :: proc(ed: ^ImGuiEditor, open_idx: int) {
	if open_idx < 0 || open_idx >= len(ed.open_docs) do return
	delete(ed.open_docs[open_idx].text)
	delete(ed.open_docs[open_idx].last_good)
	ordered_remove(&ed.open_docs, open_idx)
	if ed.current_open > open_idx {
		ed.current_open -= 1
	} else if ed.current_open == open_idx {
		// The visible document is gone; show a neighbor without stashing.
		if len(ed.open_docs) > 0 {
			ied_show(ed, min(open_idx, len(ed.open_docs) - 1))
		} else {
			ed.current_open = -1
			ed.current = -1
			ite_set_text(ed.handle, "")
			ed.saved_undo = ite_get_undo_index(ed.handle)
			ed.status = ""
		}
	}
}

ied_load_named :: proc(ed: ^ImGuiEditor, name: string) {
	for f, i in ed.files {
		if f == name {
			ied_load(ed, i)
			return
		}
	}
}

// Closes open docs under scenes/<unit>/. On a scene switch the previous
// unit's tabs go away, EXCEPT dirty ones: unsaved work is never
// destroyed, so those stay until the user saves (ied_save_all reaps them
// once clean).
ied_close_unit :: proc(ed: ^ImGuiEditor, unit: string) {
	if unit == "" do return
	prefix := fmt.tprintf("scenes/%s/", unit)
	live_undo := ite_get_undo_index(ed.handle)
	// Walk backwards: ied_close mutates open_docs in place.
	for i := len(ed.open_docs) - 1; i >= 0; i -= 1 {
		doc := &ed.open_docs[i]
		rel := ed.files[doc.file]
		if !strings.has_prefix(rel, prefix) do continue
		dirty := doc.dirty || (i == ed.current_open && live_undo != ed.saved_undo)
		if dirty do continue
		ied_close(ed, i)
	}
}

// Parse a slang import line: `import "../common";` (quoted, resolved
// relative to the importing file) or `import common;` (bare module,
// resolved at the SHADER_DIR root). Returns the raw import target.
ied_parse_import :: proc(line: string) -> (target: string, ok: bool) {
	l := strings.trim_left_space(line)
	if !strings.has_prefix(l, "import") do return "", false
	l = strings.trim_left_space(l[len("import"):])
	if l == "" do return "", false
	if l[0] == '"' {
		end := strings.index_byte(l[1:], '"')
		if end < 0 do return "", false
		return l[1:1 + end], true
	}
	end := strings.index_byte(l, ';')
	if end < 0 do return "", false
	return strings.trim_space(l[:end]), true
}

// Resolve an import target to a files-list name (relative to SHADER_DIR,
// no extension): quoted relative paths against the importing file's
// directory, bare names at the root.
ied_resolve_import :: proc(from_rel, target: string) -> string {
	target := strings.trim_suffix(target, ".slang")
	full := target
	if strings.has_prefix(target, ".") {
		if slash := strings.last_index(from_rel, "/"); slash >= 0 {
			full = fmt.tprintf("%s/%s", from_rel[:slash], target)
		}
	}
	// Normalize: resolve "." and ".." segments.
	parts := strings.split(full, "/", context.temp_allocator)
	out: [dynamic]string
	for p in parts {
		switch p {
		case "", ".":
		case "..":
			if len(out) > 0 do pop(&out)
		case:
			append(&out, p)
		}
	}
	return strings.join(out[:], "/", context.temp_allocator)
}

// The scene file plus every transitively imported module, breadth-first,
// scene first. Names match ImGuiEditor.files entries.
ied_scene_files :: proc(ed: ^ImGuiEditor, scene_rel: string) -> [dynamic]string {
	result := make([dynamic]string, 0, 8, context.temp_allocator)
	visited := make(map[string]bool, 16, context.temp_allocator)
	queue := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&queue, scene_rel)
	visited[scene_rel] = true
	for i := 0; i < len(queue); i += 1 {
		rel := queue[i]
		data, err := os.read_entire_file(
			fmt.tprintf("%s/%s.slang", SHADER_DIR, rel),
			context.temp_allocator,
		)
		if err != nil do continue
		append(&result, rel)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			target, ok := ied_parse_import(line)
			if !ok do continue
			resolved := ied_resolve_import(rel, target)
			if resolved == "" || visited[resolved] do continue
			visited[resolved] = true
			append(&queue, resolved)
		}
	}
	return result
}

// The files-list name of a scene: scenes/<title>.slang or, since scenes
// moved to per-scene folders, scenes/<title>/<title>.slang, matched by
// base name. "" when unknown.
ied_scene_rel :: proc(ed: ^ImGuiEditor, scene_name: string) -> string {
	for f in ed.files {
		if !strings.has_prefix(f, "scenes/") do continue
		base := f
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		if base == scene_name {
			return f
		}
	}
	return ""
}

// Follow the rendered scene: open its tab plus a tab per imported module
// (the scene ends up visible). Runs on scene change only; tabs the user
// opened for unrelated files are left alone.
ied_open_scene :: proc(ed: ^ImGuiEditor, scene_name: string) {
	if scene_name == ed.last_scene do return
	// Leaving a scene: its tabs close (dirty ones wait for the user to
	// save; they are reaped by ied_save_all once clean).
	old_scene := ed.last_scene
	ed.last_scene = scene_name
	ied_close_unit(ed, old_scene)
	scene_rel := ied_scene_rel(ed, scene_name)
	if scene_rel == "" do return
	files := ied_scene_files(ed, scene_rel)
	for rel, i in files {
		if i == 0 do continue // the scene itself is opened last
		ied_load_named(ed, rel)
	}
	ied_load_named(ed, scene_rel)
	// Force a re-sync of the freshly shown file to slangd.
	ed.lsp_dirty = true
	ed.lsp_change_frames = 18
}

// Save every modified open document. Shader files are the app's only
// persistent state, so this IS the application-wide save (Cmd+S and the
// toolbar's "save all"). The visible document's text is stashed first so
// its latest edits are included. Returns the number of files written.
ied_save_all :: proc(ed: ^ImGuiEditor) -> int {
	if ed.current_open >= 0 && ed.current_open < len(ed.open_docs) {
		vis := &ed.open_docs[ed.current_open]
		delete(vis.text)
		vis.text = strings.clone(string(ite_get_text(ed.handle)))
		vis.loaded = true
		vis.dirty = vis.dirty || ite_get_undo_index(ed.handle) != ed.saved_undo
	}
	saved := 0
	for &doc in ed.open_docs {
		if !doc.loaded || !doc.dirty do continue
		path := ied_file_path(ed, doc.file)
		if os.write_entire_file(path, transmute([]u8)doc.text) != nil {
			ed.status = fmt.bprintf(ed.status_buf[:], tr("ERROR writing %s"), path)
			continue
		}
		doc.dirty = false
		saved += 1
	}
	if ed.current_open >= 0 {
		ed.saved_undo = ite_get_undo_index(ed.handle)
	}
	// Reap the now-clean tabs that don't belong to the current scene:
	// dirty tabs survived the switch so the user could save them; once
	// saved, they go away (shared files outside scenes/ never close).
	if saved > 0 && ed.last_scene != "" {
		current_prefix := fmt.tprintf("scenes/%s/", ed.last_scene)
		for i := len(ed.open_docs) - 1; i >= 0; i -= 1 {
			doc := &ed.open_docs[i]
			rel := ed.files[doc.file]
			if !strings.has_prefix(rel, "scenes/") do continue
			if strings.has_prefix(rel, current_prefix) do continue
			if doc.dirty do continue
			ied_close(ed, i)
		}
	}
	h, m, s := time.clock(time.now())
	if saved > 0 {
		ed.status = fmt.bprintf(ed.status_buf[:], tr("saved %d file(s) at %02d:%02d:%02d"), saved, h, m, s)
	} else {
		ed.status = fmt.bprintf(ed.status_buf[:], "%s", tr("nothing to save"))
	}
	return saved
}

ied_capture_last_good :: proc(ed: ^ImGuiEditor) {
	for &doc in ed.open_docs {
		if !doc.loaded || doc.dirty do continue
		data, err := os.read_entire_file(ied_file_path(ed, doc.file), context.temp_allocator)
		if err != nil do continue
		delete(doc.last_good)
		doc.last_good = strings.clone(string(data))
	}
}

ied_has_current_build_error :: proc(ed: ^ImGuiEditor) -> bool {
	if ed.current < 0 do return false
	rel := ed.files[ed.current]
	sync.mutex_lock(&scene_build_mu)
	defer sync.mutex_unlock(&scene_build_mu)
	for be in build_errors {
		if be.file == rel do return true
	}
	return false
}

ied_restore_last_good :: proc(ed: ^ImGuiEditor) -> bool {
	if ed.current_open < 0 || ed.current_open >= len(ed.open_docs) do return false
	doc := &ed.open_docs[ed.current_open]
	if doc.last_good == "" do return false
	ite_set_text(ed.handle, strings.clone_to_cstring(doc.last_good, context.temp_allocator))
	delete(doc.text)
	doc.text = strings.clone(doc.last_good)
	doc.loaded = true
	doc.dirty = true
	ed.lsp_dirty = true
	ed.lsp_change_frames = 0
	ed.status = fmt.bprintf(ed.status_buf[:], tr("restored last compiled version of %s"), ed.files[doc.file])
	return true
}

// Find a definition for word in text: a top-level line (column 0) declaring
// `word` as a function ("<ret> word(") or struct ("struct word", tolerating
// modifiers like "public").
ied_find_definition :: proc(text: string, word: string) -> (line: int, found: bool) {
	if word == "" do return 0, false
	needle := strings.concatenate({word, "("}, context.temp_allocator)
	struct_needle := strings.concatenate({"struct ", word}, context.temp_allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	for ln, i in lines {
		if ln == "" || ln[0] == ' ' || ln[0] == '\t' || ln[0] == '/' do continue
		if strings.contains(ln, struct_needle) do return i, true
		idx := strings.index(ln, needle)
		if idx > 0 {
			prefix := ln[:idx]
			if !strings.contains(prefix, "=") do return i, true
		}
	}
	return 0, false
}

// Symbol docs for a word in text: the trimmed definition line (multi-line
// signatures joined) plus the contiguous //-comment block directly above
// it, newest line last. All strings use the temp allocator.
ied_symbol_in_text :: proc(text: string, word: string) -> (sig, doc: string, found: bool) {
	def, ok := ied_find_definition(text, word)
	if !ok do return "", "", false
	lines := strings.split_lines(text, context.temp_allocator)
	sig = strings.trim_space(lines[def])
	// Join continuation lines while the signature has no closing paren
	// (Slang parameters often wrap).
	for i := def + 1; !strings.contains(sig, ")") && i < len(lines); i += 1 {
		sig = fmt.tprintf("%s %s", sig, strings.trim_space(lines[i]))
	}
	// Doc block: contiguous // lines directly above the definition.
	end := def - 1
	for end >= 0 {
		l := strings.trim_space(lines[end])
		if l != "" do break
		end -= 1
	}
	start := end
	for start >= 0 {
		l := strings.trim_space(lines[start])
		if !strings.has_prefix(l, "//") do break
		start -= 1
	}
	if end >= 0 && start < end {
		for i := start + 1; i <= end; i += 1 {
			line := strings.trim_prefix(strings.trim_space(lines[i]), "//")
			if doc == "" {
				doc = strings.trim_space(line)
			} else {
				doc = fmt.tprintf("%s\n%s", doc, strings.trim_space(line))
			}
		}
	}
	return sig, doc, true
}

// Curated docs for the Slang builtins the trail uses most. Consulted only
// when no user definition resolves, so project symbols always win.
IedBuiltinDoc :: struct {
	name, sig, doc: string,
}
IED_BUILTIN_DOCS := []IedBuiltinDoc {
	{
		"clamp",
		"T clamp<T>(T x, T minVal, T maxVal)",
		"Constrains x to [minVal, maxVal]: below minVal returns minVal, above maxVal returns maxVal. Works component-wise on vectors. clamp(uv, 0.0, 1.0) keeps coordinates inside the unit square.",
	},
	{
		"lerp",
		"T lerp<T>(T a, T b, S t)",
		"Linear interpolation: a + (b - a) * t. t = 0 gives a, t = 1 gives b, 0.5 the midpoint; t outside [0,1] extrapolates. GLSL calls this mix.",
	},
	{
		"smoothstep",
		"T smoothstep<T>(T edge0, T edge1, T x)",
		"Smooth Hermite transition from 0 to 1 as x goes from edge0 to edge1, with zero slope at both ends. The standard way to soften SDF edges: smoothstep(-w, w, d).",
	},
	{
		"step",
		"T step<T>(T edge, T x)",
		"0.0 when x < edge, 1.0 otherwise. A hard threshold; compare with smoothstep for a soft edge. step(0.5, uv.x) splits the image vertically.",
	},
	{
		"fract",
		"T fract<T>(T x)",
		"Fractional part: x - floor(x), always in [0,1). Tiling and repetition primitive: fract(uv * 4.0) repeats the pattern 4x per axis.",
	},
	{
		"ddx",
		"T ddx<T>(T x)",
		"Partial derivative of x along screen-space X, estimated from 2x2 pixel quads. Base of anti-aliased edges: fwidth(d) = abs(ddx(d)) + abs(ddy(d)).",
	},
	{
		"ddy",
		"T ddy<T>(T x)",
		"Partial derivative of x along screen-space Y, estimated from 2x2 pixel quads. Pair with ddx for fwidth-based filtering.",
	},
}

// Dismiss the hover docs tooltip; ESC maps here before app quit.
ied_hover_close :: proc(ed: ^ImGuiEditor) {
	ed.hover_dwell = 0
	ed.hover_shown = false
	if ed.hover_sig != "" {
		delete(ed.hover_sig)
		ed.hover_sig = ""
		delete(ed.hover_doc)
		ed.hover_doc = ""
	}
}

// Resolve a symbol for hover docs: current file first, then the other
// shaders (same search order as goto-definition), then the builtin table.
ied_lookup_symbol :: proc(ed: ^ImGuiEditor, word: string) -> (sig, doc: string, found: bool) {
	if sig2, doc2, ok := ied_symbol_in_text(string(ite_get_text(ed.handle)), word); ok {
		return sig2, doc2, true
	}
	for f, i in ed.files {
		if i == ed.current do continue
		data, err := os.read_entire_file(ied_file_path(ed, i), context.temp_allocator)
		if err != nil do continue
		if sig2, doc2, ok := ied_symbol_in_text(string(data), word); ok {
			return sig2, doc2, true
		}
	}
	for b in IED_BUILTIN_DOCS {
		if b.name == word do return b.sig, b.doc, true
	}
	return "", "", false
}

// Whole-word replace of old_name with new_name in text (identifier
// boundaries on both sides, so "fbm" doesn't touch "afbm"/"fbm2").
// Returns the original string and 0 when nothing matched.
text_replace_word :: proc(text, old_name, new_name: string) -> (string, int) {
	if old_name == "" do return text, 0
	sb := strings.builder_make(context.temp_allocator)
	count := 0
	start := 0
	for start <= len(text) - len(old_name) {
		idx := strings.index(text[start:], old_name)
		if idx < 0 do break
		i := start + idx
		end := i + len(old_name)
		is_word := (i == 0 || !sg_is_ident(text[i - 1])) && (end == len(text) || !sg_is_ident(text[end]))
		if !is_word {
			strings.write_string(&sb, text[start:end])
			start = end
			continue
		}
		strings.write_string(&sb, text[start:i])
		strings.write_string(&sb, new_name)
		start = end
		count += 1
	}
	if count == 0 do return text, 0
	strings.write_string(&sb, text[start:])
	return strings.to_string(sb), count
}

// Slang keywords/builtin types: renaming one of these would corrupt every
// file, so the rename command refuses them outright.
IED_KEYWORDS := []string {
	"if", "else", "for", "while", "switch", "case", "break", "continue", "return",
	"struct", "class", "import", "public", "static", "const", "in", "out", "inout",
	"void", "bool", "int", "uint", "float", "half", "double", "true", "false",
	"let", "var", "cbuffer", "typedef", "enum", "interface", "namespace",
	"groupshared", "uniform", "discard",
	"bool2", "bool3", "bool4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
	"float2", "float3", "float4", "half2", "half3", "half4",
	"double2", "double3", "double4",
	"Texture2D", "Texture3D", "TextureCube", "RWTexture2D", "SamplerState",
	"ConstantBuffer", "vector", "matrix",
}

ied_is_keyword :: proc(word: string) -> bool {
	for k in IED_KEYWORDS {
		if word == k do return true
	}
	return false
}

ied_open_doc :: proc(ed: ^ImGuiEditor, file_idx: int) -> (^OpenDoc, bool) {
	for &doc in ed.open_docs {
		if doc.file == file_idx do return &doc, true
	}
	return nil, false
}

// Renames old_name to new_name in every shader file (the context menu's
// "Rename symbol" command). The current document is replaced in the
// component, open tabs in their stash, the rest on disk; every touched
// file is written. NOTE: textual (not semantic) rename: occurrences in
// comments and strings are replaced too.
ied_rename :: proc(ed: ^ImGuiEditor, old_name, new_name: string) {
	if old_name == "" || new_name == "" || old_name == new_name do return
	if ied_is_keyword(old_name) {
		ed.status = fmt.bprintf(ed.status_buf[:], tr("refusing to rename keyword %s"), old_name)
		return
	}
	total := 0
	files_changed := 0
	for f, i in ed.files {
		text := ""
		if i == ed.current {
			text = string(ite_get_text(ed.handle))
		} else if doc, ok := ied_open_doc(ed, i); ok && doc.loaded {
			text = doc.text
		} else {
			data, err := os.read_entire_file(ied_file_path(ed, i), context.temp_allocator)
			if err != nil do continue
			text = string(data)
		}
		new_text, count := text_replace_word(text, old_name, new_name)
		if count == 0 do continue
		total += count
		files_changed += 1
		if i == ed.current {
			ite_set_text(ed.handle, strings.clone_to_cstring(new_text, context.temp_allocator))
			// The file write below matches the component content: not dirty.
			ed.saved_undo = ite_get_undo_index(ed.handle)
			ed.lsp_dirty = true
		} else if doc, ok := ied_open_doc(ed, i); ok {
			delete(doc.text)
			doc.text = strings.clone(new_text)
			doc.loaded = true
			doc.dirty = false // written below
		}
		if os.write_entire_file(ied_file_path(ed, i), transmute([]u8)new_text) != nil {
			ed.status = fmt.bprintf(ed.status_buf[:], tr("ERROR writing %s"), ied_file_path(ed, i))
			return
		}
	}
	ed.status = fmt.bprintf(ed.status_buf[:],
		tr("renamed %s → %s: %d occurrence(s) in %d file(s)"),
		old_name,
		new_name,
		total,
		files_changed,
	)
}

// Pushes a position onto the navigation history (dedup against the last
// entry; keeps the newest 32).
ied_nav_push :: proc(ed: ^ImGuiEditor, pos: NavPos) {
	if n := len(ed.nav_history); n > 0 && ed.nav_history[n - 1] == pos do return
	append(&ed.nav_history, pos)
	if len(ed.nav_history) > 32 {
		ordered_remove(&ed.nav_history, 0)
	}
}

ied_nav_cursor :: proc(ed: ^ImGuiEditor) -> NavPos {
	return NavPos {
		file = ed.current,
		line = int(ite_get_cursor_line(ed.handle)),
		col  = int(ite_get_cursor_col(ed.handle)),
	}
}

// Option+'-': jump back to the previous cursor position (file included).
ied_nav_back :: proc(ed: ^ImGuiEditor) {
	if len(ed.nav_history) == 0 {
		ed.status = fmt.bprintf(ed.status_buf[:], "%s", tr("no previous position"))
		return
	}
	pos := pop(&ed.nav_history)
	if pos.file >= 0 && pos.file != ed.current {
		ied_load(ed, pos.file)
	}
	ite_set_cursor_pos(ed.handle, c.size_t(pos.line), c.size_t(pos.col))
	// The jump is the new snapshot: don't re-record it as a "big move".
	ed.nav_snapshot = NavPos{file = ed.current, line = pos.line, col = pos.col}
	ed.nav_valid = true
	ed.status = fmt.bprintf(ed.status_buf[:], tr("back to %s:%d:%d"), ed.files[ed.current], pos.line + 1, pos.col + 1)
}

// Per-frame cursor tracking: moves larger than 8 lines (or across files)
// push the previous position onto the history; small moves just update
// the snapshot silently.
ied_nav_tick :: proc(ed: ^ImGuiEditor) {
	if ed.current < 0 {
		ed.nav_valid = false
		return
	}
	pos := ied_nav_cursor(ed)
	if !ed.nav_valid {
		ed.nav_snapshot = pos
		ed.nav_valid = true
		return
	}
	if pos.file != ed.nav_snapshot.file || abs(pos.line - ed.nav_snapshot.line) > 8 {
		ied_nav_push(ed, ed.nav_snapshot)
	}
	ed.nav_snapshot = pos
}

// Jump to the definition of word (current file, then the other shaders).
ied_goto_definition :: proc(ed: ^ImGuiEditor, word: string) {
	// Record the origin so Option+'-' returns here.
	if ed.current >= 0 {
		ied_nav_push(ed, ied_nav_cursor(ed))
	}
	if line, ok := ied_find_definition(string(ite_get_text(ed.handle)), word); ok {
		ite_goto_line(ed.handle, c.size_t(line))
		ed.status = fmt.bprintf(ed.status_buf[:], tr("%s: definition in %s.slang:%d"), word, ed.files[ed.current], line + 1)
		return
	}
	for f, i in ed.files {
		if i == ed.current do continue
		data, err := os.read_entire_file(ied_file_path(ed, i), context.allocator)
		if err != nil do continue
		if line, ok := ied_find_definition(string(data), word); ok {
			ied_load(ed, i)
			ite_goto_line(ed.handle, c.size_t(line))
			ed.status = fmt.bprintf(ed.status_buf[:], tr("%s: definition in %s.slang:%d"), word, f, line + 1)
			return
		}
	}
	ed.status = fmt.bprintf(ed.status_buf[:], tr("%s: no definition found"), word)
}

ied_request_goto_word :: proc(ed: ^ImGuiEditor, word: string) {
	if word == "" do return
	delete(ed.goto_word)
	ed.goto_word = strings.clone(word)
	ed.goto_pending = true
}

// Per-frame non-UI work: self-test driver, deferred goto-definition, the
// context-menu goto channel, the debounced LSP sync, and the diagnostics
// push. Runs regardless of sidebar mode so diagnostics keep flowing.
ied_tick :: proc(ed: ^ImGuiEditor) {
	// Self-test: exercise the deferred goto mechanism without mouse input.
	if ied_selftest {
		ied_selftest_frame += 1
		switch ied_selftest_frame {
		case 30:
			// Cross-file: hash21 lives in common.slang, used by scenes.
			if ed.current >= 0 {
				ied_request_goto_word(ed, "hash21")
			}
		case 45:
			line := ite_get_cursor_line(ed.handle)
			file := ed.current >= 0 ? ed.files[ed.current] : "?"
			// Expected: file switched to "common" at hash21's definition line.
			text := string(ite_get_text(ed.handle))
			want, found := ied_find_definition(text, "hash21")
			ok := file == "common" && found && int(line) == want
			log.infof(
				"[ied-test] cross-file goto: %s.slang line %d (want common %d) %s",
				file,
				line,
				want,
				ok ? "PASS" : "FAIL",
			)
		case 47:
			// Call-site resolution: words used at call sites must resolve
			// cross-file (goto-definition and hover docs share this path).
			words := [?]string{"fbm", "scene_uv", "appleDistances", "sdSegment", "is_outside", "frag_coord"}
			for w in words {
				_, _, found := ied_lookup_symbol(ed, w)
				log.infof("[ied-test] lookup %s: %s", w, found ? "OK" : "MISS")
			}
			// Doc extraction: frag_coord carries a //-comment above it.
			sig, doc, found := ied_lookup_symbol(ed, "frag_coord")
			ok := found && strings.contains(sig, "frag_coord") && strings.contains(doc, "y up")
			log.infof("[ied-test] hover docs: sig=%q doc=%q %s", sig, doc, ok ? "PASS" : "FAIL")
			// Builtin docs resolve without any user definition; a project
			// symbol still wins over the builtin table (clamp vs scene_uv).
			bsig, bdoc, bfound := ied_lookup_symbol(ed, "clamp")
			bok := bfound && strings.contains(bsig, "clamp") && strings.contains(bdoc, "minVal")
			log.infof("[ied-test] builtin docs (clamp): %s", bok ? "PASS" : "FAIL")
		case 50:
			// Rename helper: whole-word replace respects identifier
			// boundaries (afbm/fbm2 untouched, comment + decl replaced).
			src := "fbm(x) + afbm + fbm2(y) + fbm( z ); // fbm\nfloat fbm = 1.0;"
			out, n := text_replace_word(src, "fbm", "noise_fbm")
			ok := n == 4 &&
				strings.contains(out, "noise_fbm(x)") &&
				strings.contains(out, "noise_fbm( z )") &&
				strings.contains(out, "float noise_fbm = 1.0") &&
				strings.contains(out, "afbm") &&
				strings.contains(out, "fbm2(y)") &&
				!strings.contains(out, "noise_fbm2")
			log.infof("[ied-test] rename replace: %d replacements %s", n, ok ? "PASS" : "FAIL")
			if !ok do log.infof("[ied-test]   got: %s", out)
		case 70:
			// Glass mode visual check: same call path as the toolbar button.
			ed.bg_transparent = true
			ite_set_glass(ed.handle, true, ed.glass_alpha)
			log.info("[ied-test] glass enabled")
		case 80:
			// Theme machinery check: monokai on screen for the screenshot.
			ed.bg_transparent = false
			ite_set_glass(ed.handle, false, ed.glass_alpha)
			ed.theme = .MONOKAI
			ied_apply_theme(ed)
			log.info("[ied-test] monokai applied")
		case 90:
			// LSP chain check: completion straight from slangd for a known
			// prefix in common.slang (hash21 lives at line 29).
			if ied_lsp != nil {
				data, _ := os.read_entire_file("src/shaders/common.slang", context.temp_allocator)
				items := lsp_complete(ied_lsp, "file:///tmp/common.slang", string(data), 100, 4)
				log.infof("[ied-test] lsp completions: %d items", len(items))
				for item, i in items {
					if i >= 5 do break
					log.infof("[ied-test]   %s (%s)", item.label, item.detail)
				}
			} else {
				log.info("[ied-test] lsp unavailable")
			}
		case 95:
			// Member completion: right after "Uniforms." slangd must offer
			// the SceneUniforms fields (struct member access).
			if ied_lsp != nil {
				data, _ := os.read_entire_file("src/shaders/scenes/apple/apple.slang", context.temp_allocator)
				text := string(data)
				line, col := -1, 0
				if idx := strings.index(text, "Uniforms.iResolution"); idx >= 0 {
					prefix := text[:idx + len("Uniforms.")]
					line = strings.count(prefix, "\n")
					col = len(prefix)
					if nl := strings.last_index(prefix, "\n"); nl >= 0 {
						col = len(prefix) - nl - 1
					}
				}
				// Real URI: imports ("../../common") must resolve for
				// slangd to know SceneUniforms' members.
				cwd, _ := os.get_working_directory(context.temp_allocator)
				uri := fmt.tprintf("file://%s/src/shaders/scenes/apple/apple.slang", cwd)
				items := lsp_complete(ied_lsp, uri, text, line, col)
				has_field := false
				for item in items {
					if item.label == "iTime" || item.label == "iFbm" {
						has_field = true
						break
					}
				}
				log.infof(
					"[ied-test] member completion after '.': %d items %s",
					len(items),
					has_field ? "PASS" : "FAIL",
				)
				for item, i in items {
					if i >= 5 do break
					log.infof("[ied-test]   %s (%s)", item.label, item.detail)
				}
			}
		case 100:
			// Live diagnostics check: break the DOCUMENT (not the file,
			// nothing is saved) and expect slangd to flag it. The goto test
			// above left the editor on common.slang, so reload apple first.
			if ied_lsp != nil {
				ied_load_named(ed, ied_scene_rel(ed, "apple"))
				text := string(ite_get_text(ed.handle))
				broken, found := strings.replace(text, "float3 bg = paper_texture;", "float3 bg = paper_texture", 1, context.temp_allocator)
				if found {
					ite_set_text(ed.handle, strings.clone_to_cstring(broken, context.temp_allocator))
					// Programmatic SetText may not fire the change callback;
					// force the dirty flag the way typing would.
					ed.lsp_dirty = true
					log.infof("[ied-test] document broken, dirty=%v", ed.lsp_dirty)
				} else {
					log.info("[ied-test] needle not found in document")
				}
			}
		case 130:
			if ied_lsp != nil {
				log.infof(
					"[ied-test] frame 130: dirty=%v diag_version=%d diag_files=%d",
					ed.lsp_dirty,
					ied_lsp.diag_version,
					len(ied_lsp.diagnostics),
				)
			}
		case 150:
			// Hover docs visual check: force the hovered word so the
			// signature + doc tooltip renders (screenshot target).
			ied_debug_hover_word = "frag_coord"
		case 155:
			// Shortcuts tab visual check (screenshot target).
			emit(SetMode(.SHORTCUTS))
		case 160:
			// Mobile theater visual check (screenshot target).
			emit(ToggleMobile{})
		case 400:
			if ied_lsp != nil {
				diags, has := ied_lsp.diagnostics[ied_scene_rel(ed, "apple")]
				log.infof(
					"[ied-test] live diagnostics: %d for scenes/apple %s (diag_version=%d, files=%d)",
					has ? len(diags) : 0,
					has && len(diags) > 0 ? "PASS" : "FAIL",
					ied_lsp.diag_version,
					len(ied_lsp.diagnostics),
				)
				for d, i in diags {
					if i >= 3 do break
					log.infof("[ied-test]   line %d: %s", d.line + 1, d.msg)
				}
			}
		case 420:
			restored := ied_restore_last_good(ed)
			matches := false
			if restored && ed.current_open >= 0 {
				doc := &ed.open_docs[ed.current_open]
				matches = string(ite_get_text(ed.handle)) == doc.last_good
			}
			log.infof("[ied-test] restore last compiled: %s", restored && matches ? "PASS" : "FAIL")
		}
	}

	// Deferred goto-definition (recorded last frame by Cmd+click or the
	// context menu).
	if ed.goto_pending {
		ed.goto_pending = false
		if ied_debug_clicks do log.debugf("[ied] executing deferred goto: %q", ed.goto_word)
		ied_goto_definition(ed, ed.goto_word)
		delete(ed.goto_word)
		ed.goto_word = ""
	}

	// Context-menu "Go to definition" and "Rename symbol" requests arrive
	// through the wrapper.
	{
		buf: [128]u8
		if ite_take_goto_word(ed.handle, cstring(&buf[0]), len(buf)) {
			ied_request_goto_word(ed, string(cstring(&buf[0])))
		}
		if ite_take_rename_word(ed.handle, cstring(&buf[0]), len(buf)) {
			delete(ed.rename_word)
			ed.rename_word = strings.clone(string(cstring(&buf[0])))
			ed.rename_open = true
		}
	}

	// Navigation history: track cursor moves worth returning to.
	ied_nav_tick(ed)

	// Live LSP sync: debounce text changes (~300ms) into didChange;
	// publishDiagnostics arrive via the drain over the next frames.
	if ied_lsp != nil && ed.current >= 0 {
		if ed.lsp_dirty {
			ed.lsp_change_frames += 1
			if ed.lsp_change_frames >= 18 {
				lsp_sync(ied_lsp, ied_current_uri(ed), string(ite_get_text(ed.handle)))
				ed.lsp_dirty = false
				ed.lsp_change_frames = 0
			}
		}
		lsp_drain(ied_lsp)
	}

	// Push diagnostics (goose-build errors on save + live slangd diagnostics)
	if ed.build_success_version != build_success_version {
		ed.build_success_version = build_success_version
		ied_capture_last_good(ed)
	}
	// when either set changes or the current file changes. build_errors is
	// written by the scene build worker: hold its mutex while reading.
	lsp_diag_version := ied_lsp != nil ? ied_lsp.diag_version : 0
	sync.mutex_lock(&scene_build_mu)
	if ed.err_version != build_errors_version ||
	   ed.err_file != ed.current ||
	   ed.lsp_diag_version != lsp_diag_version {
		ed.err_version = build_errors_version
		ed.err_file = ed.current
		ed.lsp_diag_version = lsp_diag_version
		ite_clear_diagnostics(ed.handle)
		if ed.current >= 0 {
			rel := ed.files[ed.current]
			for be in build_errors {
				if be.file != rel do continue
				msg := strings.clone_to_cstring(be.msg, context.temp_allocator)
				line := c.size_t(max(0, be.line - 1))
				ite_add_squiggle(ed.handle, line, c.size_t(max(0, be.col - 1)), msg)
				ite_add_error_marker(ed.handle, line, msg)
			}
			if ied_lsp != nil {
				if diags, has := ied_lsp.diagnostics[rel]; has {
					for d in diags {
						end_line := d.end_line
						if end_line == 0 do end_line = d.line
						col_end := d.col_end
						if col_end <= d.col_start do col_end = d.col_start + 1
						msg := strings.clone_to_cstring(d.msg, context.temp_allocator)
						ite_add_squiggle_range(
							ed.handle,
							c.size_t(max(0, d.line)),
							c.size_t(max(0, d.col_start)),
							c.size_t(max(0, end_line)),
							c.size_t(max(0, col_end)),
							msg,
						)
						ite_add_error_marker(ed.handle, c.size_t(max(0, d.line)), msg)
					}
				}
			}
		}
	}
	sync.mutex_unlock(&scene_build_mu)
}

// Editor panel content: toolbar, document tabs, the text component.
// Renders into the caller's window (the sidebar's EDITOR mode panel).
ied_panel :: proc(ed: ^ImGuiEditor) {
	io := im.GetIO()

	// Ice scroll: the wheel feeds a velocity that glides with exponential
	// friction instead of ImGui's hard line-step jumps. Horizontal stays
	// direct.
	if im.IsWindowHovered({.ChildWindows}) && io.MouseWheel != 0 {
		ed.scroll_vel += io.MouseWheel * 230
		io.MouseWheel = 0
	}
	if ed.scroll_vel != 0 {
		y := im.GetScrollY()
		im.SetScrollY(y - ed.scroll_vel * io.DeltaTime)
		ed.scroll_vel *= math.exp(-9 * io.DeltaTime)
		if abs(ed.scroll_vel) < 2 do ed.scroll_vel = 0
	}

	// No toolbar: saving lives in the title bar's floppy button (and
	// Cmd+S), browsing in the FILES sidebar mode, and appearance knobs in
	// the strip's gear menu (ui_activity_strip). No status row either:
	// the tabs sit at the top.
	if ied_has_current_build_error(ed) && ed.current_open >= 0 {
		doc := &ed.open_docs[ed.current_open]
		if doc.last_good != "" {
			im.TextColored({0.95, 0.45, 0.30, 1}, "%s", strings_to_c(tr("build failed")))
			im.SameLine()
			if im.Button(trc("restore last compiled")) {
				_ = ied_restore_last_good(ed)
			}
		}
	}

	// Tabs: one per open document, a single box holding the title and its
	// close × (right zone). Click on the title area switches (preserving
	// unsaved edits), click on the × zone closes. The visible tab shows
	// the component's live dirty state, the others their stashed flag.
	dl := im.GetWindowDrawList()
	live_undo := ite_get_undo_index(ed.handle)
	for doc, i in ed.open_docs {
		im.PushIDInt(i32(i))
		tab_dirty := doc.dirty || (i == ed.current_open && live_undo != ed.saved_undo)
		base := ed.files[doc.file]
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		label := fmt.ctprintf("%s%s", tab_dirty ? "• " : "", base)
		pad := f32(8)
		close_w := f32(18) // the × zone inside the tab's right edge
		h := f32(22)
		w := pad * 2 + im.CalcTextSize(label).x + close_w
		pos := im.GetCursorScreenPos()
		clicked := im.InvisibleButton("##tab", {w, h})
		hovered := im.IsItemHovered()
		in_close := hovered && im.GetMousePos().x >= pos.x + w - close_w

		box_col: im.Vec4 = {1, 1, 1, 0.04}
		if hovered do box_col = {1, 1, 1, 0.07}
		if i == ed.current_open do box_col = {0.91, 0.66, 0.34, 0.22}
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, im.GetColorU32Vec4(box_col), 5)

		text_y := pos.y + (h - im.GetTextLineHeight()) / 2
		im.DrawList_AddText(dl, {pos.x + pad, text_y}, im.GetColorU32(.Text, 1.0), label)
		x_col: im.Vec4 = in_close ? {0.95, 0.45, 0.45, 1} : {0.55, 0.57, 0.62, 1}
		im.DrawList_AddText(dl, {pos.x + w - close_w + 5, text_y}, im.GetColorU32Vec4(x_col), "×")

		if clicked {
			if in_close {
				ied_close(ed, i)
				im.PopID()
				break // open_docs shrank; indices are stale
			}
			ied_switch(ed, i)
		}
		im.PopID()
		if i < len(ed.open_docs) - 1 {
			im.SameLine()
		}
	}

	if im.IsMouseClicked(.Left) && ied_debug_clicks {
		log.infof(
			"[ied] click: super=%v gui=%v pos=(%.0f,%.0f) over_text=%v",
			io.KeySuper,
			ied_gui_held,
			io.MousePos.x,
			io.MousePos.y,
			ite_is_mouse_over_text(ed.handle, io.MousePos.x, io.MousePos.y),
		)
	}

	// Cmd+click: record the word; the jump runs next frame.
	if (io.KeySuper || ied_gui_held) && im.IsMouseClicked(.Left) {
		if ite_is_mouse_over_text(ed.handle, io.MousePos.x, io.MousePos.y) {
			buf: [128]u8
			n := ite_get_word_at_mouse(ed.handle, io.MousePos.x, io.MousePos.y, cstring(&buf[0]), len(buf))
			if ied_debug_clicks do log.debugf("[ied] word at click: %q (n=%d)", string(buf[:min(int(n), 127)]), n)
			if n > 0 {
				ied_request_goto_word(ed, string(buf[:min(int(n), len(buf) - 1)]))
			}
		}
	}

	// Cmd+Shift+D: duplicate the current line.
	if (io.KeySuper || ied_gui_held) && (io.KeyShift || ied_shift_held) && im.IsKeyPressed(.D, false) {
		ite_duplicate_line(ed.handle)
	}

	// Rename popup (context menu's "Rename symbol"): pre-filled with the
	// word, Enter or the button applies the rename across all files.
	if ed.rename_open {
		im.OpenPopup(trc("Rename symbol"))
		ed.rename_open = false
		for i in 0 ..< len(ed.rename_buf) do ed.rename_buf[i] = 0
		copy(ed.rename_buf[:], ed.rename_word)
	}
	if im.BeginPopup(trc("Rename symbol"), {}) {
		im.TextUnformatted(fmt.ctprintf(tr("rename '%s' to:"), ed.rename_word))
		im.SetNextItemWidth(200)
		apply := im.InputText(
			"##new_name",
			cstring(&ed.rename_buf[0]),
			len(ed.rename_buf),
			{.EnterReturnsTrue},
		)
		im.SameLine()
		if im.Button(trc("Rename")) do apply = true
		if apply {
			ied_rename(ed, ed.rename_word, string(cstring(&ed.rename_buf[0])))
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// The code font size is independent of the UI font size
	// (Ui.font_size): push the editor's own size around the text
	// component only.
	if app_font != nil {
		im.PushFontFloat(app_font, ed.font_size)
	}
	// Tab-switch crossfade: a WindowBg overlay over the text area that
	// fades out quickly, so the incoming document appears to fade in.
	if ed.current_open != ed.last_open_tab {
		ed.last_open_tab = ed.current_open
		ed.tab_flash = 0.55
	}
	ed.tab_flash = max(0, ed.tab_flash - io.DeltaTime * 4)

	text_pos := im.GetCursorScreenPos()
	ed.text_pos = {text_pos.x, text_pos.y}
	ed.line_h = im.GetTextLineHeight()
	// Measured advance of the editor font (the guessed 0.6 × line_h ran
	// ~8% wide, landing bursts a few characters right of the caret).
	ed.char_w = im.CalcTextSize("0000000000").x * 0.1
	avail := im.GetContentRegionAvail()
	ite_render(ed.handle, "##ied", avail.x, avail.y)
	if ed.tab_flash > 0 {
		dl := im.GetWindowDrawList()
		im.DrawList_AddRectFilled(
			dl,
			text_pos,
			{text_pos.x + avail.x, text_pos.y + avail.y},
			im.GetColorU32(.WindowBg, ed.tab_flash),
		)
	}
	if app_font != nil {
		im.PopFont()
	}

	// Hover symbol docs: dwell ~0.4 s on a word over the text, then show
	// its signature plus the doc comment above the definition. Once
	// shown, the tooltip pins and stays alive while the mouse is inside
	// it (wheel scrolls long docs); leaving the tooltip closes it.
	{
		m := io.MousePos
		over_tooltip :=
			ed.hover_shown &&
			m.x >= ed.hover_rect[0] && m.x <= ed.hover_rect[2] &&
			m.y >= ed.hover_rect[1] && m.y <= ed.hover_rect[3]
		word := ied_debug_hover_word
		if !over_tooltip && word == "" && !im.IsMouseDown(.Left) &&
		   ite_is_mouse_over_text(ed.handle, m.x, m.y) {
			buf: [128]u8
			n := ite_get_word_at_mouse(ed.handle, m.x, m.y, cstring(&buf[0]), len(buf))
			word = string(buf[:min(int(n), 127)])
		}
		// Grace window: crossing the gap between the word and the pinned
		// tooltip keeps it open; a different word swaps immediately.
		if ed.hover_shown && !over_tooltip && word == "" {
			ed.hover_grace -= io.DeltaTime
		} else {
			ed.hover_grace = 0.35
		}
		different := word != "" && word != ed.hover_word
		gone := word == "" && word != ed.hover_word && ed.hover_grace <= 0
		if !over_tooltip && (different || gone) {
			delete(ed.hover_word)
			ed.hover_word = strings.clone(word)
			ed.hover_dwell = 0
			if ed.hover_sig != "" {
				delete(ed.hover_sig)
				ed.hover_sig = ""
				delete(ed.hover_doc)
				ed.hover_doc = ""
			}
			ed.hover_shown = false
		} else if !over_tooltip && word != "" {
			ed.hover_dwell += 1
			if ed.hover_dwell == 25 {
				sig, doc, found := ied_lookup_symbol(ed, ed.hover_word)
				if found {
					ed.hover_sig = strings.clone(sig)
					ed.hover_doc = strings.clone(doc)
				}
			}
		}
		show := ed.hover_dwell >= 25 && ed.hover_sig != ""
		if show {
			if !ed.hover_shown {
				// Pin beside the cursor on the side with room, like a
				// native tooltip: right/below by default, flipping to
				// left/above near the viewport edges.
				line_h := im.GetTextLineHeightWithSpacing()
				doc_lines := min(strings.count(ed.hover_doc, "\n") + 2, 15)
				w_est := f32(470)
				h_est := f32(doc_lines + 1) * line_h + 22
				px := m.x + 16
				if px + w_est > io.DisplaySize.x - 8 do px = m.x - w_est - 12
				py := m.y + 14
				if py + h_est > io.DisplaySize.y - 8 do py = m.y - h_est - 10
				ed.hover_pin = {
					clamp(px, 8, max(8, io.DisplaySize.x - w_est)),
					clamp(py, TITLEBAR_H + 4, max(TITLEBAR_H + 4, io.DisplaySize.y - 120)),
				}
			}
			im.SetNextWindowPos(ed.hover_pin, .Always)
			// Self-test: the physical mouse may be outside the window (or
			// never moved), so pin the tooltip inside the panel.
			if ied_debug_hover_word != "" {
				wp := im.GetWindowPos()
				im.SetNextWindowPos({wp.x - 40, wp.y + 160}, .Always)
			}
			if im.BeginTooltip() {
				// Cap the tooltip: unwrapped docs used to grow right
				// without limit, and tall doc blocks had no scroll.
				im.PushTextWrapPos(im.GetCursorPosX() + 440)
				im.TextColored({0.62, 0.76, 0.95, 1}, "%s", strings_to_c(ed.hover_sig))
				if ed.hover_doc != "" {
					im.Separator()
					line_h := im.GetTextLineHeightWithSpacing()
					doc_h := min(f32(strings.count(ed.hover_doc, "\n") + 1) * line_h, 14 * line_h)
					if im.BeginChild("##hoverdoc", {440, doc_h}, {}) {
						im.TextWrapped(strings_to_c(ed.hover_doc))
					}
					im.EndChild()
				}
				wp := im.GetWindowPos()
				ws := im.GetWindowSize()
				ed.hover_rect = {wp.x - 6, wp.y - 6, wp.x + ws.x + 6, wp.y + ws.y + 6}
				im.PopTextWrapPos()
				im.EndTooltip()
			}
		}
		ed.hover_shown = show
	}
}

// The editor's floating window (F1 toggles); the panel content itself is
// ied_panel. Kept separate from the sidebar by design. Open/close springs
// the window in from the right edge (fx).
ied_frame :: proc(ed: ^ImGuiEditor, fx: ^Fx) {
	io := im.GetIO()
	anim_step(&ed.open_anim, ed.open ? 1 : 0, io.DeltaTime, fx)
	if ed.open_anim.value < 0.02 && !ed.open do return
	// Wide enough for the toolbar row (save all … theme) on small windows.
	win_w := max(io.DisplaySize.x * 0.45, 430)
	xoff := (1 - ed.open_anim.value) * 60
	dock_pos := im.Vec2{io.DisplaySize.x - win_w - 8 + xoff, TITLEBAR_H + 8}
	dock_size := im.Vec2{win_w, io.DisplaySize.y - TITLEBAR_H - 16}
	if mobile_theater {
		// Mobile theater (F4): editor docked to the bottom half of the
		// portrait window; the scene plays in the top half.
		dock_pos = {8, io.DisplaySize.y * 0.55}
		dock_size = {io.DisplaySize.x - 16, io.DisplaySize.y * 0.45 - 8}
	}
	// Docked until the user drags the title bar away; then ImGui owns
	// the position and size (still saved to imgui.ini). Forcing every
	// frame would make the drag impossible, so the dock position is
	// forced only during the open/close spring or when the window size
	// changes; in between, a position mismatch below detects the drag.
	display := [2]f32{io.DisplaySize.x, io.DisplaySize.y}
	force :=
		mobile_theater ||
		ed.open_anim.value < 1 ||
		(!ed.moved && display != ed.dock_display)
	if force {
		im.SetNextWindowPos(dock_pos, .Always)
		im.SetNextWindowSize(dock_size, .Always)
		if !ed.moved do ed.dock_display = display
	}
	// Deterministic startup: the editor always opens expanded; what the
	// user does after that is theirs (demo framing on every launch).
	im.SetNextWindowCollapsed(false, .Once)
	im.SetNextWindowBgAlpha((ed.bg_transparent ? ed.glass_alpha : 1.0) * ed.open_anim.value)
	// The ##ed2 suffix sidesteps a poisoned imgui.ini section saved with
	// an off-screen position when the app exits minimized (DisplaySize 0
	// makes the computed x negative); the fresh section starts clean.
	if !im.Begin(fmt.ctprintf("%s##ed2", tr("Shader editor")), &ed.open, {}) {
		im.End()
		return
	}
	// A position different from the dock means the user dragged the
	// title bar: hand the window over to ImGui from here on.
	if !ed.moved && !force && im.GetWindowPos() != dock_pos {
		ed.moved = true
	}
	// The window frame animates via open_anim; the content must fade too:
	// style alpha for the ImGui chrome (tabs), palette fade for the text
	// component (its raw draw-list colors ignore style alpha).
	im.PushStyleVar(.Alpha, ed.open_anim.value)
	ite_set_fade(ed.handle, ed.open_anim.value)
	ied_panel(ed)
	im.PopStyleVar()
	im.End()
}
