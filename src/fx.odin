// Overdrive FX layer: motion primitives and ink particles. Everything is
// bound to artefacts/DESIGN.md — the safelight amber is the only hue, motion is
// damped ease-out, and intensity .OFF is a clean static fallback (no
// animation, no particles, hard scene cuts, as if the layer didn't exist).
package main

import im "../vendor/odin-imgui"
import "core:math"
import "core:math/rand"

FxIntensity :: enum {
	FULL,
	SUBTLE,
	OFF,
}

FX_INTENSITY_NAMES := [FxIntensity]string {
	.FULL   = "full",
	.SUBTLE = "subtle",
	.OFF    = "off (static)",
}

FxDevelopStyle :: enum {
	RANDOM,   // every scene switch picks one at random
	DEVELOP,  // photo-develop luminance bath
	DISSOLVE, // ordered-dither pixel dissolve
	IRIS,     // circular iris from the scene selector
}

FX_DEVELOP_STYLE_NAMES := [FxDevelopStyle]string {
	.RANDOM   = "random",
	.DEVELOP  = "develop",
	.DISSOLVE = "dissolve",
	.IRIS     = "iris",
}

Fx :: struct {
	intensity:     FxIntensity,
	develop:       bool, // darkroom "develop" transition on scene switch
	develop_style: FxDevelopStyle,
	particles:     bool, // ink motes on events (save, export, scene switch)
	springs:       bool, // animated selection pill, fades
	grain:         bool, // paper grain behind panels
	sound:         bool, // afplay blips on save, build, scene switch, export
}

fx_defaults :: proc() -> Fx {
	return Fx {
		intensity = .FULL,
		develop   = true,
		particles = true,
		springs   = true,
		grain     = true,
		sound     = true,
		develop_style = .RANDOM,
	}
}

fx_on :: proc(fx: ^Fx) -> bool {
	return fx.intensity != .OFF
}

// (Develop previews are DevelopPreview messages routed through update —
// see app.odin.)

// The paper texture (SDL_GPUTexture*), set by main after asset load; the
// panels sample it for the grain background. rawptr here keeps fx.odin
// free of the SDL import.
fx_grain_binding: rawptr

// --- Spring ---------------------------------------------------------------

Anim :: struct {
	value, target: f32,
}

// Damped approach with ease-out feel: fast at FULL, softer at SUBTLE,
// snapping when springs or the whole layer are off.
anim_step :: proc(a: ^Anim, target: f32, dt: f32, fx: ^Fx) {
	a.target = target
	if !fx_on(fx) || !fx.springs {
		a.value = target
		return
	}
	rate := f32(14) if fx.intensity == .FULL else f32(8)
	a.value += (a.target - a.value) * (1 - math.exp(-rate * dt))
}

// --- Ink particles ----------------------------------------------------------
// Small CPU pool drawn on the foreground draw list. Three kinds: MOTE
// (event bursts, the classic ink scatter), TRAIL (soft faint motes that
// follow the cursor and dragged nodes), RING (expanding circle outline,
// for build-ok celebrations). TRAIL is deliberately quiet — it must read
// as texture, not as fireworks.

FxParticleKind :: enum {
	MOTE,
	TRAIL,
	RING,
}

FX_MAX_PARTICLES :: 384

FxParticle :: struct {
	pos, vel:  [2]f32,
	life, max: f32,
	size:      f32,
	shade:     u8, // MOTE only: 0 safelight, 1 light, 2 deep
	kind:      FxParticleKind,
	col:       u32, // 0 = use the shade palette (MOTE)
}

fx_particles: [FX_MAX_PARTICLES]FxParticle
fx_alive:     int // live prefix of fx_particles (swap-remove keeps it dense)

fx_last_mouse: [2]f32 // cursor trail tracking (ui.odin)

// Celebration ring origin for build-ok (scene_runtime.odin): the title
// bar's scene selector center, refreshed each frame by ui_chrome.odin.
fx_celebrate_pos: [2]f32

// Scatter n motes from a point. spread: initial radius; speed: initial
// velocity scale. No-op when particles or the layer are off.
fx_burst :: proc(fx: ^Fx, at: [2]f32, n: int, spread, speed: f32) {
	if !fx_on(fx) || !fx.particles do return
	count := n
	if fx.intensity == .SUBTLE do count = max(4, n / 3)
	for _ in 0 ..< count {
		if fx_alive >= FX_MAX_PARTICLES do return
		a := rand.float32_range(0, 2 * math.PI)
		r := rand.float32_range(0, spread)
		s := rand.float32_range(0.3, 1) * speed
		life := rand.float32_range(0.5, 1.1)
		fx_particles[fx_alive] = FxParticle {
			pos   = {at.x + math.cos(a) * r, at.y + math.sin(a) * r},
			vel   = {math.cos(a) * s, math.sin(a) * s - speed * 0.35},
			life  = life,
			max   = life,
			size  = rand.float32_range(1.2, 3.2),
			shade = u8(rand.int_max(3)),
		}
		fx_alive += 1
	}
}

fx_particles_step :: proc(dt: f32) {
	for i := 0; i < fx_alive; {
		p := &fx_particles[i]
		p.life -= dt
		if p.life <= 0 {
			// Swap-remove with the last live particle.
			fx_alive -= 1
			fx_particles[i] = fx_particles[fx_alive]
			continue
		}
		// Drag + a gentle upward ink drift.
		damp := math.exp(-2.6 * dt)
		p.vel *= damp
		p.vel.y -= 26 * dt
		p.pos += p.vel * dt
		i += 1
	}
}

FX_SHADES := [3]im.Vec4 {
	{0.91, 0.66, 0.34, 1}, // safelight amber
	{0.95, 0.75, 0.47, 1}, // light amber
	{0.76, 0.56, 0.28, 1}, // deep amber
}

// One particle into the pool (shared by bursts, trails, rings).
fx_spawn :: proc(p: FxParticle) {
	if fx_alive >= FX_MAX_PARTICLES do return
	fx_particles[fx_alive] = p
	fx_alive += 1
}

// Ring pulse: an expanding circle outline that fades as it grows (build
// celebration, scene milestones).
fx_ring :: proc(fx: ^Fx, at: [2]f32, col: u32 = 0) {
	if !fx_on(fx) || !fx.particles do return
	fx_spawn(FxParticle{pos = at, life = 0.8, max = 0.8, size = 14, kind = .RING, col = col})
}

// Soft trail mote: short-lived, low alpha, drifts up gently.
fx_trail :: proc(fx: ^Fx, at: [2]f32, col: u32 = 0) {
	if !fx_on(fx) || !fx.particles do return
	life := rand.float32_range(0.35, 0.7)
	fx_spawn(
		FxParticle {
			pos  = {at.x + rand.float32_range(-2, 2), at.y + rand.float32_range(-2, 2)},
			vel  = {rand.float32_range(-6, 6), rand.float32_range(-18, -4)},
			life = life,
			max  = life,
			size = rand.float32_range(1.4, 2.8),
			kind = .TRAIL,
			col  = col,
		},
	)
}

fx_particles_draw :: proc(dl: ^im.DrawList) {
	for i in 0 ..< fx_alive {
		p := &fx_particles[i]
		k := p.life / p.max
		switch p.kind {
		case .MOTE:
			col := FX_SHADES[p.shade]
			col.w = k * k * 0.85 // quadratic fade keeps mid-life present
			im.DrawList_AddCircleFilled(dl, {p.pos.x, p.pos.y}, p.size * (0.5 + 0.5 * k), im.GetColorU32Vec4(col))
		case .TRAIL:
			col := im.GetColorU32(.Text, 0.5 * k) if p.col == 0 else p.col
			if p.col != 0 {
				col = (col & 0x00FFFFFF) | (u32(0.65 * k * 255) << 24)
			}
			im.DrawList_AddCircleFilled(dl, {p.pos.x, p.pos.y}, p.size * k, col)
		case .RING:
			col := FX_SHADES[0]
			if p.col != 0 {
				col = {f32(p.col & 0xFF) / 255, f32(p.col >> 8 & 0xFF) / 255, f32(p.col >> 16 & 0xFF) / 255, 1}
			}
			col.w = (1 - k) * 0.8
			im.DrawList_AddCircle(dl, {p.pos.x, p.pos.y}, p.size + (1 - k) * 80, im.GetColorU32Vec4(col), 0, 1.4)
		}
	}
}
