// Integrated ImGui shader editor (Dear ImGui + goossens' ImGuiColorTextEdit
// via the ite C wrapper): a floating window toggled with F1, separate from
// the sidebar. Its tabs follow the active scene: the scene file plus every
// module it transitively imports. Cmd+S is the application-wide save
// (every dirty tab — shader files are the app's only persistent state);
// the scene watcher rebuilds on write. Cmd+click jumps to the definition
// (current file first, then the other .slang files, e.g. common.slang).
package main

import im "../vendor/odin-imgui"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
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
	ite_duplicate_line :: proc(ed: rawptr) ---
	ite_set_glass :: proc(ed: rawptr, on: bool, alpha: f32) ---
	ite_set_palette_u32 :: proc(ed: rawptr, colors: [^]u32, count: c.size_t) ---
	ite_use_dark_palette :: proc(ed: rawptr) ---
	ite_use_light_palette :: proc(ed: rawptr) ---
	ite_clear_diagnostics :: proc(ed: rawptr) ---
	ite_add_squiggle :: proc(ed: rawptr, line: c.size_t, col: c.size_t, msg: cstring) ---
	ite_add_squiggle_range :: proc(ed: rawptr, sl: c.size_t, sc: c.size_t, el: c.size_t, ec: c.size_t, msg: cstring) ---
	ite_add_error_marker :: proc(ed: rawptr, line: c.size_t, msg: cstring) ---
	ite_install_context_menu :: proc(ed: rawptr) ---
	ite_take_goto_word :: proc(ed: rawptr, buf: cstring, cap: c.size_t) -> bool ---
	ite_enable_completion :: proc(ed: rawptr, fn: IteCompletionFn, user: rawptr) ---
	ite_set_change_callback :: proc(ed: rawptr, fn: IteChangeFn, user: rawptr) ---
}

IteCompletionFn :: #type proc "c" (search_term: cstring, line: c.size_t, col: c.size_t, user: rawptr, buf: [^]u8, cap: c.size_t) -> c.int
IteChangeFn :: #type proc "c" (user: rawptr)

// Debug/self-test knobs (set from os.args in main).
ied_debug_clicks: bool
ied_selftest:     bool
ied_selftest_frame: int
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
}

ImGuiEditor :: struct {
	handle:      rawptr,
	open:        bool, // floating window visible (F1 toggles)
	files:       [dynamic]string, // relative to SHADER_DIR, no .slang ("apple" -> "scenes/apple")
	file_names:  [dynamic]cstring,
	current:     int,        // index into files of the visible document (-1: none)
	open_docs:   [dynamic]OpenDoc,
	current_open: int,       // index into open_docs of the visible document (-1: none)
	status:      string,
	saved_undo:  c.size_t,
	font_size:   f32, // code font in points; the UI font is Ui.font_size
	last_scene:  string,
	bg_transparent: bool,
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
}

// Component change callback: marks the document as needing an LSP sync.
ied_on_change :: proc "c" (user: rawptr) {
	ed := (^ImGuiEditor)(user)
	ed.lsp_dirty = true
	ed.lsp_change_frames = 0
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

// The slangd instance backing autocomplete (nil when unavailable — the
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
	ed.open = true

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
	fmt.printfln("[imgui-editor] %d shaders under %s", len(ed.files), SHADER_DIR)
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
		append(&ed.file_names, strings.clone_to_cstring(name))
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
// stash (or disk on first open). Does NOT stash the outgoing document — use
// ied_switch for user-driven tab switches.
ied_show :: proc(ed: ^ImGuiEditor, open_idx: int) {
	doc := &ed.open_docs[open_idx]
	if !doc.loaded {
		data, err := os.read_entire_file(ied_file_path(ed, doc.file), context.allocator)
		if err != nil {
			ed.status = fmt.tprintf("could not read %s", ied_file_path(ed, doc.file))
			return
		}
		doc.text = strings.clone(string(data))
		doc.loaded = true
	}
	ed.current_open = open_idx
	ed.current = doc.file
	ite_set_text(ed.handle, strings.clone_to_cstring(doc.text, context.temp_allocator))
	ed.saved_undo = ite_get_undo_index(ed.handle)
	ed.status = fmt.tprintf("editing %s.slang", ed.files[ed.current])
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
// moved to per-scene folders, scenes/<title>/<title>.slang — matched by
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
	ed.last_scene = scene_name
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
			ed.status = fmt.tprintf("ERROR writing %s", path)
			continue
		}
		doc.dirty = false
		saved += 1
	}
	if ed.current_open >= 0 {
		ed.saved_undo = ite_get_undo_index(ed.handle)
	}
	h, m, s := time.clock(time.now())
	if saved > 0 {
		ed.status = fmt.tprintf("saved %d file(s) at %02d:%02d:%02d", saved, h, m, s)
	} else {
		ed.status = "nothing to save"
	}
	return saved
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

// Jump to the definition of word (current file, then the other shaders).
ied_goto_definition :: proc(ed: ^ImGuiEditor, word: string) {
	if line, ok := ied_find_definition(string(ite_get_text(ed.handle)), word); ok {
		ite_goto_line(ed.handle, c.size_t(line))
		ed.status = fmt.tprintf("%s: definition in %s.slang:%d", word, ed.files[ed.current], line + 1)
		return
	}
	for f, i in ed.files {
		if i == ed.current do continue
		data, err := os.read_entire_file(ied_file_path(ed, i), context.allocator)
		if err != nil do continue
		if line, ok := ied_find_definition(string(data), word); ok {
			ied_load(ed, i)
			ite_goto_line(ed.handle, c.size_t(line))
			ed.status = fmt.tprintf("%s: definition in %s.slang:%d", word, f, line + 1)
			return
		}
	}
	ed.status = fmt.tprintf("%s: no definition found", word)
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
			fmt.printfln(
				"[ied-test] cross-file goto: %s.slang line %d (want common %d) %s",
				file,
				line,
				want,
				ok ? "PASS" : "FAIL",
			)
		case 70:
			// Glass mode visual check: same call path as the toolbar button.
			ed.bg_transparent = true
			ite_set_glass(ed.handle, true, 0.55)
			fmt.println("[ied-test] glass enabled")
		case 80:
			// Theme machinery check: monokai on screen for the screenshot.
			ed.bg_transparent = false
			ite_set_glass(ed.handle, false, 0.55)
			ed.theme = .MONOKAI
			ied_apply_theme(ed)
			fmt.println("[ied-test] monokai applied")
		case 90:
			// LSP chain check: completion straight from slangd for a known
			// prefix in common.slang (hash21 lives at line 29).
			if ied_lsp != nil {
				data, _ := os.read_entire_file("src/shaders/common.slang", context.temp_allocator)
				items := lsp_complete(ied_lsp, "file:///tmp/common.slang", string(data), 100, 4)
				fmt.printfln("[ied-test] lsp completions: %d items", len(items))
				for item, i in items {
					if i >= 5 do break
					fmt.printfln("[ied-test]   %s (%s)", item.label, item.detail)
				}
			} else {
				fmt.println("[ied-test] lsp unavailable")
			}
		case 100:
			// Live diagnostics check: break the DOCUMENT (not the file —
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
					fmt.printfln("[ied-test] document broken, dirty=%v", ed.lsp_dirty)
				} else {
					fmt.println("[ied-test] needle not found in document")
				}
			}
		case 130:
			if ied_lsp != nil {
				fmt.printfln(
					"[ied-test] frame 130: dirty=%v diag_version=%d diag_files=%d",
					ed.lsp_dirty,
					ied_lsp.diag_version,
					len(ied_lsp.diagnostics),
				)
			}
		case 400:
			if ied_lsp != nil {
				diags, has := ied_lsp.diagnostics[ied_scene_rel(ed, "apple")]
				fmt.printfln(
					"[ied-test] live diagnostics: %d for scenes/apple %s (diag_version=%d, files=%d)",
					has ? len(diags) : 0,
					has && len(diags) > 0 ? "PASS" : "FAIL",
					ied_lsp.diag_version,
					len(ied_lsp.diagnostics),
				)
				for d, i in diags {
					if i >= 3 do break
					fmt.printfln("[ied-test]   line %d: %s", d.line + 1, d.msg)
				}
			}
		}
	}

	// Deferred goto-definition (recorded last frame by Cmd+click or the
	// context menu).
	if ed.goto_pending {
		ed.goto_pending = false
		if ied_debug_clicks do fmt.printfln("[ied] executing deferred goto: %q", ed.goto_word)
		ied_goto_definition(ed, ed.goto_word)
		delete(ed.goto_word)
		ed.goto_word = ""
	}

	// Context-menu "Go to definition" requests arrive through the wrapper.
	{
		buf: [128]u8
		if ite_take_goto_word(ed.handle, cstring(&buf[0]), len(buf)) {
			ied_request_goto_word(ed, string(cstring(&buf[0])))
		}
	}

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
	// when either set changes or the current file changes.
	lsp_diag_version := ied_lsp != nil ? ied_lsp.diag_version : 0
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
}

// Editor panel content: toolbar, document tabs, the text component.
// Renders into the caller's window (the sidebar's EDITOR mode panel).
ied_panel :: proc(ed: ^ImGuiEditor) {
	io := im.GetIO()

	// No toolbar: saving lives in the title bar's floppy button (and
	// Cmd+S), browsing in the FILES sidebar mode, and appearance knobs in
	// the strip's gear menu (ui_activity_strip).

	// Status feedback (save results, goto messages) on its own dim row:
	// inline after the theme combo it clipped at the panel edge.
	if ed.status != "" {
		im.TextDisabled("%s", strings_to_c(ed.status))
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
		fmt.printfln(
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
			if ied_debug_clicks do fmt.printfln("[ied] word at click: %q (n=%d)", string(buf[:min(int(n), 127)]), n)
			if n > 0 {
				ied_request_goto_word(ed, string(buf[:min(int(n), len(buf) - 1)]))
			}
		}
	}

	// Cmd+Shift+D: duplicate the current line.
	if (io.KeySuper || ied_gui_held) && (io.KeyShift || ied_shift_held) && im.IsKeyPressed(.D, false) {
		ite_duplicate_line(ed.handle)
	}

	// The code font size is independent of the UI font size
	// (Ui.font_size): push the editor's own size around the text
	// component only.
	if app_font != nil {
		im.PushFontFloat(app_font, ed.font_size)
	}
	avail := im.GetContentRegionAvail()
	ite_render(ed.handle, "##ied", avail.x, avail.y)
	if app_font != nil {
		im.PopFont()
	}
}

// The editor's floating window (F1 toggles); the panel content itself is
// ied_panel. Kept separate from the sidebar by design.
ied_frame :: proc(ed: ^ImGuiEditor) {
	if !ed.open do return
	io := im.GetIO()
	// Wide enough for the toolbar row (save all … theme) on small windows.
	win_w := max(io.DisplaySize.x * 0.45, 430)
	im.SetNextWindowPos({io.DisplaySize.x - win_w - 8, TITLEBAR_H + 8}, .FirstUseEver)
	im.SetNextWindowSize({win_w, io.DisplaySize.y - TITLEBAR_H - 16}, .FirstUseEver)
	im.SetNextWindowBgAlpha(ed.bg_transparent ? 0.55 : 1.0)
	if !im.Begin("Shader editor (F1)", &ed.open, {}) {
		im.End()
		return
	}
	ied_panel(ed)
	im.End()
}
