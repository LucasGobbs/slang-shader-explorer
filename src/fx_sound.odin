// Sound effects (the spectacle layer): tiny synthesized WAV blips played
// through macOS afplay: no audio backend, no dependencies, and afplay
// failing (headless, muted) costs nothing because sound is pure feedback.
// Files are synthesized once at startup into the temp dir; playback is
// fire-and-forget with a per-kind throttle so typing/build spam can't
// stack.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"

import "core:time"

FxSfx :: enum {
	SAVE,
	BUILD_OK,
	BUILD_ERROR,
	SCENE_SWITCH,
	EXPORT,
	ZEN,
	TYPE, // soft keyboard click, one of several variants
}

// Points at the app's Fx settings (ui.fx); set once in main.
fx_settings: ^Fx

sfx_last:  [FxSfx]i64 // unix nano of the last play, per kind
sfx_paths: [FxSfx]string

SFX_DIR   :: "/tmp/shader_explorer_sfx"
SFX_RATE  :: 22050
SFX_MIN_MS := [FxSfx]i64 {
	.SAVE         = 80,
	.BUILD_OK     = 400,
	.BUILD_ERROR  = 400,
	.SCENE_SWITCH = 250,
	.EXPORT       = 300,
	.ZEN          = 400,
	.TYPE         = 55,
}

sfx_type_paths: [3]string

sfx_put16 :: proc(data: []u8, off: int, v: u32) {
	data[off] = u8(v)
	data[off + 1] = u8(v >> 8)
}

sfx_put32 :: proc(data: []u8, off: int, v: u32) {
	for k in 0 ..< 4 {
		data[off + k] = u8(v >> (8 * u32(k)))
	}
}

// Minimal 16-bit PCM mono WAV writer.
sfx_write_wav :: proc(path: string, samples: []i16) -> bool {
	data := make([]u8, 44 + len(samples) * 2, context.temp_allocator)
	copy(data[:4], "RIFF")
	sfx_put32(data, 4, u32(len(data) - 8))
	copy(data[8:12], "WAVE")
	copy(data[12:16], "fmt ")
	sfx_put32(data, 16, 16)
	sfx_put16(data, 20, 1) // PCM
	sfx_put16(data, 22, 1) // mono
	sfx_put32(data, 24, SFX_RATE)
	sfx_put32(data, 28, SFX_RATE * 2)
	sfx_put16(data, 32, 2)  // block align
	sfx_put16(data, 34, 16) // bits per sample
	copy(data[36:40], "data")
	sfx_put32(data, 40, u32(len(samples) * 2))
	for s, i in samples {
		sfx_put16(data, 44 + i * 2, u32(u16(s)))
	}
	return os.write_entire_file(path, data) == nil
}

// Sine with exponential decay; f0→f1 sweep when f1 > 0.
sfx_tone :: proc(ms: int, f0, f1: f32, square := false) -> []i16 {
	n := SFX_RATE * ms / 1000
	out := make([]i16, n, context.temp_allocator)
	for i in 0 ..< n {
		t := f32(i) / SFX_RATE
		f := f1 > 0 ? f0 + (f1 - f0) * (f32(i) / f32(n)) : f0
		phase := 2 * math.PI * f * t
		v := square ? (math.sin(phase) >= 0 ? f32(0.5) : f32(-0.5)) : math.sin(phase)
		env := math.exp(-t * (square ? 18.0 : 14.0))
		out[i] = i16(v * env * 24000)
	}
	return out
}

// --- ASMR palette -----------------------------------------------------------
// Nothing here is a bare sine: plucks are Karplus-Strong (marimba/kalimba
// body), clicks and whooshes are one-pole low-passed noise (paper, soft
// keyboard). Slow attacks, rounded releases, modest levels.

// Karplus-Strong pluck: noise-filled delay line, damped feedback. feedback
// closer to 1 rings longer (more guitar), lower is more marimba-thud.
sfx_pluck :: proc(ms: int, freq, feedback: f32) -> []i16 {
	period := max(2, int(f32(SFX_RATE) / freq))
	buf := make([]f32, period, context.temp_allocator)
	for &v in buf do v = rand.float32_range(-1, 1)
	n := SFX_RATE * ms / 1000
	out := make([]i16, n, context.temp_allocator)
	idx := 0
	for i in 0 ..< n {
		cur := buf[idx]
		nxt := buf[(idx + 1) % period]
		v := (cur + nxt) * 0.5 * feedback
		buf[idx] = v
		idx = (idx + 1) % period
		attack := math.min(1, f32(i) / (0.006 * SFX_RATE))
		env := attack * math.exp(-f32(i) / (f32(n) * 0.5))
		out[i] = i16(v * env * 13000)
	}
	return out
}

// One-pole low-passed noise burst: a soft keyboard keypress / paper tap.
sfx_click :: proc(ms: int, cutoff: f32) -> []i16 {
	n := SFX_RATE * ms / 1000
	out := make([]i16, n, context.temp_allocator)
	lp: f32
	attack_n := max(1, n / 6)
	for i in 0 ..< n {
		x := rand.float32_range(-1, 1)
		lp += cutoff * (x - lp)
		env: f32
		if i < attack_n {
			env = f32(i) / f32(attack_n)
		} else {
			env = math.exp(-(f32(i - attack_n) / f32(n)) * 8)
		}
		out[i] = i16(lp * env * 9500)
	}
	return out
}

// Low-passed noise swell with a raised-cosine envelope: a paper whoosh.
sfx_whoosh :: proc(ms: int) -> []i16 {
	n := SFX_RATE * ms / 1000
	out := make([]i16, n, context.temp_allocator)
	lp: f32
	for i in 0 ..< n {
		k := f32(i) / f32(n)
		a := 0.04 + 0.30 * math.sin(math.PI * k) // cutoff opens then closes
		x := rand.float32_range(-1, 1)
		lp += a * (x - lp)
		env := math.sin(math.PI * k)
		out[i] = i16(lp * env * env * 11000)
	}
	return out
}

// Error thud: a heavily damped low pluck plus a quiet low-passed tap.
// Reads as "something didn't take", never as an alarm.
sfx_thud :: proc() -> []i16 {
	pluck := sfx_pluck(320, 110, 0.988)
	tap := sfx_click(90, 0.12)
	n := max(len(pluck), len(tap))
	out := make([]i16, n, context.temp_allocator)
	for i in 0 ..< n {
		a := i < len(pluck) ? pluck[i] : 0
		b := i < len(tap) ? tap[i] : 0
		out[i] = i16(clamp(int(a) + int(b) / 2, -32767, 32767))
	}
	return out
}

sfx_concat :: proc(a, b: []i16) -> []i16 {
	out := make([]i16, len(a) + len(b), context.temp_allocator)
	copy(out[:len(a)], a)
	copy(out[len(a):], b)
	return out
}

// Synthesizes every blip once. Missing dir or write failure just means
// silence for that sound.
fx_sfx_init :: proc() {
	os.make_directory(SFX_DIR)
	emit_wav :: proc(path: string, samples: []i16) {
		if !sfx_write_wav(path, samples) {
			log.errorf("sfx: failed to write %s", path)
		}
	}
	// The ASMR set: kalimba plucks, paper whooshes, soft key clicks.
	emit_wav(SFX_DIR + "/save.wav", sfx_pluck(320, 523.25, 0.9945))          // C5
	emit_wav(SFX_DIR + "/build_ok.wav", sfx_concat(sfx_pluck(160, 523.25, 0.994), sfx_pluck(300, 784.0, 0.995))) // C5 → G5
	emit_wav(SFX_DIR + "/build_error.wav", sfx_thud())
	emit_wav(SFX_DIR + "/scene.wav", sfx_whoosh(220))
	emit_wav(SFX_DIR + "/export.wav", sfx_pluck(450, 1318.5, 0.996))         // E6 shimmer
	emit_wav(SFX_DIR + "/zen.wav", sfx_whoosh(320))
	for v, i in ([3]f32{0.30, 0.22, 0.16}) {
		path := fmt.tprintf("%s/type%d.wav", SFX_DIR, i)
		emit_wav(path, sfx_click(14 + i * 4, v))
		sfx_type_paths[i] = path
	}
	sfx_paths = {
		.SAVE         = SFX_DIR + "/save.wav",
		.BUILD_OK     = SFX_DIR + "/build_ok.wav",
		.BUILD_ERROR  = SFX_DIR + "/build_error.wav",
		.SCENE_SWITCH = SFX_DIR + "/scene.wav",
		.EXPORT       = SFX_DIR + "/export.wav",
		.ZEN          = SFX_DIR + "/zen.wav",
		.TYPE         = "",
	}
}

// Fire-and-forget playback, throttled per kind.
fx_sfx_play :: proc(kind: FxSfx) {
	if fx_settings == nil || !fx_on(fx_settings) || !fx_settings.sound do return
	now := time.to_unix_nanoseconds(time.now())
	if now - sfx_last[kind] < SFX_MIN_MS[kind] * i64(time.Millisecond) do return
	sfx_last[kind] = now
	path := sfx_paths[kind]
	if kind == .TYPE {
		path = sfx_type_paths[rand.int_max(len(sfx_type_paths))]
	}
	if !os.exists(path) do return
	_, err := os.process_start({command = []string{"afplay", path}})
	if err != nil {
		// afplay absent or busy: sound is optional feedback, never fatal.
		log.errorf("sfx: afplay failed: %v", err)
	}
}
