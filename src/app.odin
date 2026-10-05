// Application architecture, incremental Elm style: everything that can
// happen to the app is a Msg, every Msg is applied in exactly one place
// (update), and the view (ui_build, the main loop) emits messages instead
// of mutating state. Effects that touch the OS, the filesystem, or the
// GPU are described as Cmd values and executed by the interpreter in
// main.odin: widgets and editor code never call SDL/OS directly for
// actions. GPU pipelines, scene runtime, and ImGui are untouched: this
// layer is about data flow, not rendering.
//
// Adding a feature: new Msg variant + one case in update + view code
// emitting it. State changes live only here.
package main

import im "../vendor/odin-imgui"
import sdl "vendor:sdl3"

// Union variants in Odin are types, declared before the union.
SceneSelected   :: int
SetMode         :: SidebarMode
TogglePanel     :: struct {}
ToggleZen       :: struct {} // SPACE: sidebar AND editor
ToggleSidebar   :: struct {} // Cmd+B: sidebar only
ToggleTheater   :: struct {} // F3
ToggleMobile    :: struct {} // F4: 9:16 portrait recording mode
SetFxIntensity  :: FxIntensity
ToggleFx        :: FxKind
SaveAll         :: struct {}
ExportRequested :: ExportAction
Quit            :: struct {}
WindowMinimize  :: struct {}
WindowFullscreen :: struct {} // green traffic light: true macOS fullscreen
DevelopPreview  :: struct {} // EFFECTS panel preview button

ExportAction :: struct {
	kind: ExportRequest,
	at:   [2]f32, // burst origin (the button's center)
}

Msg :: union {
	SceneSelected,
	SetMode,
	TogglePanel,
	ToggleZen,
	ToggleSidebar,
	ToggleTheater,
	ToggleMobile,
	SetFxIntensity,
	ToggleFx,
	SaveAll,
	ExportRequested,
	Quit,
	WindowMinimize,
	WindowFullscreen,
	DevelopPreview,
}

FxKind :: enum {
	DEVELOP,
	PARTICLES,
	SPRINGS,
	GRAIN,
	SOUND,
}

// Effects the interpreter (main.odin) executes. Pure state changes
// happen inside update; anything that touches the OS, files, or GPU is
// one of these.
Cmd :: enum {
	QUIT,
	MINIMIZE,
	FULLSCREEN_ON,
	FULLSCREEN_OFF,
	MOBILE_ENTER,
	MOBILE_EXIT,
	SAVE_ALL,
	EXPORT_PNG,
	EXPORT_GIF,
	DEVELOP,
}
Cmds :: bit_set[Cmd]

// The application state owners. update mutates through these pointers;
// nothing else does for message-shaped flows.
App :: struct {
	ui:  ^Ui,
	sm:  ^SceneManager,
	ed:  ^ImGuiEditor,
	ing: ^NodeGraph,
	win: ^sdl.Window,
}

// Bounded per-frame queue: widgets emit during ui_build, main drains
// right after. 64 messages per frame is far beyond real usage.
MSG_CAP :: 64
msg_buf:   [MSG_CAP]Msg
msg_count: int

emit :: proc(msg: Msg) {
	if msg_count >= MSG_CAP do return
	msg_buf[msg_count] = msg
	msg_count += 1
}

// Applies one message. The ONLY place message-shaped state changes.
// Returns the effects for the interpreter to execute.
update :: proc(app: ^App, msg: Msg) -> Cmds {
	cmds: Cmds
	switch m in msg {
	case SceneSelected:
		if m >= 0 && m < len(app.sm.scenes) {
			app.sm.current = m
		}
	case SetMode:
		app.ui.mode = m
		app.ui.panel_open = true
	case TogglePanel:
		app.ui.panel_open = !app.ui.panel_open
	case ToggleZen:
		app.ui.open = !app.ui.open
		app.ed.open = app.ui.open
		fx_sfx_play(.ZEN)
	case ToggleSidebar:
		app.ui.open = !app.ui.open
	case ToggleTheater:
		ui := app.ui
		if !ui.theater {
			ui.theater = true
			ui.saved_ui_font = ui.font_size
			ui.saved_ed_font = app.ed.font_size
			ui.saved_open = ui.open
			ui.saved_ed_open = app.ed.open
			ui.font_size = 18
			im.GetStyle().FontSizeBase = 18
			app.ed.font_size = 21
			ui.open = false // zen slide hides the sidebar
			app.ed.open = true
			app.ed.moved = false // theater docks the editor again
		} else {
			ui.theater = false
			ui.font_size = ui.saved_ui_font
			im.GetStyle().FontSizeBase = ui.saved_ui_font
			app.ed.font_size = ui.saved_ed_font
			ui.open = ui.saved_open
			app.ed.open = ui.saved_ed_open
		}
	case ToggleMobile:
		// Mobile theater: 9:16 portrait window for vertical recordings
		// (TikTok/Instagram). NOT a mobile app: the window just takes
		// phone dimensions so the capture crops cleanly. Sidebar hides,
		// the editor docks to the bottom half, type grows (like F3).
		ui := app.ui
		if !ui.mobile {
			ui.mobile = true
			mobile_theater = true
			ui.mobile_saved_ui_font = ui.font_size
			ui.mobile_saved_ed_font = app.ed.font_size
			ui.mobile_saved_open = ui.open
			ui.mobile_saved_ed_open = app.ed.open
			ui.font_size = 18
			im.GetStyle().FontSizeBase = 18
			app.ed.font_size = 21
			ui.open = false
			app.ed.open = true
			app.ed.moved = false // the bottom dock wins in this mode
			cmds += {.MOBILE_ENTER}
		} else {
			ui.mobile = false
			mobile_theater = false
			ui.font_size = ui.mobile_saved_ui_font
			im.GetStyle().FontSizeBase = ui.mobile_saved_ui_font
			app.ed.font_size = ui.mobile_saved_ed_font
			ui.open = ui.mobile_saved_open
			app.ed.open = ui.mobile_saved_ed_open
			app.ed.moved = false
			cmds += {.MOBILE_EXIT}
		}
	case SetFxIntensity:
		app.ui.fx.intensity = m
	case ToggleFx:
		switch m {
		case .DEVELOP:
			app.ui.fx.develop = !app.ui.fx.develop
		case .PARTICLES:
			app.ui.fx.particles = !app.ui.fx.particles
		case .SPRINGS:
			app.ui.fx.springs = !app.ui.fx.springs
		case .GRAIN:
			app.ui.fx.grain = !app.ui.fx.grain
		case .SOUND:
			app.ui.fx.sound = !app.ui.fx.sound
		}
	case SaveAll:
		cmds += {.SAVE_ALL}
	case ExportRequested:
		// The burst is pure FX state; the file write is a Cmd.
		n := 70 if m.kind == .GIF else 50
		speed := f32(230) if m.kind == .GIF else f32(200)
		fx_burst(&app.ui.fx, m.at, n, 24, speed)
		if m.kind == .GIF {
			cmds += {.EXPORT_GIF}
		} else {
			cmds += {.EXPORT_PNG}
		}
	case Quit:
		cmds += {.QUIT}
	case WindowMinimize:
		cmds += {.MINIMIZE}
	case WindowFullscreen:
		if .FULLSCREEN in sdl.GetWindowFlags(app.win) {
			cmds += {.FULLSCREEN_OFF}
		} else {
			cmds += {.FULLSCREEN_ON}
		}
	case DevelopPreview:
		cmds += {.DEVELOP}
	}
	return cmds
}
