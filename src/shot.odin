package main

import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbiw "vendor:stb/image"

PixelReadback :: struct {
	transfer: ^sdl.GPUTransferBuffer,
	fence:    ^sdl.GPUFence,
	pending:  bool,
	x, y:     i32,
}

pixel_readback_begin :: proc(
	readback: ^PixelReadback,
	gpu: ^sdl.GPUDevice,
	tex: ^sdl.GPUTexture,
	x, y, width, height: i32,
) -> bool {
	if readback.pending || tex == nil || width <= 0 || height <= 0 do return false
	px := clamp(x, 0, width - 1)
	py := clamp(y, 0, height - 1)
	transfer := sdl.CreateGPUTransferBuffer(gpu, {usage = .DOWNLOAD, size = 4})
	if transfer == nil {
		log.errorf("pixel inspector: failed to create transfer buffer: %s", sdl.GetError())
		return false
	}
	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	if cmd == nil {
		log.errorf("pixel inspector: failed to acquire command buffer: %s", sdl.GetError())
		sdl.ReleaseGPUTransferBuffer(gpu, transfer)
		return false
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(
		copy_pass,
		{texture = tex, x = u32(px), y = u32(py), z = 0, w = 1, h = 1, d = 1},
		{transfer_buffer = transfer, offset = 0, pixels_per_row = 1, rows_per_layer = 1},
	)
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		log.errorf("pixel inspector: failed to submit readback: %s", sdl.GetError())
		sdl.ReleaseGPUTransferBuffer(gpu, transfer)
		return false
	}
	readback.transfer = transfer
	readback.fence = fence
	readback.pending = true
	readback.x, readback.y = px, py
	return true
}

pixel_readback_poll :: proc(
	readback: ^PixelReadback,
	gpu: ^sdl.GPUDevice,
) -> (rgba: [4]f32, x, y: i32, ready: bool) {
	if !readback.pending || !sdl.QueryGPUFence(gpu, readback.fence) do return
	ptr := sdl.MapGPUTransferBuffer(gpu, readback.transfer, false)
	if ptr == nil {
		log.errorf("pixel inspector: failed to map readback: %s", sdl.GetError())
	} else {
		bytes := ([^]u8)(ptr)
		for i in 0 ..< 4 do rgba[i] = f32(bytes[i]) / 255.0
		sdl.UnmapGPUTransferBuffer(gpu, readback.transfer)
		ready = true
		x, y = readback.x, readback.y
	}
	sdl.ReleaseGPUFence(gpu, readback.fence)
	sdl.ReleaseGPUTransferBuffer(gpu, readback.transfer)
	readback^ = {}
	return
}

pixel_readback_cancel :: proc(readback: ^PixelReadback, gpu: ^sdl.GPUDevice) {
	if !readback.pending do return
	_ = sdl.WaitForGPUFences(gpu, true, &readback.fence, 1)
	sdl.ReleaseGPUFence(gpu, readback.fence)
	sdl.ReleaseGPUTransferBuffer(gpu, readback.transfer)
	readback^ = {}
}

PassPixelReadback :: struct {
	items: [DEBUG_WATCH_MAX_PASSES]PixelReadback,
	rgba:  [DEBUG_WATCH_MAX_PASSES][4]f32,
	valid: [DEBUG_WATCH_MAX_PASSES]bool,
	count: int,
	pending: bool,
}

pass_pixel_readback_cancel :: proc(readback: ^PassPixelReadback, gpu: ^sdl.GPUDevice) {
	for &item in readback.items do if item.pending do pixel_readback_cancel(&item, gpu)
	readback^ = {}
}

pass_pixel_readback_begin :: proc(
	readback: ^PassPixelReadback,
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	res: ^SceneResources,
	x, y, width, height: i32,
) -> bool {
	if readback.pending do pass_pixel_readback_cancel(readback, gpu)
	readback.count = min(len(scene.passes), DEBUG_WATCH_MAX_PASSES)
	started := false
	for i in 0 ..< readback.count {
		tex := scene_pass_texture(scene, scene_tex, res, i)
		if pixel_readback_begin(&readback.items[i], gpu, tex, x, y, width, height) {
			started = true
		}
	}
	readback.pending = started
	return started
}

pass_pixel_readback_poll :: proc(readback: ^PassPixelReadback, gpu: ^sdl.GPUDevice) -> (changed, complete: bool) {
	if !readback.pending do return
	still_pending := false
	for i in 0 ..< readback.count {
		if !readback.items[i].pending do continue
		rgba, _, _, ready := pixel_readback_poll(&readback.items[i], gpu)
		if ready {
			readback.rgba[i] = rgba
			readback.valid[i] = true
			changed = true
		}
		still_pending |= readback.items[i].pending
	}
	readback.pending = still_pending
	complete = !still_pending
	return
}

DEBUG_WATCH_COUNT :: 8
DEBUG_WATCH_MAX_PASSES :: 16
DEBUG_WATCH_RECORD_COUNT :: DEBUG_WATCH_COUNT * DEBUG_WATCH_MAX_PASSES
DEBUG_WATCH_RECORD_SIZE :: 32
DEBUG_WATCH_BUFFER_SIZE :: DEBUG_WATCH_RECORD_COUNT * DEBUG_WATCH_RECORD_SIZE

DebugWatchSample :: struct {
	valid: bool,
	type:  u32,
	count: u32,
	pass:  u32,
	value: [4]f32,
}

DebugWatchReadback :: struct {
	transfer: ^sdl.GPUTransferBuffer,
	fence: ^sdl.GPUFence,
	frame_id: u32,
	pending: bool,
}

debug_watch_readback_begin :: proc(
	readback: ^DebugWatchReadback,
	gpu: ^sdl.GPUDevice,
	buffer: ^sdl.GPUBuffer,
	frame_id: u32,
) -> bool {
	if readback.pending || buffer == nil do return false
	transfer := sdl.CreateGPUTransferBuffer(gpu, {usage = .DOWNLOAD, size = DEBUG_WATCH_BUFFER_SIZE})
	if transfer == nil {
		log.errorf("debug watches: failed to create transfer buffer: %s", sdl.GetError())
		return false
	}
	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	if cmd == nil {
		log.errorf("debug watches: failed to acquire command buffer: %s", sdl.GetError())
		sdl.ReleaseGPUTransferBuffer(gpu, transfer)
		return false
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUBuffer(
		copy_pass,
		{buffer = buffer, offset = 0, size = DEBUG_WATCH_BUFFER_SIZE},
		{transfer_buffer = transfer, offset = 0},
	)
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		log.errorf("debug watches: failed to submit readback: %s", sdl.GetError())
		sdl.ReleaseGPUTransferBuffer(gpu, transfer)
		return false
	}
	readback.transfer = transfer
	readback.fence = fence
	readback.frame_id = frame_id
	readback.pending = true
	return true
}

debug_watch_readback_poll :: proc(
	readback: ^DebugWatchReadback,
	gpu: ^sdl.GPUDevice,
) -> (samples: [DEBUG_WATCH_RECORD_COUNT]DebugWatchSample, ready: bool) {
	if !readback.pending || !sdl.QueryGPUFence(gpu, readback.fence) do return
	ptr := sdl.MapGPUTransferBuffer(gpu, readback.transfer, false)
	if ptr == nil {
		log.errorf("debug watches: failed to map readback: %s", sdl.GetError())
	} else {
		base := uintptr(ptr)
		for i in 0 ..< DEBUG_WATCH_RECORD_COUNT {
			offset := uintptr(i * DEBUG_WATCH_RECORD_SIZE)
			frame_id := (^u32)(rawptr(base + offset + 0))^
			if frame_id != readback.frame_id do continue
			samples[i].valid = true
			samples[i].type = (^u32)(rawptr(base + offset + 4))^
			samples[i].count = (^u32)(rawptr(base + offset + 8))^
			samples[i].pass = (^u32)(rawptr(base + offset + 12))^
			for c in 0 ..< 4 {
				samples[i].value[c] = (^f32)(rawptr(base + offset + uintptr(16 + c*4)))^
			}
		}
		sdl.UnmapGPUTransferBuffer(gpu, readback.transfer)
		ready = true
	}
	sdl.ReleaseGPUFence(gpu, readback.fence)
	sdl.ReleaseGPUTransferBuffer(gpu, readback.transfer)
	readback^ = {}
	return
}

debug_watch_readback_cancel :: proc(readback: ^DebugWatchReadback, gpu: ^sdl.GPUDevice) {
	if !readback.pending do return
	_ = sdl.WaitForGPUFences(gpu, true, &readback.fence, 1)
	sdl.ReleaseGPUFence(gpu, readback.fence)
	sdl.ReleaseGPUTransferBuffer(gpu, readback.transfer)
	readback^ = {}
}

// exports/<title>_YYYY-MM-DD_HH-MM-SS.<ext>: one file per export, so the
// exports/ folder keeps the full export history. Creates exports/ on demand.
// Timestamp is local time (libc localtime/strftime).
export_path :: proc(title, ext: string) -> string {
	os.make_directory("exports") // fine if it already exists
	now := libc.time(nil)
	buf: [64]u8
	n := libc.strftime(raw_data(buf[:]), len(buf), "%Y-%m-%d_%H-%M-%S", libc.localtime(&now))
	return fmt.tprintf("exports/%s_%s.%s", title, string(buf[:n]), ext)
}

// Frame export: `--shot out.png` renders one frame of the current scene,
// downloads the offscreen texture, and writes
// it as a PNG (stb_image_write), then exits.

// Downloads `tex` and saves it as RGBA8 PNG. The texture must have been
// submitted in an earlier command buffer (the scene compute pass).
save_texture_png :: proc(
	gpu: ^sdl.GPUDevice,
	tex: ^sdl.GPUTexture,
	width, height: i32,
	path: string,
) -> bool {
	size := u32(width) * u32(height) * 4
	tbuf := sdl.CreateGPUTransferBuffer(gpu, {usage = .DOWNLOAD, size = size})
	if tbuf == nil {
		log.error("shot: failed to create download transfer buffer")
		return false
	}
	defer sdl.ReleaseGPUTransferBuffer(gpu, tbuf)

	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(
		copy_pass,
		{texture = tex, x = 0, y = 0, z = 0, w = u32(width), h = u32(height), d = 1},
		{
			transfer_buffer = tbuf,
			offset = 0,
			pixels_per_row = u32(width),
			rows_per_layer = u32(height),
		},
	)
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		log.error("shot: failed to submit download")
		return false
	}
	defer sdl.ReleaseGPUFence(gpu, fence)
	if !sdl.WaitForGPUFences(gpu, true, &fence, 1) {
		log.error("shot: fence wait failed")
		return false
	}

	ptr := sdl.MapGPUTransferBuffer(gpu, tbuf, false)
	if ptr == nil {
		log.error("shot: failed to map transfer buffer")
		return false
	}
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	ok := stbiw.write_png(path_c, width, height, 4, ptr, width * 4) != 0
	sdl.UnmapGPUTransferBuffer(gpu, tbuf)
	if !ok {
		log.errorf("shot: failed to write %s", path)
		return false
	}
	log.infof("shot: wrote %s (%dx%d)", path, width, height)
	return true
}
