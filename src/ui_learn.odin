package main

// LEARN mode: markdown-based learning trails. Pages live in
// assets/trails/*.md; "index" is the home page. The renderer is a
// deliberate md-lite: headers, bullets, fenced code blocks, and inline
// links: because the feature that matters is the bridge to practice:
// [label](scene:NAME) loads the scene AND opens the editor on its entry
// file, [label](trail:NAME) navigates between pages.
import im "../vendor/odin-imgui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

LEARN_DIR :: "assets/trails"

learn_page: string // current page base name ("" = not loaded yet)
learn_text: string // owned page content

learn_load :: proc(page: string) {
	path := fmt.tprintf("%s/%s.md", LEARN_DIR, page)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("learn: could not read %s", path)
		return
	}
	delete(learn_text)
	learn_text = strings.clone(string(data))
	delete(learn_page)
	learn_page = strings.clone(page)
}

// Renders one inline segment run: plain text interleaved with
// [label](target) links. Targets are "scene:NAME" (load scene + open
// editor) and "trail:NAME" (navigate). Returns true if a link fired.
learn_render_rich_line :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor, line: string) {
	// Lines without links wrap at the panel width; link lines flow
	// inline (content authors keep those short).
	if strings.index(line, "](") < 0 {
		im.TextWrapped("%s", strings_to_c(line))
		return
	}
	rest := line
	first := true
	link_col := im.Vec4{0.55, 0.75, 0.95, 1}
	for {
		open := strings.index(rest, "[")
		if open < 0 do break
		close := strings.index(rest[open:], "](")
		if close < 0 do break
		close += open
		end := strings.index(rest[close + 2:], ")")
		if end < 0 do break
		end += close + 2
		label := rest[open + 1:close]
		target := rest[close + 2:end]
		// Segment before the link.
		if open > 0 {
			if !first { im.SameLine(0, 0) }
			im.TextUnformatted(strings_to_c(rest[:open]))
			first = false
		}
		if !first { im.SameLine(0, 0) }
		im.TextColored(link_col, "%s", strings_to_c(label))
		if im.IsItemHovered() {
			mn := im.GetItemRectMin()
			mx := im.GetItemRectMax()
			im.DrawList_AddLine(
				im.GetWindowDrawList(),
				{mn.x, mx.y - 1},
				{mx.x, mx.y - 1},
				im.GetColorU32Vec4(link_col),
				1,
			)
			if im.IsMouseClicked(.Left) {
				if strings.has_prefix(target, "scene:") {
					file := strings.trim_prefix(target, "scene:")
					for &s, i in sm.scenes {
						if s.title == file {
							emit(SceneSelected(i))
							// ed.files entries omit the .slang suffix
							// (ied_file_path appends it).
							entry := fmt.tprintf("scenes/%s/%s", file, file)
							ied_load_named(ed, entry)
							ed.open = true
							break
						}
					}
				} else if strings.has_prefix(target, "trail:") {
					learn_load(strings.trim_prefix(target, "trail:"))
					return // the page changed under us; stop rendering it
				}
			}
		}
		first = false
		rest = rest[end + 1:]
	}
	if len(rest) > 0 {
		if !first { im.SameLine(0, 0) }
		im.TextUnformatted(strings_to_c(rest))
	}
}

learn_render_page :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	in_code := false
	code_lines := 0
	for line in strings.split_lines(learn_text, context.temp_allocator) {
		if strings.has_prefix(line, "```") {
			in_code = !in_code
			if in_code do code_lines = 0
			continue
		}
		if in_code {
			// Fenced block: dim text over a subtle strip, indented.
			mn := im.GetCursorScreenPos()
			w := im.GetContentRegionAvail().x
			h := im.GetTextLineHeight()
			im.DrawList_AddRectFilled(
				im.GetWindowDrawList(),
				{mn.x, mn.y},
				{mn.x + w, mn.y + h},
				im.GetColorU32Vec4({1, 1, 1, 0.05}),
			)
			im.TextDisabled("  %s", strings_to_c(line))
			code_lines += 1
			continue
		}
		trimmed := strings.trim_space(line)
		switch {
		case trimmed == "":
			im.Spacing()
		case strings.has_prefix(trimmed, "## "):
			im.Spacing()
			im.TextColored({0.91, 0.66, 0.34, 1}, "%s", strings_to_c(trimmed[3:]))
		case strings.has_prefix(trimmed, "# "):
			im.TextColored({0.95, 0.92, 0.88, 1}, "%s", strings_to_c(trimmed[2:]))
			im.Separator()
			im.Spacing()
		case strings.has_prefix(trimmed, "- "):
			im.Bullet()
			learn_render_rich_line(ui, sm, ed, trimmed[2:])
		case:
			learn_render_rich_line(ui, sm, ed, trimmed)
		}
	}
}

ui_learn_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	if learn_text == "" do learn_load("index")
	im.TextDisabled(trc("learn"))
	if learn_page != "index" {
		// Back to the trail index.
		im.TextColored({0.55, 0.75, 0.95, 1}, "%s", strings_to_c(tr("← all trails")))
		if im.IsItemHovered() && im.IsMouseClicked(.Left) {
			learn_load("index")
			return
		}
		im.Separator()
	}
	learn_render_page(ui, sm, ed)
}
