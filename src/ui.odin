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

// Mobile theater (F4): when true, the editor docks to the bottom half
// of the portrait window. Package-level because ied_frame has no Ui.
mobile_theater: bool

// Portrait window size for vertical recordings: half of 1080×1920.
MOBILE_W :: 540
MOBILE_H :: 960

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
	LEARN,
	GRAPH,
	EXPORT,
	EFFECTS,
	SHORTCUTS,
}

Ui :: struct {
	params:         UiParams,
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
	// Theater mode (F3): one-shortcut recording composition: sidebar
	// hidden, editor docked open, larger type. Saved state restores on
	// exit.
	theater:        bool,
	saved_ui_font:  f32,
	saved_ed_font:  f32,
	saved_open:     bool,
	saved_ed_open:  bool,
	// Mobile theater (F4): 9:16 portrait recording mode. Own saved slots
	// (theater's saved_* would clobber if both modes nest).
	mobile:              bool,
	mobile_saved_ui_font: f32,
	mobile_saved_ed_font: f32,
	mobile_saved_open:    bool,
	mobile_saved_ed_open: bool,
	graph_max:      bool, // GRAPH panel maximized to the full window width
	files_frame:    int,  // frame counter pacing the FILES-mode rescan
	font_size:      f32,  // UI font in points; the code font is ImGuiEditor.font_size
	// Overdrive FX state (fx.odin): settings, the strip's animated
	// selection pill, the mode-change slide, the panel collapse spring,
	// the sidebar's zen slide, and the scene combo's rect (bursts
	// originate there on scene switch).
	fx:             Fx,
	pill:           Anim,
	slide:          f32, // 0..1 mode-change slide-in progress
	panel_w:        Anim, // panel width spring (collapse/expand)
	user_w:         f32, // user-dragged panel width; 0 = per-mode default
	sidebar_x:      Anim, // strip+panel x offset (zen mode slides left)
	prev_mode:      SidebarMode,
	scene_sel_rect: [4]f32,
	// Save feedback on the floppy icon: 1 on a successful save, decays
	// out (amber fill fades, the check draws in during the first third).
	save_flash:     f32,
	// Pixel inspector: a scene click requests an async 1x1 GPU readback.
	pixel_inspect_enabled: bool,
	pixel_inspect_request: bool,
	pixel_inspect_pending: bool,
	pixel_inspect_valid:   bool,
	pixel_request_pos:     [2]f32, // SDL window coordinates, top-left origin
	pixel_x, pixel_y:      i32,
	pixel_uv:              [2]f32, // 0..1, y up (shader convention)
	pixel_scene_uv:        [2]f32, // centered/aspect-correct scene_uv
	pixel_rgba:            [4]f32,
	debug_watch_request: bool,
	debug_watch_pending: bool,
	debug_watch_sampled: bool,
	debug_watches: [DEBUG_WATCH_RECORD_COUNT]DebugWatchSample,
	debug_provenance_pending: bool,
	debug_provenance_valid: [DEBUG_WATCH_MAX_PASSES]bool,
	debug_provenance_path: [DEBUG_WATCH_MAX_PASSES]bool,
	debug_provenance_rgba: [DEBUG_WATCH_MAX_PASSES][4]f32,
	gen_ms:         f32, // average compute texture generation time, fed by main
	// A scene created from a template: selected as soon as the watcher
	// discovers the new file (next frame's rescan).
	pending_scene:  string,
}

ui_init :: proc() -> ^Ui {
	ui := new(Ui)
	ui.params.skybox = -1 // start with no skybox
	ui.open = true
	ui.panel_open = true
	ui.font_size = 16
	ui.gif_end = 5
	ui.fx = fx_defaults()
	ui.slide = 1
	ui.panel_w.value = 300
	return ui
}

// Professional dark theme: tinted neutral layers (bar / panel / frame) so
// scene colors stay true, and one warm amber accent reserved for selection
// and active state. Restrained color strategy: the accent never decorates,
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
) {
	ui_toolbar(ui, sm, window, ied)
	io := im.GetIO()
	ui.captures_mouse = io.WantCaptureMouse

	// FX per-frame: particles always run (they render on the foreground
	// draw list, above everything).
	fx_particles_step(io.DeltaTime)
	fx_particles_draw(im.GetForegroundDrawList())

	// Cursor trail: soft motes behind fast cursor movement (quiet by
	// design: texture, not fireworks).
	{
		mouse := [2]f32{io.MousePos.x, io.MousePos.y}
		d := mouse - fx_last_mouse
		if d.x * d.x + d.y * d.y > 36 && fx_alive < FX_MAX_PARTICLES - 4 {
			fx_trail(&ui.fx, mouse)
			if d.x * d.x + d.y * d.y > 144 do fx_trail(&ui.fx, mouse)
		}
		fx_last_mouse = mouse
	}

	// Mode change: the panel content slides in from the left with a
	// cubic ease-out (replaces the old flat alpha fade, which read as
	// nothing happening).
	if ui.mode != ui.prev_mode {
		ui.prev_mode = ui.mode
		ui.slide = 0
	}
	ui.slide = min(1, ui.slide + io.DeltaTime / 0.16)

	// Zen (SPACE / Cmd+B): the whole sidebar slides off the left edge
	// and back. Keep rendering while the spring settles.
	target_w := ui_panel_width(ui, ui.mode, io.DisplaySize.x)
	anim_step(
		&ui.sidebar_x,
		ui.open ? 0 : -(STRIP_W + target_w),
		io.DeltaTime,
		&ui.fx,
	)

	if ui.params.grid && !ui.params.view3d {
		ui_draw_grid(ui, frame_w, frame_h)
	}
	hidden_x := -(STRIP_W + target_w)
	if !ui.open &&
	   (!fx_on(&ui.fx) || !ui.fx.springs || ui.sidebar_x.value <= hidden_x + 2) {
		return
	}

	ui_activity_strip(ui, ied, ui.sidebar_x.value)

	// Panel collapse: clicking the active mode's icon springs the width
	// shut (VS Code behavior, but physical).
	anim_step(&ui.panel_w, ui.panel_open ? target_w : 0, io.DeltaTime, &ui.fx)
	if ui.panel_w.value < 4 do return

	slide_off := f32(0)
	panel_alpha := f32(1)
	if fx_on(&ui.fx) && ui.fx.springs {
		t := ui.slide
		ease := 1 - (1 - t) * (1 - t) * (1 - t)
		slide_off = (1 - ease) * -14
		panel_alpha = 0.25 + 0.75 * ease
	}

	im.SetNextWindowPos({STRIP_W + ui.sidebar_x.value + slide_off, TITLEBAR_H}, .Always)
	im.SetNextWindowSize({ui.panel_w.value, io.DisplaySize.y - TITLEBAR_H}, .Always)
	panel_x := STRIP_W + ui.sidebar_x.value + slide_off
	im.SetNextWindowBgAlpha(panel_alpha)
	flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
	}
	if ui.mode == .GRAPH {
		// The graph canvas owns the wheel (trackpad pan). If any overlay
		// item (preview toggle, maximize button) ever pushes the panel's
		// content past its size, the window becomes a scroll container
		// and ImGui consumes the wheel to scroll it, killing the pan
		// and hiding part of the editor. Pin the scroll at the origin
		// and refuse wheel scrolling in this mode.
		flags += {.NoScrollWithMouse, .NoScrollbar}
		im.SetNextWindowScroll({0, 0})
	}
	im.PushStyleVar(.WindowRounding, 0) // docked chrome is square
	if im.Begin("##side_panel", nil, flags) {
		ui_draw_grain(ui)
		switch ui.mode {
		case .CONTROLS:
			ui_controls_panel(ui, sm)
		case .FILES:
			ui_files_panel(ui, sm, ied)
		case .LEARN:
			ui_learn_panel(ui, sm, ied)
		case .GRAPH:
			ing_panel(ing, ied, sm.scenes[sm.current].title, &ui.graph_max)
		case .EXPORT:
			ui_export_panel(ui)
		case .EFFECTS:
			ui_fx_panel(ui)
		case .SHORTCUTS:
			ui_shortcuts_panel(ui)
		}
	}
	im.End()
	im.PopStyleVar()

	ui_panel_edge(ui, panel_x)
	return
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
