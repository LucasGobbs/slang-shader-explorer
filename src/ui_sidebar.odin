package main

// Sidebar: the VS Code-style activity strip (icon column) and its docked
// mode panels (controls, files, graph, export, effects), the settings
// gear popup, the panel grain background, and the resize handle. Split
// out of ui.odin.

import im "../vendor/odin-imgui"
import "core:fmt"
import "core:math"
import "core:strings"

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
	// The active tint is the strip's animated pill (ui_activity_strip);
	// buttons only draw the hover wash.
	if !active && hovered {
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
	case .LEARN:
		// Open book: two page halves around a spine.
		im.DrawList_AddLine(dl, {cx, cy - 7}, {cx, cy + 6}, icon_col, 1.4) // spine
		im.DrawList_AddLine(dl, {cx, cy - 7}, {cx - 8, cy - 4}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 8, cy - 4}, {cx - 8, cy + 5}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx - 8, cy + 5}, {cx, cy + 6}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx, cy - 7}, {cx + 8, cy - 4}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx + 8, cy - 4}, {cx + 8, cy + 5}, icon_col, 1.4)
		im.DrawList_AddLine(dl, {cx + 8, cy + 5}, {cx, cy + 6}, icon_col, 1.4)
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
	case .EFFECTS:
		// Ink droplet: teardrop.
		im.DrawList_AddCircleFilled(dl, {cx, cy + 2.5}, 4.6, icon_col)
		im.DrawList_AddTriangleFilled(dl, {cx - 4, cy + 1}, {cx + 4, cy + 1}, {cx, cy - 7}, icon_col)
	}
	return clicked
}

// The icon column. Clicking a different mode selects it; clicking the
// active mode's icon collapses/expands the panel (VS Code behavior). A
// settings gear sits at the bottom: editor theme, font scale, and glass
// mode (moved out of the editor toolbar).
ui_activity_strip :: proc(ui: ^Ui, ied: ^ImGuiEditor, x_off: f32) {
	io := im.GetIO()
	im.SetNextWindowPos({x_off, TITLEBAR_H}, .Always)
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
		modes := [6]SidebarMode{.CONTROLS, .FILES, .LEARN, .GRAPH, .EXPORT, .EFFECTS}

		// Animated selection pill: slides to the active mode's slot
		// (fx.springs; snaps when springs or the FX layer are off).
		active_idx := 0
		for m, i in modes {
			if m == ui.mode {
				active_idx = i
				break
			}
		}
		anim_step(&ui.pill, f32(27 + active_idx * 42), io.DeltaTime, &ui.fx)
		if ui.panel_open {
			win_pos := im.GetWindowPos()
			py := win_pos.y + ui.pill.value
			im.DrawList_AddRectFilled(dl, {win_pos.x + 6, py - 17}, {win_pos.x + 40, py + 17}, im.GetColorU32Vec4({0.91, 0.66, 0.34, 0.22}), 8)
		}

		for m, i in modes {
			if ui_strip_button(ui, m, i) {
				if ui.mode == m {
					emit(TogglePanel{})
				} else {
					emit(SetMode(m))
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
		// Tall enough for every row (language, theme, two fonts, glass,
		// transparency, two pan knobs): open with the bottom inside the
		// window instead of overflowing past it.
		im.SetNextWindowPos({STRIP_W + 6, io.DisplaySize.y - 480}, .Appearing)
		if im.BeginPopup("##settings", {}) {
			im.TextDisabled(trc("language"))
			im.SetNextItemWidth(130)
			if im.BeginCombo("##lang", strings_to_c(LANGUAGE_TAGS[app_language]), {}) {
				for tag, l in LANGUAGE_TAGS {
					if im.Selectable(strings_to_c(tag), l == app_language, {}) {
						i18n_set_language(l)
					}
				}
				im.EndCombo()
			}
			im.TextDisabled(trc("theme"))
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
			im.TextDisabled(trc("editor font"))
			im.SetNextItemWidth(130)
			im.SliderFloat("##edfont", &ied.font_size, 10, 28, "%.0f")
			im.TextDisabled(trc("ui font"))
			im.SetNextItemWidth(130)
			if im.SliderFloat("##uifont", &ui.font_size, 12, 22, "%.0f") {
				im.GetStyle().FontSizeBase = ui.font_size
			}
			if im.Checkbox(trc("glass"), &ied.bg_transparent) {
				ite_set_glass(ied.handle, ied.bg_transparent, ied.glass_alpha)
			}
			im.TextDisabled(trc("transparency"))
			im.SetNextItemWidth(130)
			if im.SliderFloat("##galpha", &ied.glass_alpha, 0.10, 1.00, "%.2f") {
				// Live-reapply when glass is on (the floating window's
				// frame alpha reads glass_alpha every frame).
				if ied.bg_transparent {
					ite_set_glass(ied.handle, true, ied.glass_alpha)
				}
			}
			im.TextDisabled(trc("graph pan friction"))
			im.SetNextItemWidth(130)
			im.SliderFloat("##panfric", &sg_pan_friction, 1, 10, "%.1f")
			im.TextDisabled(trc("graph pan max speed"))
			im.SetNextItemWidth(130)
			im.SliderFloat("##panspeed", &sg_pan_max_speed, 1000, 12000, "%.0f")
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

ui_panel_width :: proc(ui: ^Ui, mode: SidebarMode, display_w: f32) -> f32 {
	// The user's dragged width wins once set (VS Code: one sidebar width
	// for every mode), clamped to a sane band.
	if ui.user_w > 0 {
		return clamp(ui.user_w, 220, display_w * 0.85)
	}
	switch mode {
	case .CONTROLS:
		return 300
	case .FILES:
		return 280
	case .LEARN:
		return 340
	case .GRAPH:
		if ui.graph_max do return display_w - STRIP_W
		return display_w * 0.52
	case .EXPORT:
		return 280
	case .EFFECTS:
		return 280
	}
	return 300
}

// CONTROLS mode: the classic controls (view options, export, interaction,
// the active scene's reflected params).
ui_controls_panel :: proc(ui: ^Ui, sm: ^SceneManager) {
	im.TextDisabled(trc("controls"))
	// Time: the running clock, shown live. Type a value (or use the +/-
	// steppers) and commit with Enter to jump the scene to that time.
	im.SetNextItemWidth(140)
	im.InputFloat(trc("time (s)"), ui.time, 0.5, 5.0, "%.2f")
	im.Checkbox(trc("color"), &ui.params.color)
	im.Checkbox(trc("3D view"), &ui.params.view3d)
	im.SameLine()
	im.Checkbox(trc("grid"), &ui.params.grid)
	im.TextUnformatted(fmt.ctprintf(tr("gen %.2f ms"), ui.gen_ms))

	if im.CollapsingHeader(trc("debug"), {}) {
		im.TextDisabled(trc("return debug_* from the shader"))
		im.TextColored({1.0, 0.1, 1.0, 1.0}, "%s", "NaN")
		im.SameLine()
		im.TextColored({1.0, 1.0, 0.1, 1.0}, "%s", "+Inf")
		im.SameLine()
		im.TextColored({0.1, 1.0, 1.0, 1.0}, "%s", "-Inf")
		im.Checkbox(trc("pixel inspector"), &ui.pixel_inspect_enabled)
		if ui.pixel_inspect_enabled {
			im.TextDisabled(trc("click the scene to sample"))
			if ui.pixel_inspect_pending {
				im.TextDisabled(trc("waiting for GPU..."))
			}
			if ui.pixel_inspect_valid {
				im.TextUnformatted(fmt.ctprintf("pixel  %d, %d", ui.pixel_x, ui.pixel_y))
				im.TextUnformatted(fmt.ctprintf("uv     %.4f, %.4f", ui.pixel_uv[0], ui.pixel_uv[1]))
				im.TextUnformatted(fmt.ctprintf("scene  %.4f, %.4f", ui.pixel_scene_uv[0], ui.pixel_scene_uv[1]))
				im.TextColored(
					{ui.pixel_rgba[0], ui.pixel_rgba[1], ui.pixel_rgba[2], 1},
					"rgba   %.3f, %.3f, %.3f, %.3f",
					ui.pixel_rgba[0],
					ui.pixel_rgba[1],
					ui.pixel_rgba[2],
					ui.pixel_rgba[3],
				)
				if len(sm.scenes) > 0 {
					scene := &sm.scenes[sm.current]
					if scene.pipeline.output_pass >= 0 && scene.pipeline.output_pass < len(scene.passes) {
						im.TextUnformatted(fmt.ctprintf("pass   %s", scene.passes[scene.pipeline.output_pass].name))
					}
				}
			}
			if ui.pixel_inspect_valid && len(sm.scenes) > 0 {
				scene := &sm.scenes[sm.current]
				im.SeparatorText(trc("pixel provenance"))
				if ui.debug_provenance_pending do im.TextDisabled(trc("reading pass outputs..."))
				for pass, i in scene.passes {
					if i >= DEBUG_WATCH_MAX_PASSES || !ui.debug_provenance_path[i] do continue
					if !ui.debug_provenance_valid[i] {
						im.TextDisabled(fmt.ctprintf("%s · pending", pass.name))
						continue
					}
					value := ui.debug_provenance_rgba[i]
					im.TextColored(
						{value[0], value[1], value[2], 1},
						"%s  [%.3f, %.3f, %.3f, %.3f]",
						strings_to_c(pass.name), value[0], value[1], value[2], value[3],
					)
				}
				if scene_has_debug_watches(scene) {
					if im.Button(trc("refresh watches")) {
						ui.debug_watch_request = true
						ui.debug_watch_sampled = false
					}
					if ui.debug_watch_pending {
						im.SameLine()
						im.TextDisabled(trc("reading watches..."))
					}
					if ui.debug_watch_sampled {
						found := false
						for watch, record_index in ui.debug_watches {
							if !watch.valid do continue
							slot := record_index % DEBUG_WATCH_COUNT
							found = true
							label := fmt.tprintf("watch %d", slot)
							if int(watch.pass) < len(scene.passes) {
								pass := &scene.passes[watch.pass]
								if pass.debug_watch_labels[slot] != "" do label = pass.debug_watch_labels[slot]
								if len(scene.passes) > 1 {
									im.TextDisabled(fmt.ctprintf("%s ·", pass.name))
									im.SameLine()
								}
							}
							switch watch.count {
							case 1: im.TextUnformatted(fmt.ctprintf("%s = %.4f", label, watch.value[0]))
							case 2: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f]", label, watch.value[0], watch.value[1]))
							case 3: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f, %.4f]", label, watch.value[0], watch.value[1], watch.value[2]))
							case: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f, %.4f, %.4f]", label, watch.value[0], watch.value[1], watch.value[2], watch.value[3]))
							}
						}
						if !found do im.TextDisabled(trc("no debug_watch values for this pixel"))
					}
				} else {
					im.TextDisabled(trc("add debug_watch_* in the shader"))
					im.SameLine()
					im.TextDisabled("(?)")
					if im.IsItemHovered() && im.BeginTooltip() {
						im.TextUnformatted("fragment:")
						im.TextDisabled("debug_watch_fragment(slot, value,")
						im.TextDisabled("  uint2(input.gl_FragCoord.xy), Uniforms)")
						im.Spacing()
						im.TextUnformatted("compute:")
						im.TextDisabled("debug_watch_compute(slot, value, id.xy, Uniforms)")
						im.Spacing()
						im.TextDisabled("The value expression becomes its label.")
						im.EndTooltip()
					}
				}
			}
		}
	}
	if im.CollapsingHeader(trc("interaction"), {}) {
		if im.RadioButton(trc("autorotate"), ui.params.interaction == .AUTOROTATE) {
			ui.params.interaction = .AUTOROTATE
		}
		if im.RadioButton(trc("mouse rotation"), ui.params.interaction == .MOUSE_ROTATE) {
			ui.params.interaction = .MOUSE_ROTATE
		}
	}

	// The active scene's annotated params, in a visually separate section.
	if len(sm.scenes) > 0 {
		scene := &sm.scenes[sm.current]
		if len(scene.widgets) > 0 {
			im.SeparatorText(fmt.ctprintf(tr("%s params"), scene.title))
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
	im.TextDisabled(trc("export"))
	if im.Button(trc("export png")) {
		mn := im.GetItemRectMin()
		mx := im.GetItemRectMax()
		emit(ExportAction{kind = .PNG, at = {(mn.x + mx.x) / 2, (mn.y + mx.y) / 2}})
	}
	im.SameLine()
	im.TextUnformatted(fmt.ctprintf(tr("frame at t = %.2f s"), ui.time^))

	im.SeparatorText("gif")
	im.SetNextItemWidth(140)
	im.InputFloat(trc("start (s)"), &ui.gif_start, 0.5, 1.0, "%.2f")
	im.SetNextItemWidth(140)
	im.InputFloat(trc("end (s)"), &ui.gif_end, 0.5, 1.0, "%.2f")
	ui.gif_start = max(ui.gif_start, 0)
	ui.gif_end = max(ui.gif_end, ui.gif_start)
	frames := max(1, int((ui.gif_end - ui.gif_start) * GIF_FPS))
	im.TextUnformatted(fmt.ctprintf(tr("%d frames @ %d fps"), frames, GIF_FPS))
	if im.Button(trc("export gif")) {
		mn := im.GetItemRectMin()
		mx := im.GetItemRectMax()
		emit(ExportAction{kind = .GIF, at = {(mn.x + mx.x) / 2, (mn.y + mx.y) / 2}})
	}
}

// EFFECTS mode: the FX showroom. Global intensity (off = the static
// fallback), per-effect toggles, and preview triggers.
ui_fx_panel :: proc(ui: ^Ui) {
	fx := &ui.fx
	im.TextDisabled(trc("effects"))

	im.SetNextItemWidth(140)
	if im.BeginCombo("##fx_intensity", trc(FX_INTENSITY_NAMES[fx.intensity]), {}) {
		for name, v in FX_INTENSITY_NAMES {
			if im.Selectable(trc(name), v == fx.intensity, {}) {
				emit(SetFxIntensity(v))
			}
		}
		im.EndCombo()
	}

	// Toggles route through update (app.odin): the checkbox edits a copy,
	// the real field flips only there.
	develop := fx.develop
	if im.Checkbox(trc("develop transition"), &develop) {
		emit(ToggleFx(.DEVELOP))
	}
	particles := fx.particles
	if im.Checkbox(trc("ink particles"), &particles) {
		emit(ToggleFx(.PARTICLES))
	}
	springs := fx.springs
	if im.Checkbox(trc("springs"), &springs) {
		emit(ToggleFx(.SPRINGS))
	}
	grain := fx.grain
	if im.Checkbox(trc("paper grain"), &grain) {
		emit(ToggleFx(.GRAIN))
	}
	sound := fx.sound
	if im.Checkbox(trc("sound"), &sound) {
		emit(ToggleFx(.SOUND))
	}

	// Develop style: which transition plays on scene switch.
	im.TextDisabled(trc("develop style"))
	im.SetNextItemWidth(140)
	if im.BeginCombo("##fx_devstyle", trc(FX_DEVELOP_STYLE_NAMES[fx.develop_style]), {}) {
		for name, v in FX_DEVELOP_STYLE_NAMES {
			if im.Selectable(trc(name), v == fx.develop_style, {}) {
				fx.develop_style = v
			}
		}
		im.EndCombo()
	}

	im.Spacing()
	im.SeparatorText(trc("preview"))
	if im.Button(trc("develop")) {
		emit(DevelopPreview{})
	}
	im.SameLine()
	if im.Button(trc("burst")) {
		mn := im.GetItemRectMin()
		mx := im.GetItemRectMax()
		fx_burst(fx, {(mn.x + mx.x) / 2, (mn.y + mx.y) / 2}, 70, 30, 240)
	}
}

// FILES mode: every .slang under src/shaders. Scenes emit SceneSelected
// (app.odin); shared modules open in the editor.
ui_files_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	// Keep the list fresh (template-created scenes, external files); the
	// rescan is append-only and cheap.
	ui.files_frame += 1
	if ui.files_frame % 120 == 1 {
		ied_rescan(ed)
	}

	active_title := len(sm.scenes) > 0 ? sm.scenes[sm.current].title : ""

	// Only the open scene's files: the unit's entry shader plus its
	// modules (passes). Other scenes switch from the title-bar combo.
	im.TextDisabled(strings_to_c(active_title))
	prefix := fmt.tprintf("scenes/%s/", active_title)
	for f in ed.files {
		if !strings.has_prefix(f, prefix) do continue
		rel := f[len(prefix):]
		label := rel == active_title ? active_title : fmt.tprintf("  %s", rel)
		if im.Selectable(strings_to_c(label), false, {}) {
			ied_load_named(ed, f)
			ed.open = true
		}
	}

	im.Spacing()
	im.TextDisabled(trc("shared"))
	for f in ed.files {
		if strings.has_prefix(f, "scenes/") do continue
		if im.Selectable(strings_to_c(f), false, {}) {
			ied_load_named(ed, f)
			ed.open = true // surface the floating editor on the file
		}
	}
}

// Paper grain behind the panel content: the scanned paper texture, slow
// UV drift, barely-there alpha (fx.grain). Draws into the current window
// (the side panel) before any widgets.
ui_draw_grain :: proc(ui: ^Ui) {
	if !fx_on(&ui.fx) || !ui.fx.grain || fx_grain_binding == nil do return
	dl := im.GetWindowDrawList()
	wp := im.GetWindowPos()
	ws := im.GetWindowSize()
	tex_ref := im.TextureRef {
		_TexID = im.TextureID(uintptr(fx_grain_binding)),
	}
	im.ImDrawList_AddImage(
		dl,
		tex_ref,
		wp,
		{wp.x + ws.x, wp.y + ws.y},
		{f32(im.GetTime()) * 0.002, 0},
		{f32(im.GetTime()) * 0.002 + ws.x / 1024, ws.y / 1024},
		im.GetColorU32Vec4({1, 1, 1, 0.05}),
	)
}

// Panel resize handle: an 8px strip just outside the panel's right edge
// (inside the panel the border pixel belongs to the panel and hover never
// reached the handle). Drag sets ui.user_w: one user width for every
// mode (VS Code behavior). Amber seam while hovering/dragging.
ui_panel_edge :: proc(ui: ^Ui, panel_x: f32) {
	io := im.GetIO()
	im.SetNextWindowPos({panel_x + ui.panel_w.value + 1, TITLEBAR_H}, .Always)
	im.SetNextWindowSize({8, io.DisplaySize.y - TITLEBAR_H}, .Always)
	edge_flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoBackground,
		.NoScrollbar,
		.NoScrollWithMouse,
	}
	// Zero padding: on an 8px window the default 12px padding pushes the
	// button's hit rect out of the strip entirely.
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	if im.Begin("##panel_edge", nil, edge_flags) {
		im.InvisibleButton("##edge_btn", {8, io.DisplaySize.y - TITLEBAR_H})
		edge_hovered := im.IsItemHovered()
		edge_active := im.IsItemActive()
		if edge_hovered || edge_active {
			im.SetMouseCursor(.ResizeEW)
		}
		if edge_active {
			ui.user_w = clamp(
				io.MousePos.x - STRIP_W - ui.sidebar_x.value + 3,
				220,
				io.DisplaySize.x * 0.85,
			)
		}
		if edge_hovered || edge_active {
			dl := im.GetWindowDrawList()
			ex := panel_x + ui.panel_w.value - 0.5
			im.DrawList_AddLine(
				dl,
				{ex, TITLEBAR_H},
				{ex, io.DisplaySize.y},
				im.GetColorU32Vec4({0.91, 0.66, 0.34, 0.8}),
			)
		}
	}
	im.End()
	im.PopStyleVar()
}
