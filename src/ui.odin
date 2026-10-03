package main

import im "../vendor/odin-imgui"
import "core:fmt"
import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// Controls UI: Dear ImGui is the only UI toolkit in the app (microui was
// retired). The editor panel lives in imgui_editor.odin; this file owns
// the title bar (the borderless window's chrome, with the scene selector),
// the Controls window, the scene's reflected params (a visually separate
// section), and the normalized graph-paper grid drawn behind the windows
// via the background draw list.
//
// Widget map from the old microui build:
//   checkboxes          -> im.Checkbox
//   radio buttons       -> im.RadioButton
//   tree nodes          -> im.CollapsingHeader
//   scene sliders       -> im.SliderFloat
//   scene color params  -> im.ColorEdit3 (was three sliders)
//   grid overlay        -> im.GetBackgroundDrawList lines + text

InteractionMode :: enum {
	AUTOROTATE,
	MOUSE_ROTATE,
}

UiParams :: struct {
	paused:      bool,
	color:       bool,
	view3d:      bool, // false = flat blit, true = 3D heightfield view
	grid:        bool, // graph-paper overlay with labeled axes
	paper:       int,  // index into the paper textures list (assets/)
	skybox:      int,  // index into skybox textures (assets/skybox/), -1 = none
	model_index: int,  // index into the loaded models (assets/models/)
	interaction: InteractionMode,
}

// One-shot export actions requested from the Controls window; main picks
// them up after the frame's compute pass and resets them to .NONE.
ExportRequest :: enum {
	NONE,
	PNG, // current frame, at the current app_time
	GIF, // [gif_start, gif_end] rendered frame by frame + ffmpeg
}

// Sidebar modes (VS Code-style activity bar): each icon docks a different
// tool panel on the left edge. CONTROLS is the classic params window,
// FILES the shader file browser, GRAPH the shader node graph. The code
// editor stays OUT of the sidebar by design: it is a floating window (F1).
SidebarMode :: enum {
	CONTROLS,
	FILES,
	GRAPH,
	EXPORT,
}

Ui :: struct {
	params:         UiParams,
	scene_request:  int,
	export_request: ExportRequest,
	// Points at main's app_time: the controls panel shows it live and
	// edits write through to the running clock.
	time:           ^f32,
	// GIF export window (seconds), editable in the EXPORT panel.
	gif_start:      f32,
	gif_end:        f32,
	// True while the mouse is over a UI window or a widget owns the drag;
	// the shader click (iMouse.z) must ignore those clicks.
	captures_mouse: bool,
	open:           bool, // whole sidebar (SPACE = zen mode hides it)
	mode:           SidebarMode,
	panel_open:     bool, // clicking the active mode's icon collapses the panel
	files_frame:    int,  // frame counter pacing the FILES-mode rescan
	font_size:      f32,  // UI font in points; the code font is ImGuiEditor.font_size
	// Set by the title bar's close button; main breaks the loop on it.
	quit_requested: bool,
	gen_ms:         f32, // average compute texture generation time, fed by main
	// A scene created from a template: selected as soon as the watcher
	// discovers the new file (next frame's rescan).
	pending_scene:  string,
}

ui_init :: proc() -> ^Ui {
	ui := new(Ui)
	ui.params.skybox = -1 // start with no skybox
	ui.scene_request = -1
	ui.open = true
	ui.panel_open = true
	ui.font_size = 16
	ui.gif_end = 5
	return ui
}

// Professional dark theme: tinted neutral layers (bar / panel / frame) so
// scene colors stay true, and one warm amber accent reserved for selection
// and active state. Restrained color strategy — the accent never decorates,
// it marks state. Applied once after the ImGui context exists.
ui_apply_style :: proc() {
	style := im.GetStyle()
	style.WindowPadding = {12, 10}
	style.FramePadding = {10, 5}
	style.ItemSpacing = {10, 8}
	style.ItemInnerSpacing = {8, 6}
	style.IndentSpacing = 18
	style.ScrollbarSize = 12
	style.GrabMinSize = 8
	style.WindowRounding = 8
	style.ChildRounding = 6
	style.FrameRounding = 5
	style.PopupRounding = 6
	style.ScrollbarRounding = 6
	style.GrabRounding = 5
	style.WindowBorderSize = 1
	style.FrameBorderSize = 0

	accent := im.Vec4{0.91, 0.66, 0.34, 1}
	colors := &style.Colors
	colors[im.Col.Text] = {0.87, 0.88, 0.90, 1}
	colors[im.Col.TextDisabled] = {0.46, 0.48, 0.52, 1}
	colors[im.Col.WindowBg] = {0.075, 0.079, 0.094, 0.97}
	colors[im.Col.ChildBg] = {0, 0, 0, 0}
	colors[im.Col.PopupBg] = {0.098, 0.103, 0.122, 0.98}
	colors[im.Col.Border] = {1, 1, 1, 0.09}
	colors[im.Col.BorderShadow] = {0, 0, 0, 0}
	colors[im.Col.FrameBg] = {1, 1, 1, 0.05}
	colors[im.Col.FrameBgHovered] = {1, 1, 1, 0.10}
	colors[im.Col.FrameBgActive] = {1, 1, 1, 0.15}
	colors[im.Col.TitleBg] = {0.075, 0.079, 0.094, 1}
	colors[im.Col.TitleBgActive] = {0.075, 0.079, 0.094, 1}
	colors[im.Col.TitleBgCollapsed] = {0.075, 0.079, 0.094, 1}
	colors[im.Col.MenuBarBg] = {0.102, 0.106, 0.125, 1}
	colors[im.Col.ScrollbarBg] = {0, 0, 0, 0}
	colors[im.Col.ScrollbarGrab] = {1, 1, 1, 0.14}
	colors[im.Col.ScrollbarGrabHovered] = {1, 1, 1, 0.22}
	colors[im.Col.ScrollbarGrabActive] = {1, 1, 1, 0.30}
	colors[im.Col.CheckMark] = accent
	colors[im.Col.SliderGrab] = {1, 1, 1, 0.28}
	colors[im.Col.SliderGrabActive] = accent
	colors[im.Col.Button] = {1, 1, 1, 0.07}
	colors[im.Col.ButtonHovered] = {1, 1, 1, 0.13}
	colors[im.Col.ButtonActive] = {1, 1, 1, 0.18}
	colors[im.Col.Header] = {1, 1, 1, 0.06}
	colors[im.Col.HeaderHovered] = {1, 1, 1, 0.11}
	colors[im.Col.HeaderActive] = {1, 1, 1, 0.16}
	colors[im.Col.Separator] = {1, 1, 1, 0.10}
	colors[im.Col.SeparatorHovered] = accent
	colors[im.Col.SeparatorActive] = accent
	colors[im.Col.ResizeGrip] = {1, 1, 1, 0.10}
	colors[im.Col.ResizeGripHovered] = {1, 1, 1, 0.20}
	colors[im.Col.ResizeGripActive] = {1, 1, 1, 0.28}
	colors[im.Col.TabHovered] = {1, 1, 1, 0.12}
	colors[im.Col.TextSelectedBg] = {0.91, 0.66, 0.34, 0.35}
	colors[im.Col.NavCursor] = accent
}

// ---------------------------------------------------------------------------
// Title bar: the app window is borderless (SDL_WINDOW_BORDERLESS), so this
// bar IS the window chrome — traffic-light controls on the left, the scene
// selector beside them, "+ new", drag space, pause on the right. Empty bar
// space drags the window and edge strips resize it via the SDL hit test in
// main.odin; every interactive widget registers its rect below so the hit
// test leaves clicks on them to ImGui.

TITLEBAR_H :: 38

titlebar_hot_rects: [8][4]f32 // min.x, min.y, max.x, max.y in window coords
titlebar_hot_count: int

titlebar_reset_hot :: proc() {
	titlebar_hot_count = 0
}

titlebar_mark_hot :: proc() {
	if titlebar_hot_count >= len(titlebar_hot_rects) do return
	mn := im.GetItemRectMin()
	mx := im.GetItemRectMax()
	titlebar_hot_rects[titlebar_hot_count] = {mn.x, mn.y, mx.x, mx.y}
	titlebar_hot_count += 1
}

titlebar_point_hot :: proc(x, y: f32) -> bool {
	for r in titlebar_hot_rects[:titlebar_hot_count] {
		if x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3] do return true
	}
	return false
}

TrafficAction :: enum {
	NONE,
	CLOSE,
	MINIMIZE,
	MAXIMIZE,
}

// macOS-style traffic lights: 12 px circles on 20 px slots. Glyphs appear
// when any of the three is hovered; the whole set dims to gray while the
// window is unfocused, matching native behavior.
ui_traffic_lights :: proc(focused: bool) -> TrafficAction {
	action := TrafficAction.NONE
	dl := im.GetWindowDrawList()
	group_min := im.GetCursorScreenPos()
	mouse := im.GetMousePos()
	slot := f32(20)
	group_hovered :=
		mouse.x >= group_min.x && mouse.x < group_min.x + 3 * slot &&
		mouse.y >= group_min.y && mouse.y < group_min.y + slot

	cols := [3]im.Vec4 {
		{0.95, 0.38, 0.35, 1}, // close
		{0.97, 0.75, 0.19, 1}, // minimize
		{0.19, 0.78, 0.26, 1}, // zoom
	}
	acts := [3]TrafficAction{.CLOSE, .MINIMIZE, .MAXIMIZE}
	ids := [3]cstring{"##tl_close", "##tl_min", "##tl_max"}
	for i in 0 ..< 3 {
		pos := im.GetCursorScreenPos()
		center := im.Vec2{pos.x + slot / 2, pos.y + slot / 2}
		if im.InvisibleButton(ids[i], {slot, slot}) {
			action = acts[i]
		}
		titlebar_mark_hot()
		col := focused ? cols[i] : im.Vec4{0.40, 0.40, 0.43, 1}
		im.DrawList_AddCircleFilled(dl, center, 6, im.GetColorU32Vec4(col))
		if group_hovered {
			glyph := im.GetColorU32Vec4({0, 0, 0, 0.55})
			switch i {
			case 0: // close: x
				im.DrawList_AddLine(dl, {center.x - 3, center.y - 3}, {center.x + 3, center.y + 3}, glyph, 1.3)
				im.DrawList_AddLine(dl, {center.x - 3, center.y + 3}, {center.x + 3, center.y - 3}, glyph, 1.3)
			case 1: // minimize: -
				im.DrawList_AddLine(dl, {center.x - 3.2, center.y}, {center.x + 3.2, center.y}, glyph, 1.3)
			case 2: // zoom: square
				im.DrawList_AddRect(dl, {center.x - 2.8, center.y - 2.8}, {center.x + 2.8, center.y + 2.8}, glyph, 0, 1.2)
			}
		}
		if i < 2 do im.SameLine(0, 0)
	}
	return action
}

// Title bar (see above): scene switching, scene creation from templates,
// window controls. Returns a scene index when a scene was selected.
ui_toolbar :: proc(ui: ^Ui, sm: ^SceneManager, window: ^sdl.Window, ied: ^ImGuiEditor) -> int {
	request := -1
	titlebar_reset_hot()

	// A template-created scene appeared in the rescan: select it now.
	if ui.pending_scene != "" {
		for &s, i in sm.scenes {
			if s.title == ui.pending_scene {
				request = i
				break
			}
		}
		if request >= 0 {
			delete(ui.pending_scene)
			ui.pending_scene = ""
		}
	}

	io := im.GetIO()
	im.SetNextWindowPos({0, 0}, .Always)
	im.SetNextWindowSize({io.DisplaySize.x, TITLEBAR_H}, .Always)
	flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoScrollbar,
		.NoScrollWithMouse,
		.NoBringToFrontOnFocus,
	}
	im.PushStyleColorVec4(.WindowBg, {0.102, 0.106, 0.125, 1})
	im.PushStyleColorVec4(.Border, {0, 0, 0, 0})
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	im.PushStyleVarVec2(.FramePadding, {10, 4})
	// Docked chrome is square (DESIGN.md): rounding belongs to floating
	// surfaces only — rounded corners against flush neighbors clash.
	im.PushStyleVar(.WindowRounding, 0)
	if im.Begin("##titlebar", nil, flags) {
		dl := im.GetWindowDrawList()
		focused := .INPUT_FOCUS in sdl.GetWindowFlags(window)

		// Window controls; the scene selector sits right beside them.
		im.SetCursorPos({10, (TITLEBAR_H - 20) / 2})
		#partial switch ui_traffic_lights(focused) {
		case .CLOSE:
			ui.quit_requested = true
		case .MINIMIZE:
			sdl.MinimizeWindow(window)
		case .MAXIMIZE:
			if .MAXIMIZED in sdl.GetWindowFlags(window) {
				sdl.RestoreWindow(window)
			} else {
				sdl.MaximizeWindow(window)
			}
		}

		frame_y := (TITLEBAR_H - (im.GetFontSize() + 8)) / 2

		// Scene selector: click shows all available scenes.
		im.SetCursorPos({10 + 3 * 20 + 8, frame_y})
		im.SetNextItemWidth(210)
		im.PushStyleColorVec4(.FrameBg, {1, 1, 1, 0.05})
		im.PushStyleColorVec4(.FrameBgHovered, {1, 1, 1, 0.10})
		im.PushStyleColorVec4(.FrameBgActive, {1, 1, 1, 0.15})
		current_title := len(sm.scenes) > 0 ? sm.scenes[sm.current].title : "?"
		if im.BeginCombo("##scene_sel", strings_to_c(current_title), {.HeightLarge}) {
			for &s, i in sm.scenes {
				if im.Selectable(strings_to_c(s.title), i == sm.current, {}) {
					request = i
				}
			}
			im.EndCombo()
		}
		titlebar_mark_hot()
		im.PopStyleColor(3)

		// Scene templates: create a new scene file from scratch.
		im.SameLine(0, 8)
		im.SetNextItemWidth(92)
		if im.BeginCombo("##new_kind", "+ new", {}) {
			if im.Selectable("compute", false, {}) {
				if title, ok := scene_create(.COMPUTE); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable("graphics 2d", false, {}) {
				if title, ok := scene_create(.GRAPHICS_2D); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable("graphics 3d", false, {}) {
				if title, ok := scene_create(.GRAPHICS_3D); ok {
					ui.pending_scene = title
				}
			}
			im.EndCombo()
		}
		titlebar_mark_hot()

		// Save-all (floppy) left of pause: same drawn-icon style — the font
		// has no 💾 glyph. Saves every dirty editor tab (ied_save_all).
		size := f32(22)
		save_x := io.DisplaySize.x - 10 - size - 8 - size
		im.SetCursorPos({save_x, (TITLEBAR_H - size) / 2})
		if im.InvisibleButton("##saveall", {size, size}) {
			ied_save_all(ied)
		}
		titlebar_mark_hot()
		smn := im.GetItemRectMin()
		if im.IsItemHovered() {
			im.DrawList_AddRectFilled(dl, smn, {smn.x + size, smn.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 4)
		}
		scol := im.GetColorU32(.Text, 1.0)
		// Floppy: body outline, metal shutter top-right, label slot bottom.
		im.DrawList_AddRect(dl, {smn.x + 3, smn.y + 3}, {smn.x + size - 3, smn.y + size - 3}, scol, 2, 1.4)
		im.DrawList_AddRectFilled(dl, {smn.x + size - 10, smn.y + 4}, {smn.x + size - 5, smn.y + 10}, scol)
		im.DrawList_AddRect(dl, {smn.x + 7, smn.y + size - 9}, {smn.x + size - 7, smn.y + size - 4}, scol, 1, 1.2)

		// Pause/play on the right edge: drawn icon (the font has no ⏸/▶
		// glyphs), one block showing the action the click will take —
		// bars while running, triangle while paused.
		im.SetCursorPos({io.DisplaySize.x - 10 - size, (TITLEBAR_H - size) / 2})
		if im.InvisibleButton("##pauseplay", {size, size}) {
			ui.params.paused = !ui.params.paused
		}
		titlebar_mark_hot()
		mn := im.GetItemRectMin()
		if im.IsItemHovered() {
			im.DrawList_AddRectFilled(dl, mn, {mn.x + size, mn.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 4)
		}
		col := im.GetColorU32(.Text, 1.0)
		if ui.params.paused {
			pad := f32(5)
			im.DrawList_AddTriangleFilled(
				dl,
				{mn.x + pad, mn.y + pad},
				{mn.x + pad, mn.y + size - pad},
				{mn.x + size - pad + 2, mn.y + size / 2},
				col,
			)
		} else {
			bw := f32(4)
			im.DrawList_AddRectFilled(dl, {mn.x + 5, mn.y + 5}, {mn.x + 5 + bw, mn.y + size - 5}, col)
			im.DrawList_AddRectFilled(dl, {mn.x + size - 5 - bw, mn.y + 5}, {mn.x + size - 5, mn.y + size - 5}, col)
		}

		// 1 px separator between the chrome and the scene below.
		im.DrawList_AddLine(
			dl,
			{0, TITLEBAR_H - 0.5},
			{io.DisplaySize.x, TITLEBAR_H - 0.5},
			im.GetColorU32Vec4({1, 1, 1, 0.09}),
		)
	}
	im.End()
	im.PopStyleVar(3)
	im.PopStyleColor(2)
	return request
}

// ---------------------------------------------------------------------------
// Sidebar: a VS Code-style activity strip (narrow icon column) plus a
// docked panel whose content depends on the selected mode. The strip stays
// when the panel is collapsed; SPACE (zen mode) hides both.

STRIP_W :: 46

// One activity-strip button: 34 px slot with a glyph drawn via the draw
// list (the font has no icon glyphs). The active mode gets the accent
// tint; hover brightens. Returns true when clicked.
ui_strip_button :: proc(ui: ^Ui, mode: SidebarMode, index: int) -> bool {
	dl := im.GetWindowDrawList()
	im.SetCursorPos({(STRIP_W - 34) / 2, 10 + f32(index) * 42})
	pos := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(fmt.ctprintf("##strip%d", index), {34, 34})
	hovered := im.IsItemHovered()
	active := ui.mode == mode && ui.panel_open
	cx := pos.x + 17
	cy := pos.y + 17
	if active {
		im.DrawList_AddRectFilled(dl, pos, {pos.x + 34, pos.y + 34}, im.GetColorU32Vec4({0.91, 0.66, 0.34, 0.22}), 8)
	} else if hovered {
		im.DrawList_AddRectFilled(dl, pos, {pos.x + 34, pos.y + 34}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 8)
	}
	icon_col := im.GetColorU32Vec4(
		active ? im.Vec4{0.91, 0.66, 0.34, 1} :
		hovered ? im.Vec4{0.87, 0.88, 0.90, 1} : im.Vec4{0.55, 0.57, 0.62, 1},
	)
	switch mode {
	case .CONTROLS:
		// Sliders: three rails with knobs at different offsets.
		knobs := [3]f32{-2, 3, -4}
		for k, i in knobs {
			y := cy - 6 + f32(i) * 6
			im.DrawList_AddLine(dl, {cx - 7, y}, {cx + 7, y}, icon_col, 1.4)
			im.DrawList_AddCircleFilled(dl, {cx + k, y}, 2.2, icon_col)
		}
	case .FILES:
		// Folder: body outline with a raised tab on the top edge.
		im.DrawList_AddRect(dl, {cx - 8, cy - 4}, {cx + 8, cy + 7}, icon_col, 2, 1.4)
		im.DrawList_AddLine(dl, {cx - 8, cy - 4}, {cx - 8, cy - 6}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 8, cy - 6}, {cx - 3, cy - 6}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 3, cy - 6}, {cx - 1, cy - 4}, icon_col, 1.4)
	case .GRAPH:
		// Graph: two nodes linked by an edge.
		im.DrawList_AddLine(dl, {cx - 2, cy - 2}, {cx + 3, cy + 3}, icon_col, 1.4)
		im.DrawList_AddCircle(dl, {cx - 5, cy - 4}, 3.2, icon_col)
		im.DrawList_AddCircle(dl, {cx + 6, cy + 5}, 3.2, icon_col)
	case .EXPORT:
		// Export: an arrow dropping into a tray.
		im.DrawList_AddLine(dl, {cx, cy - 7}, {cx, cy + 1}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 4, cy - 3}, {cx, cy + 1}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx + 4, cy - 3}, {cx, cy + 1}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 7, cy + 3}, {cx - 7, cy + 7}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx + 7, cy + 3}, {cx + 7, cy + 7}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 7, cy + 7}, {cx + 7, cy + 7}, icon_col, 1.4)
	}
	return clicked
}

// The icon column. Clicking a different mode selects it; clicking the
// active mode's icon collapses/expands the panel (VS Code behavior). A
// settings gear sits at the bottom: editor theme, font scale, and glass
// mode (moved out of the editor toolbar).
ui_activity_strip :: proc(ui: ^Ui, ied: ^ImGuiEditor) {
	io := im.GetIO()
	im.SetNextWindowPos({0, TITLEBAR_H}, .Always)
	im.SetNextWindowSize({STRIP_W, io.DisplaySize.y - TITLEBAR_H}, .Always)
	flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoScrollbar,
		.NoScrollWithMouse,
		.NoBringToFrontOnFocus,
	}
	im.PushStyleColorVec4(.WindowBg, {0.102, 0.106, 0.125, 1})
	im.PushStyleColorVec4(.Border, {0, 0, 0, 0})
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	im.PushStyleVar(.WindowRounding, 0) // docked chrome is square
	if im.Begin("##activity_strip", nil, flags) {
		dl := im.GetWindowDrawList()
		modes := [4]SidebarMode{.CONTROLS, .FILES, .GRAPH, .EXPORT}
		for m, i in modes {
			if ui_strip_button(ui, m, i) {
				if ui.mode == m {
					ui.panel_open = !ui.panel_open
				} else {
					ui.mode = m
					ui.panel_open = true
				}
			}
		}

		// Settings gear pinned to the bottom edge. Glyph: ring + 8 spokes.
		gear_y := io.DisplaySize.y - TITLEBAR_H - 34 - 10
		im.SetCursorPos({(STRIP_W - 34) / 2, gear_y})
		gpos := im.GetCursorScreenPos()
		if im.InvisibleButton("##strip_settings", {34, 34}) {
			im.OpenPopup("##settings")
		}
		ghov := im.IsItemHovered()
		if ghov {
			im.DrawList_AddRectFilled(dl, gpos, {gpos.x + 34, gpos.y + 34}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 8)
		}
		gc := im.Vec2{gpos.x + 17, gpos.y + 17}
		gcol := im.GetColorU32Vec4(
			ghov ? im.Vec4{0.87, 0.88, 0.90, 1} : im.Vec4{0.55, 0.57, 0.62, 1},
		)
		im.DrawList_AddCircle(dl, gc, 3.2, gcol, 0, 1.4)
		for i in 0 ..< 8 {
			a := f32(i) * math.PI / 4
			ca, sa := math.cos(a), math.sin(a)
			im.DrawList_AddLine(dl, {gc.x + 5.2 * ca, gc.y + 5.2 * sa}, {gc.x + 7.8 * ca, gc.y + 7.8 * sa}, gcol, 1.4)
		}

		// Settings popup: appearance knobs, one place only. Two
		// independent font sizes: the code editor's (pushed around the
		// text component) and the UI's (style FontSizeBase). Captions sit
		// on their own rows: trailing slider labels overflowed the
		// auto-sized popup.
		im.SetNextWindowPos({STRIP_W + 6, io.DisplaySize.y - 236}, .Appearing)
		if im.BeginPopup("##settings", {}) {
			im.TextDisabled("theme")
			im.SetNextItemWidth(130)
			if im.BeginCombo("##theme", strings_to_c(THEME_NAMES[ied.theme]), {}) {
				for name, t in THEME_NAMES {
					if im.Selectable(strings_to_c(name), t == ied.theme, {}) {
						ied.theme = t
						ied_apply_theme(ied)
					}
				}
				im.EndCombo()
			}
			im.TextDisabled("editor font")
			im.SetNextItemWidth(130)
			im.SliderFloat("##edfont", &ied.font_size, 10, 28, "%.0f")
			im.TextDisabled("ui font")
			im.SetNextItemWidth(130)
			if im.SliderFloat("##uifont", &ui.font_size, 12, 22, "%.0f") {
				im.GetStyle().FontSizeBase = ui.font_size
			}
			if im.Checkbox("glass", &ied.bg_transparent) {
				ite_set_glass(ied.handle, ied.bg_transparent, 0.55)
			}
			im.EndPopup()
		}
		// 1 px separator between the strip and the panel/scene.
		im.DrawList_AddLine(
			dl,
			{STRIP_W - 0.5, TITLEBAR_H},
			{STRIP_W - 0.5, io.DisplaySize.y},
			im.GetColorU32Vec4({1, 1, 1, 0.09}),
		)
	}
	im.End()
	im.PopStyleVar(2)
	im.PopStyleColor(2)
}

ui_panel_width :: proc(mode: SidebarMode, display_w: f32) -> f32 {
	switch mode {
	case .CONTROLS:
		return 300
	case .FILES:
		return 280
	case .GRAPH:
		return display_w * 0.52
	case .EXPORT:
		return 280
	}
	return 300
}

// CONTROLS mode: the classic controls (view options, export, interaction,
// the active scene's reflected params).
ui_controls_panel :: proc(ui: ^Ui, sm: ^SceneManager) {
	im.TextDisabled("controls")
	// Time: the running clock, shown live. Type a value (or use the +/-
	// steppers) and commit with Enter to jump the scene to that time.
	im.SetNextItemWidth(140)
	im.InputFloat("time (s)", ui.time, 0.5, 5.0, "%.2f")
	im.Checkbox("color", &ui.params.color)
	im.Checkbox("3D view", &ui.params.view3d)
	im.SameLine()
	im.Checkbox("grid", &ui.params.grid)
	im.TextUnformatted(fmt.ctprintf("gen %.2f ms", ui.gen_ms))

	if im.CollapsingHeader("interaction", {}) {
		if im.RadioButton("autorotate", ui.params.interaction == .AUTOROTATE) {
			ui.params.interaction = .AUTOROTATE
		}
		if im.RadioButton("mouse rotation", ui.params.interaction == .MOUSE_ROTATE) {
			ui.params.interaction = .MOUSE_ROTATE
		}
	}

	// The active scene's annotated params, in a visually separate section.
	if len(sm.scenes) > 0 {
		scene := &sm.scenes[sm.current]
		if len(scene.widgets) > 0 {
			im.SeparatorText(fmt.ctprintf("%s params", scene.title))
			for &w, i in scene.widgets {
				id := fmt.ctprintf("%s##w%d", w.label, i)
				switch w.kind {
				case .SLIDER:
					im.SliderFloat(id, &w.value[0], w.min, w.max, "%.2f")
				case .TOGGLE:
					im.Checkbox(id, &w.on)
				case .COLOR:
					im.ColorEdit3(id, &w.value)
				}
			}
		}
	}
}

// EXPORT mode: frame and animation capture. PNG grabs the current frame
// at the current app_time; the GIF re-renders [gif_start, gif_end] frame
// by frame and assembles it with ffmpeg (blocking, a few seconds).
ui_export_panel :: proc(ui: ^Ui) {
	im.TextDisabled("export")
	if im.Button("export png") {
		ui.export_request = .PNG
	}
	im.SameLine()
	im.TextUnformatted(fmt.ctprintf("frame at t = %.2f s", ui.time^))

	im.SeparatorText("gif")
	im.SetNextItemWidth(140)
	im.InputFloat("start (s)", &ui.gif_start, 0.5, 1.0, "%.2f")
	im.SetNextItemWidth(140)
	im.InputFloat("end (s)", &ui.gif_end, 0.5, 1.0, "%.2f")
	ui.gif_start = max(ui.gif_start, 0)
	ui.gif_end = max(ui.gif_end, ui.gif_start)
	frames := max(1, int((ui.gif_end - ui.gif_start) * GIF_FPS))
	im.TextUnformatted(fmt.ctprintf("%d frames @ %d fps", frames, GIF_FPS))
	if im.Button("export gif") {
		ui.export_request = .GIF
	}
}

// FILES mode: every .slang under src/shaders. Scenes switch the running
// scene; shared modules open in the editor (jumping to EDITOR mode).
// Returns a scene index when a scene was picked.
ui_files_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) -> int {
	request := -1

	// Keep the list fresh (template-created scenes, external files); the
	// rescan is append-only and cheap.
	ui.files_frame += 1
	if ui.files_frame % 120 == 1 {
		ied_rescan(ed)
	}

	active_title := len(sm.scenes) > 0 ? sm.scenes[sm.current].title : ""

	im.TextDisabled("scenes")
	for f in ed.files {
		if !strings.has_prefix(f, "scenes/") do continue
		rel := f[len("scenes/"):]
		slash := strings.index(rel, "/")
		if slash < 0 do continue
		unit := rel[:slash]
		file := rel[slash + 1:]
		if file == unit {
			// The scene unit itself (entry file <unit>/<unit>).
			if im.Selectable(strings_to_c(unit), unit == active_title, {}) {
				for &s, i in sm.scenes {
					if s.title == unit {
						request = i
						break
					}
				}
			}
		} else {
			// Scene-owned module: indented under its unit; opens in the
			// editor.
			if im.Selectable(strings_to_c(fmt.tprintf("  %s", file)), false, {}) {
				ied_load_named(ed, f)
				ed.open = true
			}
		}
	}

	im.Spacing()
	im.TextDisabled("shared")
	for f in ed.files {
		if strings.has_prefix(f, "scenes/") do continue
		if im.Selectable(strings_to_c(f), false, {}) {
			ied_load_named(ed, f)
			ed.open = true // surface the floating editor on the file
		}
	}
	return request
}

// Builds the widgets. Returns a scene index when a scene was selected.
// Scenes are the runtime-discovered .slang files (see scene_runtime.odin);
// the active scene's annotated params ([UiSlider] etc.) appear as widgets
// automatically.
ui_build :: proc(
	ui: ^Ui,
	sm: ^SceneManager,
	window: ^sdl.Window,
	ied: ^ImGuiEditor,
	ing: ^NodeGraph,
	frame_w, frame_h: i32,
) -> int {
	ui.scene_request = ui_toolbar(ui, sm, window, ied)
	ui.export_request = .NONE
	io := im.GetIO()
	ui.captures_mouse = io.WantCaptureMouse

	if ui.params.grid && !ui.params.view3d {
		ui_draw_grid(ui, frame_w, frame_h)
	}
	if !ui.open do return ui.scene_request

	ui_activity_strip(ui, ied)
	if !ui.panel_open do return ui.scene_request

	im.SetNextWindowPos({STRIP_W, TITLEBAR_H}, .Always)
	im.SetNextWindowSize({ui_panel_width(ui.mode, io.DisplaySize.x), io.DisplaySize.y - TITLEBAR_H}, .Always)
	flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
	}
	im.PushStyleVar(.WindowRounding, 0) // docked chrome is square
	if im.Begin("##side_panel", nil, flags) {
		switch ui.mode {
		case .CONTROLS:
			ui_controls_panel(ui, sm)
		case .FILES:
			if r := ui_files_panel(ui, sm, ied); r >= 0 {
				ui.scene_request = r
			}
		case .GRAPH:
			ing_panel(ing, ied, sm.scenes[sm.current].title)
		case .EXPORT:
			ui_export_panel(ui)
		}
	}
	im.End()
	im.PopStyleVar()
	return ui.scene_request
}

// Normalized graph overlay: both axes are always [0,1], independent of
// window size or aspect ratio. Origin is bottom-left (GLSL convention).
// Drawn on ImGui's background draw list: over the scene, behind all windows.
GRID_DIVISIONS :: 10     // minor line every 0.1
GRID_MAJOR_EVERY :: 5    // dark line every 0.5
GRID_LABEL_EVERY :: 2    // label every 0.2

ui_draw_grid :: proc(ui: ^Ui, frame_w, frame_h: i32) {
	dl := im.GetBackgroundDrawList()
	w := f32(frame_w)
	h := f32(frame_h)

	minor := im.GetColorU32Vec4({0, 0, 0, 0.09})
	major := im.GetColorU32Vec4({0, 0, 0, 0.26})
	axis := im.GetColorU32Vec4({0, 0, 0, 0.65})
	text_col := im.GetColorU32Vec4({0, 0, 0, 0.83})

	// Vertical: normalized X grows left -> right.
	for k in 0 ..= GRID_DIVISIONS {
		x := f32(k) / GRID_DIVISIONS * w
		col := minor
		if k == 0 || k == GRID_DIVISIONS {
			col = axis
		} else if k % GRID_MAJOR_EVERY == 0 {
			col = major
		}
		im.DrawList_AddLine(dl, {min(x, w - 1), 0}, {min(x, w - 1), h}, col)
	}
	// Horizontal: screen Y grows down, normalized Y grows up.
	for k in 0 ..= GRID_DIVISIONS {
		y := h - f32(k) / GRID_DIVISIONS * h
		col := minor
		if k == 0 || k == GRID_DIVISIONS {
			col = axis
		} else if k % GRID_MAJOR_EVERY == 0 {
			col = major
		}
		py := clamp(y, 0, h - 1)
		im.DrawList_AddLine(dl, {0, py}, {w, py}, col)
	}

	// Labels: X just above the bottom edge, Y just right of the left edge,
	// a single 0 at the origin.
	for k in 0 ..= GRID_DIVISIONS {
		if k % GRID_LABEL_EVERY != 0 do continue
		v := f32(k) / GRID_DIVISIONS
		x := clamp(v * w + 3, 3, w - 18)
		im.DrawList_AddText(dl, {x, h - 15}, text_col, fmt.ctprintf("%.1f", v))
	}
	for k := GRID_LABEL_EVERY; k <= GRID_DIVISIONS; k += GRID_LABEL_EVERY {
		v := f32(k) / GRID_DIVISIONS
		y := clamp(h - v * h - 14, 2, h - 16)
		im.DrawList_AddText(dl, {4, y}, text_col, fmt.ctprintf("%.1f", v))
	}
}

// cstring view of a Go-style string, in temp allocator (ImGui needs
// NUL-terminated labels).
strings_to_c :: proc(s: string) -> cstring {
	return fmt.ctprintf("%s", s)
}
