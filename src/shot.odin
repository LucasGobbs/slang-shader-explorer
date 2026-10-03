package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbiw "vendor:stb/image"

// exports/<title>_YYYY-MM-DD_HH-MM-SS.<ext> — one file per export, so the
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
		fmt.eprintln("shot: failed to create download transfer buffer")
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
		fmt.eprintln("shot: failed to submit download")
		return false
	}
	defer sdl.ReleaseGPUFence(gpu, fence)
	if !sdl.WaitForGPUFences(gpu, true, &fence, 1) {
		fmt.eprintln("shot: fence wait failed")
		return false
	}

	ptr := sdl.MapGPUTransferBuffer(gpu, tbuf, false)
	if ptr == nil {
		fmt.eprintln("shot: failed to map transfer buffer")
		return false
	}
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	ok := stbiw.write_png(path_c, width, height, 4, ptr, width * 4) != 0
	sdl.UnmapGPUTransferBuffer(gpu, tbuf)
	if !ok {
		fmt.eprintfln("shot: failed to write %s", path)
		return false
	}
	fmt.printfln("shot: wrote %s (%dx%d)", path, width, height)
	return true
}
