package main

// User-facing error/notice toasts, drawn top-right under the title bar.
// Replaces fatal error paths (SDL asserts, build failures) with visible
// notifications: the app keeps running, the user sees what happened.
// Duplicate messages within a short window refresh the existing toast
// instead of flooding (a per-frame SDL validation error would otherwise
// spawn 60 toasts a second).
import im "../vendor/odin-imgui"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

NotifyKind :: enum {
	INFO,
	WARN,
	ERROR,
}

Notice :: struct {
	text: string, // owned
	kind: NotifyKind,
	age:  f32,
	hits: int, // repeated occurrences folded into this toast
}

NOTIFY_LIFETIME :: f32(7.0)
NOTIFY_FADE :: f32(0.6)
NOTIFY_DEDUP_WINDOW :: f32(2.0)
NOTIFY_MAX :: 5

notices: [dynamic]Notice
notify_mu: sync.Mutex

// Saved main-thread context for the SDL assertion callback (a "c" proc
// on an arbitrary thread).
g_sdl_context: runtime.Context

notify :: proc(kind: NotifyKind, fmt_str: string, args: ..any) {
	sync.mutex_lock(&notify_mu)
	defer sync.mutex_unlock(&notify_mu)
	text := fmt.tprintf(fmt_str, ..args)
	// Dedupe: same text seen recently -> refresh and count, no new card.
	for &n in notices {
		if n.text == text && n.age < NOTIFY_DEDUP_WINDOW {
			n.age = 0
			n.hits += 1
			return
		}
	}
	append(&notices, Notice{text = strings.clone(text), kind = kind})
	for len(notices) > NOTIFY_MAX {
		delete(notices[0].text)
		ordered_remove(&notices, 0)
	}
}

// Packs a color WITHOUT the style alpha that im.GetColorU32Vec4 bakes
// in: toasts must stay opaque regardless of surrounding panel state.
ncol :: proc(r, g, b, a: f32) -> u32 {
	ci :: proc(v: f32) -> u32 {
		return u32(clamp(v, 0, 1) * 255 + 0.5)
	}
	return ci(a) << 24 | ci(b) << 16 | ci(g) << 8 | ci(r)
}

// Toast colors follow the darkroom palette: amber accent for warnings,
// signal red for errors, neutral text for info.
notify_kind_color :: proc(kind: NotifyKind) -> im.Vec4 {
	switch kind {
	case .INFO:
		return {0.62, 0.76, 0.95, 1}
	case .WARN:
		return {0.91, 0.66, 0.34, 1}
	case .ERROR:
		return {0.95, 0.42, 0.36, 1}
	}
	return {1, 1, 1, 1}
}

// Foreground overlay, called once per frame after all windows. Cards
// slide in from the right, hold, then fade; a click dismisses.
notify_draw :: proc(dt: f32) {
	sync.mutex_lock(&notify_mu)
	defer sync.mutex_unlock(&notify_mu)
	if len(notices) == 0 do return
	io := im.GetIO()
	dl := im.GetForegroundDrawList()
	w := f32(340)
	pad := f32(10)
	x1 := io.DisplaySize.x - w - 12
	y := f32(TITLEBAR_H + 10)
	for i := len(notices) - 1; i >= 0; i -= 1 {
		n := &notices[i]
		n.age += dt
		if n.age >= NOTIFY_LIFETIME {
			delete(n.text)
			ordered_remove(&notices, i)
			continue
		}
		// Entrance slide (first 0.25s) and exit fade (last NOTIFY_FADE).
		slide := min(n.age / 0.25, 1)
		xoff := (1 - slide * slide) * 40
		alpha := 1 - math.smoothstep(NOTIFY_LIFETIME - NOTIFY_FADE, NOTIFY_LIFETIME, n.age)
		idx := f32(len(notices) - 1 - i) // stack order: newest at top
		h := pad * 2 + im.GetTextLineHeight() * 1.15
		cy := y + idx * (h + 8)
		min_p := im.Vec2{x1 + xoff, cy}
		max_p := im.Vec2{x1 + w + xoff, cy + h}
		// Click to dismiss.
		mouse := io.MousePos
		if io.MouseClicked[0] &&
		   mouse.x >= min_p.x && mouse.x <= max_p.x &&
		   mouse.y >= min_p.y && mouse.y <= max_p.y {
			delete(n.text)
			ordered_remove(&notices, i)
			continue
		}
		accent := notify_kind_color(n.kind)
		im.DrawList_AddRectFilled(dl, min_p, max_p, ncol(0.09, 0.09, 0.10, alpha), 6)
		// Accent bar: square corners, clipped inside the card's rounding.
		im.DrawList_AddRectFilled(
			dl,
			min_p,
			{min_p.x + 3, max_p.y},
			ncol(accent.x, accent.y, accent.z, alpha),
		)
		label := n.text
		if n.hits > 1 {
			label = fmt.tprintf("%s (×%d)", n.text, n.hits)
		}
		im.DrawList_AddText(
			dl,
			{min_p.x + pad + 4, min_p.y + pad - 1},
			ncol(0.92, 0.92, 0.92, alpha),
			strings_to_c(label),
		)
	}
}

// SDL assertion handler: validation errors (bad bindings, invalid state)
// become error toasts instead of the abort dialog. The app keeps running
// with the previous frame's state; the log keeps the full condition.
sdl_assert_notify :: proc "c" (data: ^sdl.AssertData, userdata: rawptr) -> sdl.AssertState {
	context = g_sdl_context
	cond := string(data.condition)
	file := string(data.filename)
	log.errorf("SDL assert: %s (%s:%s:%d, ×%d)", cond, file, string(data.function), data.linenum, data.trigger_count)
	notify(.ERROR, "GPU: %s", cond)
	return .IGNORE
}
