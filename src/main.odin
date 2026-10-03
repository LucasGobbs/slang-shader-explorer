package main

import goose "../../goose/src"
import shader_glue "./generated"
import im "../vendor/odin-imgui"
import im_sdl "../vendor/odin-imgui/backends/sdl3"
import im_sdlgpu "../vendor/odin-imgui/backends/sdlgpu3"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

// shader_explorer: a shader playground. Every .slang file in
// src/shaders/scenes is a scene (compute or fullscreen graphics pass,
// discovered and built at runtime — see scene_runtime.odin). Scenes
// render into an offscreen texture; a single blit pipeline samples it
// and the UI overlay draws on top. Generation time is measured per
// frame with a GPU fence and shown as an average in the UI.
//
// Built with -define:HOT_RELOAD:true (`make run` / `make debug`) the
// infra glue loads shader code from disk per call.

HOT_RELOAD :: #config(HOT_RELOAD, false)

// The app font (JetBrains Mono), kept so the code editor can push its own
// size independently of the UI font size.
app_font: ^im.Font

// Scenes are discovered and built at runtime from src/shaders/scenes
// (see scene_runtime.odin); only infra shaders use the compiled glue.

create_shader :: proc(
	gpu: ^sdl.GPUDevice,
	glue: goose.GraphicsParameters,
	stage: sdl.GPUShaderStage,
) -> ^sdl.GPUShader {
	shader := sdl.CreateGPUShader(
		gpu,
		{
			stage = stage,
			format = glue.code.platform == .Metal ? {.MSL} : {.SPIRV},
			code_size = glue.code.blob.size,
			code = glue.code.blob.data,
			entrypoint = glue.code.entrypoint,
			num_samplers = glue.resources.samplers,
			num_uniform_buffers = glue.resources.uniform_buffers,
			num_storage_buffers = glue.resources.storage_buffers,
			num_storage_textures = glue.resources.storage_textures,
		},
	)
	if shader == nil {
		fmt.eprintfln("failed to create shader %s", glue.code.name)
	}
	return shader
}

link_pipeline :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
	vertex_shader, fragment_shader: ^sdl.GPUShader,
) -> ^sdl.GPUGraphicsPipeline {
	pipeline := sdl.CreateGPUGraphicsPipeline(
	gpu,
	{
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		primitive_type = .TRIANGLELIST,
		// No vertex_input_state: positions come from SV_VertexID.
		target_info = {
			num_color_targets = 1,
			color_target_descriptions = &(sdl.GPUColorTargetDescription {
					format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
				}),
		},
	},
	)
	if pipeline == nil {
		fmt.eprintln("failed to link graphics pipeline")
	}
	return pipeline
}

create_pipeline :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
	vertex_glue: goose.GraphicsParameters,
	fragment_glue: goose.GraphicsParameters,
) -> ^sdl.GPUGraphicsPipeline {
	defer free_blob_if_hot(vertex_glue)
	defer free_blob_if_hot(fragment_glue)

	vertex_shader := create_shader(gpu, vertex_glue, .VERTEX)
	if vertex_shader == nil do return nil
	fragment_shader := create_shader(gpu, fragment_glue, .FRAGMENT)
	if fragment_shader == nil {
		sdl.ReleaseGPUShader(gpu, vertex_shader)
		return nil
	}

	pipeline := link_pipeline(gpu, window, vertex_shader, fragment_shader)
	sdl.ReleaseGPUShader(gpu, vertex_shader)
	sdl.ReleaseGPUShader(gpu, fragment_shader)
	return pipeline
}

// Loads an image file (stb_image) into a GPU texture with .SAMPLER usage.
load_texture :: proc(gpu: ^sdl.GPUDevice, path: string) -> ^sdl.GPUTexture {
	file_data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read %s: %v", path, read_err)
		return nil
	}
	w, h, ch: c.int
	pixels := stbi.load_from_memory(
		raw_data(file_data),
		c.int(len(file_data)),
		&w,
		&h,
		&ch,
		4, // force RGBA8
	)
	if pixels == nil {
		fmt.eprintfln("failed to decode %s: %s", path, stbi.failure_reason())
		return nil
	}
	defer stbi.image_free(pixels)

	tex := sdl.CreateGPUTexture(
		gpu,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(w),
			height = u32(h),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	if tex == nil do return nil

	size := u32(w) * u32(h) * 4
	upload := sdl.CreateGPUTransferBuffer(gpu, {usage = .UPLOAD, size = size})
	if upload == nil {
		sdl.ReleaseGPUTexture(gpu, tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(gpu, upload)
	ptr := sdl.MapGPUTransferBuffer(gpu, upload, false)
	mem.copy(ptr, pixels, int(size))
	sdl.UnmapGPUTransferBuffer(gpu, upload)

	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = upload, offset = 0, pixels_per_row = u32(w), rows_per_layer = u32(h)},
		{texture = tex, w = u32(w), h = u32(h), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	ok := sdl.SubmitGPUCommandBuffer(cmd); assert(ok)
	return tex
}


// Hit test for the borderless window: SDL asks how each region behaves.
// Edge strips resize, empty title-bar space drags the window (widget rects
// registered by ui_toolbar stay .NORMAL so ImGui keeps their clicks), the
// rest is regular scene/UI space.
RESIZE_BORDER :: 8

window_hit_test :: proc "c" (win: ^sdl.Window, area: ^sdl.Point, data: rawptr) -> sdl.HitTestResult {
	context = runtime.default_context()
	w, h: i32
	sdl.GetWindowSize(win, &w, &h)
	x, y := f32(area.x), f32(area.y)
	maximized := .MAXIMIZED in sdl.GetWindowFlags(win)

	if !maximized {
		border := f32(RESIZE_BORDER)
		left := x < border
		right := x >= f32(w) - border
		top := y < border
		bottom := y >= f32(h) - border
		switch {
		case top && left:
			return .RESIZE_TOPLEFT
		case top && right:
			return .RESIZE_TOPRIGHT
		case bottom && left:
			return .RESIZE_BOTTOMLEFT
		case bottom && right:
			return .RESIZE_BOTTOMRIGHT
		case top:
			return .RESIZE_TOP
		case bottom:
			return .RESIZE_BOTTOM
		case left:
			return .RESIZE_LEFT
		case right:
			return .RESIZE_RIGHT
		}
	}

	if y < TITLEBAR_H && !titlebar_point_hot(x, y) {
		// Zoom lives on the green traffic light; no double-click here.
		// SDL may query the hit test more than once per press (drag
		// decision + generic video layer), so counting presses in this
		// callback cannot tell a double-click from a single one.
		return .NORMAL if maximized else .DRAGGABLE
	}
	return .NORMAL
}

main :: proc() {
	once := false
	start_scene := 0
	start_graph := false
	force3d := false
	shot_path := ""
	force_color := false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--once":
			once = true
		case "--3d":
			force3d = true
		case "--ied-debug":
			ied_debug_clicks = true
		case "--ied-test":
			ied_selftest = true
		case "--color":
			force_color = true
		case "--shot":
			// Render one frame, export it as PNG (src/shot.odin), exit.
			if i + 1 < len(args) {
				i += 1
				shot_path = args[i]
			}
		case "--scene":
			if i + 1 < len(args) {
				i += 1
				n := args[i][0] - '1'
				if n >= 0 && n < 9 {
					start_scene = int(n)
				}
			}
		case "--graph":
			// Start with the sidebar on the node graph panel (CLI parity
			// with F2).
			start_graph = true
		case "--graph-test":
			// --graph plus two created passes on the starting scene.
			start_graph = true
			ing_selftest = true
		}
	}

	ok := sdl.Init({.VIDEO}); assert(ok)
	// Borderless: the ImGui title bar (ui.odin) is the window chrome. The
	// hit test keeps native drag/resize working without a native frame.
	window := sdl.CreateWindow("shader_explorer", 800, 600, {.RESIZABLE, .BORDERLESS})
	assert(window != nil)
	ok = sdl.SetWindowHitTest(window, window_hit_test, nil); assert(ok)
	ok = sdl.SetWindowMinimumSize(window, 480, 320); assert(ok)
	// Rounded corners (macOS, via the native NSWindow layer).
	window_round_corners(window)
	gpu := sdl.CreateGPUDevice({.SPIRV, .MSL, .DXBC, .DXIL}, true, nil)
	assert(gpu != nil)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

	// Scenes are discovered in src/shaders/scenes and built at runtime;
	// adding a .slang file there needs no code change (scene_runtime.odin).
	scene_mgr: SceneManager
	scene_rescan(&scene_mgr, gpu)
	assert(len(scene_mgr.scenes) > 0)
	if start_scene >= len(scene_mgr.scenes) do start_scene = 0
	scene_mgr.current = start_scene

	// Blit: the only graphics pipeline besides the UI overlay.
	blit_pipeline := create_pipeline(
		gpu,
		window,
		shader_glue.blit_vertex(),
		shader_glue.blit_fragment(),
	); assert(blit_pipeline != nil)

	// 3D heightfield view of the same offscreen texture (button in UI).
	blit3d_vertex_glue := shader_glue.blit3d_vertex()
	blit3d_fragment_glue := shader_glue.blit3d_fragment()
	blit3d_vs := create_shader(gpu, blit3d_vertex_glue, .VERTEX)
	assert(blit3d_vs != nil)
	blit3d_fs := create_shader(gpu, blit3d_fragment_glue, .FRAGMENT)
	assert(blit3d_fs != nil)
	free_blob_if_hot(blit3d_vertex_glue)
	free_blob_if_hot(blit3d_fragment_glue)
	blit3d_pipeline := sdl.CreateGPUGraphicsPipeline(
		gpu,
		{
			vertex_shader = blit3d_vs,
			fragment_shader = blit3d_fs,
			primitive_type = .TRIANGLELIST,
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
					}),
				depth_stencil_format = .D32_FLOAT,
			},
			depth_stencil_state = {
				compare_op = .LESS,
				enable_depth_test = true,
				enable_depth_write = true,
			},
		},
	); assert(blit3d_pipeline != nil)
	sdl.ReleaseGPUShader(gpu, blit3d_vs)
	sdl.ReleaseGPUShader(gpu, blit3d_fs)
	blit_sampler := sdl.CreateGPUSampler(
		gpu,
		{
			min_filter = .NEAREST,
			mag_filter = .NEAREST,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	); assert(blit_sampler != nil)

	ui := ui_init()
	if force3d do ui.params.view3d = true
	if force_color do ui.params.color = true

	// Integrated ImGui shader editor (F1 toggles the panel).
	im.CHECKVERSION()
	im.CreateContext()
	// Coding font for everything (UI + editor): the atlas default is a tiny
	// bitmap font that hurts readability; JetBrains Mono is OFL-licensed and
	// vendored. FontDefault switches NewFrame to it.
	io_fonts := im.GetIO()
	if jb := im.FontAtlas_AddFontFromFileTTF(io_fonts.Fonts, "vendor/fonts/JetBrainsMono-Regular.ttf", 16, nil, nil); jb != nil {
		io_fonts.FontDefault = jb
		app_font = jb
	}
	ui_apply_style()
	im_sdl.InitForSDLGPU(window)
	imgui_init := im_sdlgpu.DEFAULT_INIT_INFO
	imgui_init.Device = gpu
	imgui_init.ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(gpu, window)
	assert(im_sdlgpu.Init(&imgui_init))
	ied := ied_init()
	ing := ing_init()
	// The editor self-test drives the component directly; surface its
	// floating window so the frames (tabs, markers) are visible.
	if ied_selftest do ied.open = true
	if start_graph do ui.mode = .GRAPH
	if ing_selftest {
		ing.scene = strings.clone(scene_mgr.scenes[scene_mgr.current].title)
		sg_create_pass(ing, ied, .COMPUTE)
		sg_create_pass(ing, ied, .GRAPHICS)
	}

	// Scanned paper backgrounds (assets/), picked in the UI and bound to
	// the scene's compute pass. Order matches paper_names.
	paper_names := [2]string{"watercolor", "parchment"}
	paper_textures: [2]^sdl.GPUTexture
	paper_paths := [2]string{"assets/watercolor_paper.jpg", "assets/parchment.jpg"}
	for path, i in paper_paths {
		paper_textures[i] = load_texture(gpu, path)
		assert(paper_textures[i] != nil)
	}

	// Equirectangular skyboxes (assets/skybox/skybox-*.png), a global
	// option like the paper: scenes sampling skybox_tex get the pick.
	skybox_names: [dynamic]string
	skybox_textures: [dynamic]^sdl.GPUTexture
	if entries, err := os.read_directory_by_path("assets/skybox", 0, context.temp_allocator);
	   err == nil {
		for entry in entries {
			lower := strings.to_lower(entry.name, context.temp_allocator)
			if !strings.has_suffix(lower, ".png") && !strings.has_suffix(lower, ".jpg") do continue
			name := entry.name
			if strings.has_prefix(name, "skybox-") do name = name[len("skybox-"):]
			dot := strings.last_index(name, ".")
			if dot > 0 do name = name[:dot]
			tex := load_texture(gpu, entry.fullpath)
			assert(tex != nil)
			append(&skybox_names, strings.clone(name))
			append(&skybox_textures, tex)
		}
	}

	// All models in assets/models (+ generated icosphere fallback) for
	// model-viewer scenes; picked in the UI "model" group.
	models := model_load_all(gpu)
	assert(len(models) > 0 && models[0].vb != nil)
	model_names: [dynamic]string
	for &m in models do append(&model_names, m.name)
	paper_sampler := sdl.CreateGPUSampler(
		gpu,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	); assert(paper_sampler != nil)

	// Offscreen texture the compute scenes render into; recreated on resize.
	scene_tex: ^sdl.GPUTexture
	tex_w, tex_h: i32
	depth_tex: ^sdl.GPUTexture

	// Orbit camera for the 3D heightfield view.
	orbiting := false
	orbit_anchor: [2]f32
	yaw: f32 = 0.6
	pitch: f32 = 0.55
	dist: f32 = 2.6

	// Persistent orbit for model-viewer scenes in mouse rotation mode.
	model_orbiting := false
	model_orbit_anchor: [2]f32
	model_yaw: f32
	model_pitch: f32 = 0.55
	previous_interaction := ui.params.interaction

	// Texture generation timing: fence per frame, EMA of submit→completion.
	pending_fence: ^sdl.GPUFence
	fence_t0: u64
	gen_initialized := false

	set_title :: proc(window: ^sdl.Window, title: string) {
		ok := sdl.SetWindowTitle(window, fmt.ctprint("shader_explorer — ", title))
		assert(ok)
	}

	set_title(window, scene_mgr.scenes[scene_mgr.current].title)

	app_time: f32
	prev_ticks := sdl.GetTicks()
	main_loop: for {
		scene_poll(&scene_mgr, gpu)
		if len(scene_mgr.scenes) == 0 do break
		current := scene_mgr.current

		width, height: i32
		sdl.GetWindowSizeInPixels(window, &width, &height)

		io := im.GetIO()
		imgui_mouse := io.WantCaptureMouse
		imgui_kb := io.WantCaptureKeyboard

		event: sdl.Event
		for sdl.PollEvent(&event) {
			im_sdl.ProcessEvent(&event)
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if event.key.key == sdl.K_LGUI || event.key.key == sdl.K_RGUI {
					ied_gui_held = true
				} else if event.key.key == sdl.K_LSHIFT || event.key.key == sdl.K_RSHIFT {
					ied_shift_held = true
				}
				if event.key.key == sdl.K_S && (event.key.mod & sdl.KMOD_GUI) != {} {
					// Application-wide save: every dirty editor tab.
					ied_save_all(ied)
					continue
				}
				if event.key.key == sdl.K_B && (event.key.mod & sdl.KMOD_GUI) != {} {
					// Toggle the whole sidebar (VS Code's Cmd+B).
					ui.open = !ui.open
					continue
				}
				#partial switch event.key.scancode {
				case .F1:
					// The shader editor is a floating window, separate
					// from the sidebar by design.
					ied.open = !ied.open
				case .F2:
					// Jump to the node graph panel (or back to controls).
					if ui.mode == .GRAPH {
						ui.mode = .CONTROLS
					} else {
						ui.mode = .GRAPH
						ui.panel_open = true
					}
					ui.open = true
				case .ESCAPE:
					if !imgui_kb do break main_loop
				case .SPACE:
					if !imgui_kb {
						// Zen mode: hide the sidebar and the editor. The
						// title bar stays — it is the window chrome now.
						ui.open = !ui.open
						ied.open = ui.open
					}
				case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
					if !imgui_kb {
						n := int(event.key.scancode) - int(sdl.Scancode._1)
						if n < len(scene_mgr.scenes) {
							scene_mgr.current = n
							set_title(window, scene_mgr.scenes[n].title)
							gen_initialized = false
						}
					}
				}
			case .KEY_UP:
				if event.key.key == sdl.K_LGUI || event.key.key == sdl.K_RGUI {
					ied_gui_held = false
				} else if event.key.key == sdl.K_LSHIFT || event.key.key == sdl.K_RSHIFT {
					ied_shift_held = false
				}
			}

			// Orbit camera input (3D view only; left-drag rotates, wheel zooms).
			if ui.params.view3d && !imgui_mouse {
				#partial switch event.type {
				case .MOUSE_BUTTON_DOWN:
					if event.button.button == sdl.BUTTON_LEFT && !ui.captures_mouse {
						orbiting = true
						orbit_anchor = {event.button.x, event.button.y}
					}
				case .MOUSE_BUTTON_UP:
					if event.button.button == sdl.BUTTON_LEFT {
						orbiting = false
					}
				case .MOUSE_MOTION:
					if orbiting {
						yaw += (event.motion.x - orbit_anchor.x) * 0.012
						pitch = clamp(pitch + (event.motion.y - orbit_anchor.y) * 0.012, 0.1, 1.5)
						orbit_anchor = {event.motion.x, event.motion.y}
					}
				case .MOUSE_WHEEL:
					if !ui.captures_mouse {
						dist = clamp(dist * (1 - event.wheel.y * 0.1), 0.8, 8.0)
					}
				}
			}

			// Model camera input: only active in mouse rotation mode.
			if !ui.params.view3d &&
			   !imgui_mouse &&
			   ui.params.interaction == .MOUSE_ROTATE &&
			   scene_mgr.scenes[scene_mgr.current].uses_model {
				#partial switch event.type {
				case .MOUSE_BUTTON_DOWN:
					if event.button.button == sdl.BUTTON_LEFT && !ui.captures_mouse {
						model_orbiting = true
						model_orbit_anchor = {event.button.x, event.button.y}
					}
				case .MOUSE_BUTTON_UP:
					if event.button.button == sdl.BUTTON_LEFT {
						model_orbiting = false
					}
				case .MOUSE_MOTION:
					if model_orbiting {
						model_yaw -= (event.motion.x - model_orbit_anchor.x) * 0.012
						model_pitch = clamp(
							model_pitch + (event.motion.y - model_orbit_anchor.y) * 0.012,
							-1.45,
							1.45,
						)
						model_orbit_anchor = {event.motion.x, event.motion.y}
					}
				}
			}
		}

		// ImGui frame: Controls + editor panel build their widgets here; the
		// draw data is rendered after the blit pass below.
		im_sdlgpu.NewFrame()
		im_sdl.NewFrame()
		im.NewFrame()
		scene_request := ui_build(ui, &scene_mgr, window, ied, ing, width, height)
		// The editor follows the active scene (its tab plus every imported
		// module) and keeps its background work (LSP sync, diagnostics)
		// flowing whether or not its window is visible.
		ied_open_scene(ied, scene_mgr.scenes[scene_mgr.current].title)
		ied_tick(ied)
		ied_frame(ied)
		if ui.quit_requested do break main_loop
		if scene_request >= 0 {
			scene_mgr.current = scene_request
			current = scene_request
			model_orbiting = false
			set_title(window, scene_mgr.scenes[scene_request].title)
			gen_initialized = false
		}
		im.Render()

		ticks := sdl.GetTicks()
		dt := f32(ticks - prev_ticks) / 1000
		prev_ticks = ticks
		if !ui.params.paused {
			app_time += dt
		}

		// Enter mouse mode without snapping: continue from the current
		// autorotate angle, then retain every drag result after release.
		if previous_interaction != ui.params.interaction {
			if ui.params.interaction == .MOUSE_ROTATE {
				model_yaw = app_time * 0.4
				model_pitch = 0.55
			}
			model_orbiting = false
			previous_interaction = ui.params.interaction
		}

		win_w, win_h: i32
		sdl.GetWindowSize(window, &win_w, &win_h)
		scale := f32(width) / f32(win_w)

		// Mouse in pixel coordinates, y up to match frag_coord; clicks
		// landing on UI widgets do not count as scene clicks.
		mx, my: f32
		buttons := sdl.GetMouseState(&mx, &my)
		mouse_pos := [2]f32{mx * scale, f32(height) - my * scale}
		mouse_click := .LEFT in buttons && !ui.captures_mouse

		camera_yaw := app_time * 0.4
		camera_pitch: f32 = 0.55
		if ui.params.interaction == .MOUSE_ROTATE {
			camera_yaw = model_yaw
			camera_pitch = model_pitch
		}
		camera := camera_orbit(camera_yaw, camera_pitch, f32(width) / f32(height))

		scene_write_uniforms(
			&scene_mgr.scenes[current],
			{f32(width), f32(height)},
			app_time,
			ui.params.color,
			mouse_pos,
			mouse_click,
			&camera,
		)

		// (Re)create the offscreen texture on resize.
		if scene_tex == nil || tex_w != width || tex_h != height {
			if scene_tex != nil do sdl.ReleaseGPUTexture(gpu, scene_tex)
			scene_tex = sdl.CreateGPUTexture(
				gpu,
				{
					type = .D2,
					format = .R8G8B8A8_UNORM,
					usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE, .COLOR_TARGET},
					width = u32(width),
					height = u32(height),
					layer_count_or_depth = 1,
					num_levels = 1,
				},
			); assert(scene_tex != nil)
			if depth_tex != nil do sdl.ReleaseGPUTexture(gpu, depth_tex)
			depth_tex = sdl.CreateGPUTexture(
				gpu,
				{
					type = .D2,
					format = .D32_FLOAT,
					usage = {.DEPTH_STENCIL_TARGET},
					width = u32(width),
					height = u32(height),
					layer_count_or_depth = 1,
					num_levels = 1,
				},
			); assert(depth_tex != nil)
			tex_w, tex_h = width, height
		}

		// Resolve last frame's compute fence: sample the generation time
		// (submit → GPU completion, includes queue wait) into an EMA and
		// log the running average every frame.
		if pending_fence != nil && sdl.QueryGPUFence(gpu, pending_fence) {
			t1 := sdl.GetPerformanceCounter()
			sample := f32(f64(t1 - fence_t0) / f64(sdl.GetPerformanceFrequency()) * 1000)
			sdl.ReleaseGPUFence(gpu, pending_fence)
			pending_fence = nil
			if !gen_initialized {
				ui.gen_ms = sample
				gen_initialized = true
			} else {
				ui.gen_ms = 0.95 * ui.gen_ms + 0.05 * sample
			}
		}
		// fmt.printfln("gen %.3f ms", ui.gen_ms)

		// Shared resources for the frame (depth_tex recreates on resize).
		res := SceneResources {
			depth_tex       = depth_tex,
			sampler         = paper_sampler,
			paper_textures  = paper_textures[:],
			paper_index     = ui.params.paper,
			skybox_textures = skybox_textures[:],
			skybox_index    = ui.params.skybox,
			model           = &models[min(ui.params.model_index, len(models) - 1)],
		}

		// The scene renders the offscreen texture, timed by fence.
		{
			fence_t0 = sdl.GetPerformanceCounter()
			pending_fence = submit_scene_frame(
				gpu,
				&scene_mgr.scenes[current],
				scene_tex,
				&res,
				width,
				height,
			)
			assert(pending_fence != nil)
		}

		// Frame export: download the just-submitted scene texture and exit.
		if shot_path != "" {
			save_texture_png(gpu, scene_tex, width, height, shot_path)
			break main_loop
		}

		// UI export buttons: scene_tex now holds the current frame.
		#partial switch ui.export_request {
		case .PNG:
			path := export_path(scene_mgr.scenes[current].title, "png")
			if save_texture_png(gpu, scene_tex, width, height, path) {
				fmt.printfln("saved %s", path)
			}
		case .GIF:
			export_gif(
				gpu,
				&scene_mgr.scenes[current],
				scene_tex,
				&res,
				width,
				height,
				ui.params.color,
			)
		}

		// Graphics passes: blit the texture, then the UI overlay.
		{
			cmd := sdl.AcquireGPUCommandBuffer(gpu)
			defer {
				ok := sdl.SubmitGPUCommandBuffer(cmd); assert(ok)
			}

			swapchain_texture: ^sdl.GPUTexture
			ok := sdl.WaitAndAcquireGPUSwapchainTexture(
				cmd,
				window,
				&swapchain_texture,
				nil,
				nil,
			); assert(ok)

			if swapchain_texture != nil {
				color_target := sdl.GPUColorTargetInfo {
					texture     = swapchain_texture,
					load_op     = .CLEAR,
					clear_color = {0, 0, 0, 1},
					store_op    = .STORE,
				}

				if ui.params.view3d {
					// 3D heightfield pass: depth-tested mesh displaced by the
					// scene texture's r channel, orbited by the mouse.
					origin := [3]f32{0, 0.15, 0}
					cp := math.cos(pitch)
					sp := math.sin(pitch)
					camPos := [3]f32 {
						origin.x + dist * cp * math.sin(yaw),
						origin.y + dist * sp,
						origin.z + dist * cp * math.cos(yaw),
					}
					to_origin := [3]f32 {
						origin.x - camPos.x,
						origin.y - camPos.y,
						origin.z - camPos.z,
					}
					fwd := linalg.normalize(to_origin)
					right := linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
					up := linalg.cross(right, fwd)
					cam := shader_glue.Blit3dVertexCamera {
						camPos = camPos,
						aspect = f32(width) / f32(height),
						fwd    = fwd,
						fovTan = 0.577,
						right  = right,
						nearZ  = 0.1,
						up     = up,
						farZ   = 30.0,
					}

					depth_target := sdl.GPUDepthStencilTargetInfo {
						texture     = depth_tex,
						load_op     = .CLEAR,
						clear_depth = 1.0,
						store_op    = .DONT_CARE,
					}
					render_pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, &depth_target)
					sdl.BindGPUGraphicsPipeline(render_pass, blit3d_pipeline)
					sdl.PushGPUVertexUniformData(
						cmd,
						shader_glue.BLIT3D_VERTEX_CAMERA.location.slot,
						&cam,
						shader_glue.BLIT3D_VERTEX_CAMERA.size,
					)
					sdl.BindGPUVertexSamplers(
						render_pass,
						0,
						&(sdl.GPUTextureSamplerBinding {
								texture = scene_tex,
								sampler = blit_sampler,
							}),
						1,
					)
					sdl.DrawGPUPrimitives(render_pass, 6 * 256 * 256, 1, 0, 0)
					sdl.EndGPURenderPass(render_pass)
				} else {
					render_pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil)
					sdl.BindGPUGraphicsPipeline(render_pass, blit_pipeline)
					sdl.BindGPUFragmentSamplers(
						render_pass,
						0,
						&(sdl.GPUTextureSamplerBinding {
								texture = scene_tex,
								sampler = blit_sampler,
							}),
						1,
					)
					sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
					sdl.EndGPURenderPass(render_pass)
				}

				// ImGui pass: Controls + editor panel on top of everything.
				draw_data := im.GetDrawData()
				if draw_data.DisplaySize.x > 0 && draw_data.DisplaySize.y > 0 {
					im_sdlgpu.PrepareDrawData(draw_data, cmd)
					imgui_target := sdl.GPUColorTargetInfo {
						texture  = swapchain_texture,
						load_op  = .LOAD,
						store_op = .STORE,
					}
					imgui_pass := sdl.BeginGPURenderPass(cmd, &imgui_target, 1, nil)
					im_sdlgpu.RenderDrawData(draw_data, cmd, imgui_pass)
					sdl.EndGPURenderPass(imgui_pass)
				}
			}
		}

		if once do break main_loop
	}

	ite_destroy(ied.handle)
	im_sdlgpu.Shutdown()
	im_sdl.Shutdown()
	im.DestroyContext()
	fmt.println("Exiting")
}
