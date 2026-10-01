package main

import shader_glue "./generated"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"
import mu "vendor:microui"
import goose_sdl "../vendor/goose/src/adapters"

// Minimal overlay UI on top of the scene pass: microui builds the widgets
// (sliders for the FBM uniforms, scene buttons, pause), this renderer turns
// microui's draw commands into textured quads drawn by src/shaders/ui.slang
// in a second render pass with load_op = .LOAD.
//
// microui works in window points (same units as SDL mouse events); all
// geometry is scaled to pixels when vertices are emitted, so the overlay is
// crisp on Retina displays.

UI_VERTEX_CAPACITY :: 16384

UiVertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

UiSegment :: struct {
	first: u32,
	count: u32,
	clip:  sdl.Rect, // pixels
}

UiParams :: struct {
	octaves:      f32,
	lacunarity:   f32,
	gain:         f32,
	paused:       bool,
	color:        bool,
	view3d:       bool, // false = flat blit, true = 3D heightfield view
}

Ui :: struct {
	ctx:           mu.Context,
	pipeline:      ^sdl.GPUGraphicsPipeline,
	atlas:         ^sdl.GPUTexture,
	sampler:       ^sdl.GPUSampler,
	vertex_buffer: ^sdl.GPUBuffer,
	transfer:      ^sdl.GPUTransferBuffer,
	params:        UiParams,
	scene_request: int,
	// True while the mouse is over a UI window or a widget owns the drag;
	// the shader click (iMouse.z) must ignore those clicks.
	captures_mouse: bool,
	gen_ms:        f32, // average compute texture generation time, fed by main
	scale:         f32, // pixels per window point, set each frame
	verts:         [dynamic]UiVertex,
	segments:      [dynamic]UiSegment,
}

// Ui is large (microui Context is ~270KB), so it lives on the heap.
ui_init :: proc(gpu: ^sdl.GPUDevice, window: ^sdl.Window) -> ^Ui {
	ui := new(Ui)
	ui.params = {octaves = 6, lacunarity = 2.03, gain = 0.5, paused = false}
	ui.scene_request = -1
	ui.scale = 1

	mu.init(&ui.ctx)
	ui.ctx.text_width = mu.default_atlas_text_width
	ui.ctx.text_height = mu.default_atlas_text_height

	// Font atlas texture (single-channel alpha).
	ui.atlas = sdl.CreateGPUTexture(
		gpu,
		{
			type = .D2,
			format = .R8_UNORM,
			usage = {.SAMPLER},
			width = mu.DEFAULT_ATLAS_WIDTH,
			height = mu.DEFAULT_ATLAS_HEIGHT,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	); assert(ui.atlas != nil)
	ui.sampler = sdl.CreateGPUSampler(
		gpu,
		{
			min_filter = .NEAREST,
			mag_filter = .NEAREST,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	); assert(ui.sampler != nil)

	// One-time atlas upload on its own command buffer.
	upload := sdl.CreateGPUTransferBuffer(
		gpu,
		{usage = .UPLOAD, size = mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT},
	); assert(upload != nil)
	ptr := sdl.MapGPUTransferBuffer(gpu, upload, false)
	mem.copy(ptr, raw_data(mu.default_atlas_alpha[:]), mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT)
	sdl.UnmapGPUTransferBuffer(gpu, upload)
	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = upload, offset = 0},
		{
			texture = ui.atlas,
			w = mu.DEFAULT_ATLAS_WIDTH,
			h = mu.DEFAULT_ATLAS_HEIGHT,
			d = 1,
		},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	ok := sdl.SubmitGPUCommandBuffer(cmd); assert(ok)
	sdl.ReleaseGPUTransferBuffer(gpu, upload)

	// Geometry buffers, reused every frame.
	ui.vertex_buffer = sdl.CreateGPUBuffer(
		gpu,
		{usage = {.VERTEX}, size = UI_VERTEX_CAPACITY * size_of(UiVertex)},
	); assert(ui.vertex_buffer != nil)
	ui.transfer = sdl.CreateGPUTransferBuffer(
		gpu,
		{usage = .UPLOAD, size = UI_VERTEX_CAPACITY * size_of(UiVertex)},
	); assert(ui.transfer != nil)

	// Pipeline from the goose glue; alpha blending over the scene.
	vertex_glue := shader_glue.ui_vertex()
	vertex_shader := create_shader(gpu, vertex_glue, .VERTEX); assert(vertex_shader != nil)
	fragment_glue := shader_glue.ui_fragment()
	fragment_shader := create_shader(gpu, fragment_glue, .FRAGMENT)
	assert(fragment_shader != nil)
	free_blob_if_hot(vertex_glue)
	free_blob_if_hot(fragment_glue)

	reflected := shader_glue.ui_vertex_attributes(UiVertex)
	attributes := goose_sdl.convert_vertex_attributes(reflected[:], context.temp_allocator)

	ui.pipeline = sdl.CreateGPUGraphicsPipeline(
		gpu,
		{
			vertex_shader = vertex_shader,
			fragment_shader = fragment_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
					slot = 0,
					pitch = size_of(UiVertex),
					input_rate = .VERTEX,
				}),
				num_vertex_attributes = u32(len(attributes)),
				vertex_attributes = raw_data(attributes),
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
					format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
					blend_state = {
						src_color_blendfactor = .SRC_ALPHA,
						dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
						color_blend_op = .ADD,
						src_alpha_blendfactor = .SRC_ALPHA,
						dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
						alpha_blend_op = .ADD,
						color_write_mask = {.R, .G, .B, .A},
						enable_blend = true,
					},
				}),
			},
		},
	); assert(ui.pipeline != nil)

	sdl.ReleaseGPUShader(gpu, vertex_shader)
	sdl.ReleaseGPUShader(gpu, fragment_shader)
	return ui
}

ui_handle_event :: proc(ui: ^Ui, event: sdl.Event) {
	#partial switch event.type {
	case .MOUSE_MOTION:
		mu.input_mouse_move(&ui.ctx, i32(event.motion.x), i32(event.motion.y))
	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl.BUTTON_LEFT {
			mu.input_mouse_down(&ui.ctx, i32(event.button.x), i32(event.button.y), .LEFT)
		}
	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl.BUTTON_LEFT {
			mu.input_mouse_up(&ui.ctx, i32(event.button.x), i32(event.button.y), .LEFT)
		}
	case .MOUSE_WHEEL:
		mu.input_scroll(&ui.ctx, 0, i32(event.wheel.y * -30))
	}
}

// Builds the widgets. Returns a scene index when a scene button was pressed.
// Scenes are listed by compute shader file name in the Controls window; a
// static overlay at the top-center shows a few lines about the active scene
// (what it displays, what the colors mean). Both hide on SPACE.
ui_build :: proc(
	ui: ^Ui,
	current_scene: int,
	scene_names, scene_descriptions: []string,
	frame_w, frame_h: i32,
) -> int {
	ui.scene_request = -1
	ctx := &ui.ctx
	mu.begin(ctx)
	if mu.window(ctx, "Controls", {10, 10, 230, 460}) {
		mu.layout_row(ctx, {80, -1})
		mu.label(ctx, "octaves")
		mu.slider(ctx, &ui.params.octaves, 1, 12, 1)
		mu.label(ctx, "lacunarity")
		mu.slider(ctx, &ui.params.lacunarity, 1.0, 4.0, 0.01)
		mu.label(ctx, "gain")
		mu.slider(ctx, &ui.params.gain, 0.05, 0.95, 0.01)
		mu.checkbox(ctx, "pause time", &ui.params.paused)
		mu.checkbox(ctx, "color", &ui.params.color)
		mu.checkbox(ctx, "3D view", &ui.params.view3d)

		buf: [64]u8
		mu.layout_row(ctx, {-1})
		mu.label(ctx, fmt.bprintf(buf[:], "gen %.2f ms", ui.gen_ms))

		// Scene list: one text button per compute shader file.
		mu.layout_row(ctx, {-1})
		for name, i in scene_names {
			label := fmt.tprintf("[%s]", name) if current_scene == i else name
			if .SUBMIT in mu.button(ctx, label) {
				ui.scene_request = i
			}
		}
	}

	// Static overlay at the top-center: a few lines about the active scene.
	{
		overlay_opts: mu.Options = {.NO_CLOSE, .NO_RESIZE, .NO_SCROLL, .NO_INTERACT}
		if mu.window(
			ctx,
			scene_names[current_scene],
			{frame_w / 2 - 220, 10, 440, 118},
			overlay_opts,
		) {
			mu.layout_row(ctx, {-1})
			line_start := 0
			desc := scene_descriptions[current_scene]
			for ch, i in desc {
				if ch == '\n' {
					mu.text(ctx, desc[line_start:i])
					line_start = i + 1
				}
			}
			mu.text(ctx, desc[line_start:])
		}
	}
	mu.end(ctx)
	ui.captures_mouse = ctx.hover_root != nil || ctx.focus_id != 0
	return ui.scene_request
}

// Converts microui draw commands to vertex segments split by clip rect.
ui_build_geometry :: proc(ui: ^Ui, frame_width, frame_height: i32) {
	clear(&ui.verts)
	clear(&ui.segments)

	scale := ui.scale
	white := mu.default_atlas[mu.DEFAULT_ATLAS_WHITE]
	white_uv := [2]f32 {
		(f32(white.x) + f32(white.w) * 0.5) / mu.DEFAULT_ATLAS_WIDTH,
		(f32(white.y) + f32(white.h) * 0.5) / mu.DEFAULT_ATLAS_HEIGHT,
	}

	current_clip := sdl.Rect{0, 0, frame_width, frame_height}
	segment_first: u32 = 0

	push_quad :: proc(ui: ^Ui, x, y, w, h: f32, uv: mu.Rect, color: mu.Color, solid_uv: [2]f32) {
		s := ui.scale
		c := [4]f32{f32(color.r), f32(color.g), f32(color.b), f32(color.a)} / 255.0
		u0 := f32(uv.x) / mu.DEFAULT_ATLAS_WIDTH
		v0 := f32(uv.y) / mu.DEFAULT_ATLAS_HEIGHT
		u1 := (f32(uv.x) + f32(uv.w)) / mu.DEFAULT_ATLAS_WIDTH
		v1 := (f32(uv.y) + f32(uv.h)) / mu.DEFAULT_ATLAS_HEIGHT
		if uv.w == 0 {
			u0, v0, u1, v1 = solid_uv.x, solid_uv.y, solid_uv.x, solid_uv.y
		}
		p0 := UiVertex{{x * s, y * s}, {u0, v0}, c}
		p1 := UiVertex{{(x + w) * s, y * s}, {u1, v0}, c}
		p2 := UiVertex{{x * s, (y + h) * s}, {u0, v1}, c}
		p3 := UiVertex{{(x + w) * s, (y + h) * s}, {u1, v1}, c}
		append(&ui.verts, p0, p1, p2, p2, p1, p3)
	}

	cmd: ^mu.Command
	for mu.next_command(&ui.ctx, &cmd) {
		#partial switch c in cmd.variant {
		case ^mu.Command_Clip:
			// Close the current segment and start a new one.
			if int(segment_first) < len(ui.verts) {
				append(
					&ui.segments,
					UiSegment{segment_first, u32(len(ui.verts)) - segment_first, current_clip},
				)
			}
			current_clip = {
				i32(f32(c.rect.x) * scale),
				i32(f32(c.rect.y) * scale),
				i32(f32(c.rect.w) * scale),
				i32(f32(c.rect.h) * scale),
			}
			segment_first = u32(len(ui.verts))
		case ^mu.Command_Rect:
			push_quad(
				ui,
				f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h),
				{},
				c.color,
				white_uv,
			)
		case ^mu.Command_Text:
			x := f32(c.pos.x)
			y := f32(c.pos.y)
			for ch in c.str {
				// The default font covers ASCII only; non-ASCII (UTF-8
				// accents) would index past the atlas.
				glyph := ch if ch <= 126 else '?'
				r := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + int(glyph)]
				push_quad(ui, x, y, f32(r.w), f32(r.h), r, c.color, white_uv)
				x += f32(r.w)
			}
		case ^mu.Command_Icon:
			r := mu.default_atlas[int(c.id)]
			push_quad(
				ui,
				f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h),
				r,
				c.color,
				white_uv,
			)
		}
	}
	if int(segment_first) < len(ui.verts) {
		append(&ui.segments, UiSegment{segment_first, u32(len(ui.verts)) - segment_first, current_clip})
	}
}

// Uploads this frame's geometry. Call before the UI render pass.
ui_upload :: proc(ui: ^Ui, gpu: ^sdl.GPUDevice, cmd: ^sdl.GPUCommandBuffer) {
	if len(ui.verts) == 0 do return
	assert(len(ui.verts) <= UI_VERTEX_CAPACITY, "ui vertex capacity exceeded")
	size := u32(len(ui.verts) * size_of(UiVertex))
	ptr := sdl.MapGPUTransferBuffer(gpu, ui.transfer, true)
	mem.copy(ptr, raw_data(ui.verts), int(size))
	sdl.UnmapGPUTransferBuffer(gpu, ui.transfer)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = ui.transfer, offset = 0},
		{buffer = ui.vertex_buffer, offset = 0, size = size},
		true,
	)
	sdl.EndGPUCopyPass(copy_pass)
}

// Draws the overlay on top of the scene. Own render pass with .LOAD.
ui_draw :: proc(
	ui: ^Ui,
	gpu: ^sdl.GPUDevice,
	cmd: ^sdl.GPUCommandBuffer,
	swapchain_texture: ^sdl.GPUTexture,
	width, height: i32,
) {
	if len(ui.segments) == 0 do return

	color_target := sdl.GPUColorTargetInfo {
		texture  = swapchain_texture,
		load_op  = .LOAD,
		store_op = .STORE,
	}
	render_pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil)
	sdl.BindGPUGraphicsPipeline(render_pass, ui.pipeline)
	sdl.BindGPUVertexBuffers(
		render_pass,
		0,
		&(sdl.GPUBufferBinding{buffer = ui.vertex_buffer, offset = 0}),
		1,
	)
	sdl.BindGPUFragmentSamplers(
		render_pass,
		0,
		&(sdl.GPUTextureSamplerBinding{texture = ui.atlas, sampler = ui.sampler}),
		1,
	)

	resolution := shader_glue.UiVertexUniforms {
		iResolution = {f32(width), f32(height)},
	}
	sdl.PushGPUVertexUniformData(
		cmd,
		shader_glue.UI_VERTEX_UNIFORMS.location.slot,
		&resolution,
		shader_glue.UI_VERTEX_UNIFORMS.size,
	)

	for segment in ui.segments {
		sdl.SetGPUScissor(render_pass, segment.clip)
		sdl.DrawGPUPrimitives(render_pass, segment.count, 1, segment.first, 0)
	}
	sdl.EndGPURenderPass(render_pass)
}
