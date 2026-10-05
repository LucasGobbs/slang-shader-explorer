package main

// Title bar chrome: the app window is borderless (SDL_WINDOW_BORDERLESS),
// so this file owns everything the native frame would do: traffic-light
// window controls, the scene selector, save/pause, and the hot-rect
// registry that keeps the SDL hit test (main.odin) off interactive
// widgets. Split out of ui.odin.

import im "../vendor/odin-imgui"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Title bar: the app window is borderless (SDL_WINDOW_BORDERLESS), so this
// bar IS the window chrome: traffic-light controls on the left, the scene
// selector beside them, "+ new", drag space, pause on the right. Empty bar
// space drags the window and edge strips resize it via the SDL hit test in
// main.odin; every interactive widget registers its rect below so the hit
// test leaves clicks on them to ImGui.

TITLEBAR_H :: 38

titlebar_hot_rects: [8][4]f32 // min.x, min.y, max.x, max.y in window coords
titlebar_hot_count: int

// The title bar IS an SDL draggable region (window_hit_test, main.odin):
// macOS handles the drag and its window tiling natively. No manual drag
// state needed.

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
// window controls. Emits messages (app.odin) instead of returning them.
ui_toolbar :: proc(ui: ^Ui, sm: ^SceneManager, window: ^sdl.Window, ied: ^ImGuiEditor) {
	titlebar_reset_hot()

	// A template-created scene appeared in the rescan: select it now.
	// Only clear the pending title once the watcher actually discovered
	// the new scene: the async build takes a few frames, and clearing
	// early loses the selection entirely.
	if ui.pending_scene != "" {
		for &s, i in sm.scenes {
			if s.title == ui.pending_scene {
				emit(SceneSelected(i))
				delete(ui.pending_scene)
				ui.pending_scene = ""
				break
			}
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
	// Docked chrome is square: rounding belongs to floating
	// surfaces only: rounded corners against flush neighbors clash.
	im.PushStyleVar(.WindowRounding, 0)
	if im.Begin("##titlebar", nil, flags) {
		dl := im.GetWindowDrawList()
		focused := .INPUT_FOCUS in sdl.GetWindowFlags(window)

		// Window controls; the scene selector sits right beside them.
		im.SetCursorPos({10, (TITLEBAR_H - 20) / 2})
		#partial switch ui_traffic_lights(focused) {
		case .CLOSE:
			emit(Quit{})
		case .MINIMIZE:
			emit(WindowMinimize{})
		case .MAXIMIZE:
			// Green = macOS fullscreen (covers Dock and menu bar), not
			// zoom. Zoom lives on the title-bar double-click instead.
			emit(WindowFullscreen{})
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
					emit(SceneSelected(i))
				}
			}
			im.EndCombo()
		}
		titlebar_mark_hot()
		{
			mn := im.GetItemRectMin()
			mx := im.GetItemRectMax()
			ui.scene_sel_rect = {mn.x, mn.y, mx.x, mx.y}
			fx_celebrate_pos = {(mn.x + mx.x) / 2, (mn.y + mx.y) / 2}
		}
		im.PopStyleColor(3)

		// Scene templates: create a new scene file from scratch.
		im.SameLine(0, 8)
		im.SetNextItemWidth(92)
		if im.BeginCombo("##new_kind", trc("+ new"), {}) {
			if im.Selectable(trc("compute"), false, {}) {
				if title, ok := scene_create(.COMPUTE); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable(trc("graphics 2d"), false, {}) {
				if title, ok := scene_create(.GRAPHICS_2D); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable(trc("graphics 3d"), false, {}) {
				if title, ok := scene_create(.GRAPHICS_3D); ok {
					ui.pending_scene = title
				}
			}
			im.EndCombo()
		}
		titlebar_mark_hot()

		// Save-all (floppy) left of pause: same drawn-icon style: the font
		// has no 💾 glyph. Saves every dirty editor tab (ied_save_all).
		size := f32(22)
		save_x := io.DisplaySize.x - 10 - size - 8 - size
		im.SetCursorPos({save_x, (TITLEBAR_H - size) / 2})
		if im.InvisibleButton("##saveall", {size, size}) {
			emit(SaveAll{})
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

		// Save flash: amber fill fading out, with a check that draws
		// itself in during the first third of the fade (main sets
		// ui.save_flash = 1 on a successful save).
		if ui.save_flash > 0 {
			ui.save_flash = max(0, ui.save_flash - io.DeltaTime * 1.4)
			k := ui.save_flash
			im.DrawList_AddRectFilled(
				dl,
				{smn.x + 3, smn.y + 3},
				{smn.x + size - 3, smn.y + size - 3},
				im.GetColorU32Vec4({0.91, 0.66, 0.34, 0.45 * k}),
				2,
			)
			p := min(1, (1 - k) * 3.3)
			x1, y1 := smn.x + 6, smn.y + size * 0.55
			x2, y2 := smn.x + 9.5, smn.y + size - 6.5
			x3, y3 := smn.x + size - 4.5, smn.y + 5.5
			ccol := im.GetColorU32Vec4({1, 1, 1, 0.9})
			s1 := min(p / 0.35, 1)
			s2 := min(max(0, (p - 0.35) / 0.65), 1)
			if s1 > 0 {
				im.DrawList_AddLine(dl, {x1, y1}, {x1 + (x2 - x1) * s1, y1 + (y2 - y1) * s1}, ccol, 1.6)
			}
			if s2 > 0 {
				im.DrawList_AddLine(dl, {x2, y2}, {x2 + (x3 - x2) * s2, y2 + (y3 - y2) * s2}, ccol, 1.6)
			}
		}

		// Pause/play on the right edge: drawn icon (the font has no ⏸/▶
		// glyphs), one block showing the action the click will take:
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
}
