package main

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import sdl "vendor:sdl3"

// Frame export for the inktober campaign: `--shot out.png` renders one
// frame of the current scene, downloads the offscreen texture, and writes
// it as a PNG, then exits. PNG is written uncompressed (zlib stored
// blocks): no encoder dependency, still readable everywhere.

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
	pixels := mem.slice_ptr((^u8)(ptr), int(size))
	ok := write_png(path, pixels, int(width), int(height))
	sdl.UnmapGPUTransferBuffer(gpu, tbuf)
	return ok
}

be32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

png_chunk :: proc(buf: ^[dynamic]u8, type: string, data: []u8) {
	be32(buf, u32(len(data)))
	type_start := len(buf)
	append(buf, type[0], type[1], type[2], type[3])
	append(buf, ..data)
	// CRC covers type + data, which are contiguous in buf now.
	be32(buf, hash.crc32(buf[type_start:]))
}

adler32 :: proc(data: []u8) -> u32 {
	// Largest n such that 255n(n+1)/2 + (n+1)(65520) fits in u32.
	NMAX :: 5552
	a: u32 = 1
	b: u32 = 0
	pos := 0
	for pos < len(data) {
		n := min(NMAX, len(data) - pos)
		for i in pos ..< pos + n {
			a += u32(data[i])
			b += a
		}
		a %= 65521
		b %= 65521
		pos += n
	}
	return b << 16 | a
}

// Uncompressed PNG: filter 0 rows inside a zlib stream of stored blocks.
write_png :: proc(path: string, rgba: []u8, width, height: int) -> bool {
	row := width * 4
	raw: [dynamic]u8
	defer delete(raw)
	reserve(&raw, (row + 1) * height)
	for y in 0 ..< height {
		append(&raw, 0)
		append(&raw, ..rgba[y * row:(y + 1) * row])
	}

	z: [dynamic]u8
	defer delete(z)
	append(&z, 0x78, 0x01) // zlib header: deflate, no preset dictionary
	pos := 0
	for pos < len(raw) {
		n := min(65535, len(raw) - pos)
		append(&z, u8(pos + n == len(raw) ? 1 : 0))
		append(&z, u8(n), u8(n >> 8), u8(~n), u8(~n >> 8))
		append(&z, ..raw[pos:pos + n])
		pos += n
	}
	be32(&z, adler32(raw[:]))

	out: [dynamic]u8
	defer delete(out)
	append(&out, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n')
	ihdr: [13]u8
	ihdr[0] = u8(width >> 24); ihdr[1] = u8(width >> 16); ihdr[2] = u8(width >> 8); ihdr[3] = u8(width)
	ihdr[4] = u8(height >> 24); ihdr[5] = u8(height >> 16); ihdr[6] = u8(height >> 8); ihdr[7] = u8(height)
	ihdr[8] = 8  // bit depth
	ihdr[9] = 6  // color type: RGBA
	png_chunk(&out, "IHDR", ihdr[:])
	png_chunk(&out, "IDAT", z[:])
	png_chunk(&out, "IEND", {})

	if err := os.write_entire_file(path, out[:]); err != nil {
		fmt.eprintfln("shot: failed to write %s: %v", path, err)
		return false
	}
	fmt.printfln("shot: wrote %s (%dx%d)", path, width, height)
	return true
}
