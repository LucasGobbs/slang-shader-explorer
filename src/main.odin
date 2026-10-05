package main

import goose "../../goose/src"
import shader_glue "./generated"
import im "../vendor/odin-imgui"
import im_sdl "../vendor/odin-imgui/backends/sdl3"
import im_sdlgpu "../vendor/odin-imgui/backends/sdlgpu3"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "base:runtime"
import "core:slice"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import sdl "vendor:sdl3"
import "core:math/rand"
import stbi "vendor:stb/image"

// shader_explorer: a shader playground. Every .slang file in
// src/shaders/scenes is a scene (compute or fullscreen graphics pass,
// discovered and built at runtime: see scene_runtime.odin). Scenes
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
		log.errorf("failed to create shader %s", glue.code.name)
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
		log.error("failed to link graphics pipeline")
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
		log.errorf("failed to read %s: %v", path, read_err)
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
		log.errorf("failed to decode %s: %s", path, stbi.failure_reason())
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
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		log.errorf("failed to submit texture upload for %s: %s", path, sdl.GetError())
		sdl.ReleaseGPUTexture(gpu, tex)
		return nil
	}
	return tex
}

create_scene_target :: proc(gpu: ^sdl.GPUDevice, width, height: i32) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(
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
	)
}

create_black_texture :: proc(gpu: ^sdl.GPUDevice) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(
		gpu,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = 1,
			height = 1,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	if tex == nil do return nil
	upload := sdl.CreateGPUTransferBuffer(gpu, {usage = .UPLOAD, size = 4})
	if upload == nil {
		sdl.ReleaseGPUTexture(gpu, tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(gpu, upload)
	ptr := ([^]u8)(sdl.MapGPUTransferBuffer(gpu, upload, false))
	if ptr == nil {
		sdl.ReleaseGPUTexture(gpu, tex)
		return nil
	}
	for i in 0 ..< 4 do ptr[i] = 0
	sdl.UnmapGPUTransferBuffer(gpu, upload)
	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = upload, offset = 0, pixels_per_row = 1, rows_per_layer = 1},
		{texture = tex, w = 1, h = 1, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		sdl.ReleaseGPUTexture(gpu, tex)
		return nil
	}
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
	flags := sdl.GetWindowFlags(win)
	maximized := .MAXIMIZED in flags
	fullscreen := .FULLSCREEN in flags
	chromeless := maximized || fullscreen

	if !chromeless {
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
		// Empty bar space is natively draggable: macOS handles the drag
		// AND its window tiling (drag-to-edge/corner snap zones), which
		// a manual drag cannot trigger. No double-click here: the green
		// traffic light owns fullscreen/maximize.
		return .NORMAL if chromeless else .DRAGGABLE
	}
	return .NORMAL
}

show_metrics: bool

BenchmarkStats :: struct {
	mean, stddev, median, q1, q3, p95, p99, min, max: f32,
}

benchmark_stats :: proc(samples: []f32) -> BenchmarkStats {
	result: BenchmarkStats
	if len(samples) == 0 do return result
	sorted := make([]f32, len(samples), context.temp_allocator)
	copy(sorted, samples)
	slice.sort(sorted)
	for value in sorted do result.mean += value
	result.mean /= f32(len(sorted))
	for value in sorted {
		d := value - result.mean
		result.stddev += d * d
	}
	result.stddev = math.sqrt(result.stddev / f32(len(sorted)))
	percentile :: proc(values: []f32, p: f32) -> f32 {
		index := int(math.round(p * f32(len(values) - 1)))
		return values[clamp(index, 0, len(values) - 1)]
	}
	result.min = sorted[0]
	result.max = sorted[len(sorted) - 1]
	result.q1 = percentile(sorted, 0.25)
	result.median = percentile(sorted, 0.50)
	result.q3 = percentile(sorted, 0.75)
	result.p95 = percentile(sorted, 0.95)
	result.p99 = percentile(sorted, 0.99)
	return result
}

benchmark_log :: proc(label: string, samples: []f32) {
	s := benchmark_stats(samples)
	log.infof(
		"[benchmark] %s n=%d mean=%.4fms std=%.4f median=%.4f q1=%.4f q3=%.4f p95=%.4f p99=%.4f min=%.4f max=%.4f",
		label, len(samples), s.mean, s.stddev, s.median, s.q1, s.q3, s.p95, s.p99, s.min, s.max,
	)
}

main :: proc() {
	once := false
	start_scene := 0
	start_graph := false
	force3d := false
	shot_path := ""
	force_color := false
	pan_test := false
	pixel_test := false
	notify_test := false
	benchmark_frames := 0
	benchmark_warmup := 60
	benchmark_debug := false
	notify_test_frame := 0
	watch_test_watches_ready := false
	pixel_test_pos := [2]f32{400, 300}
	watch_test := false
	pan_test_frame := 0
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
		case "--notify-test":
			// Fires one toast of each kind at startup (visual check of
			// the notification overlay).
			notify_test = true
		case "--benchmark", "--benchmark-debug":
			benchmark_frames = 300
			benchmark_debug = args[i] == "--benchmark-debug"
			if i + 1 < len(args) {
				if count, ok := strconv.parse_int(args[i + 1]); ok && count > 0 {
					benchmark_frames = int(count)
					i += 1
				}
			}
		case "--metrics":
			show_metrics = true
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
				n, parsed := strconv.parse_int(args[i])
				if parsed && n > 0 {
					start_scene = int(n - 1)
				} else {
					log.warnf("ignoring invalid --scene value %q", args[i])
				}
			}
		case "--pixel-test":
			pixel_test = true
			if i + 2 < len(args) {
				x, x_ok := strconv.parse_int(args[i + 1])
				y, y_ok := strconv.parse_int(args[i + 2])
				if x_ok && y_ok {
					pixel_test_pos = {f32(x), f32(y)}
					i += 2
				}
			}
		case "--watch-test":
			pixel_test = true
			watch_test = true
			if i + 2 < len(args) {
				x, x_ok := strconv.parse_int(args[i + 1])
				y, y_ok := strconv.parse_int(args[i + 2])
				if x_ok && y_ok {
					pixel_test_pos = {f32(x), f32(y)}
					i += 2
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
		case "--pan-test":
			// Drive the node-editor trackpad pan without a trackpad: fake
			// the cursor over the canvas and inject wheel deltas.
			pan_test = true
			pan_test_debug = true
			start_graph = true
		}
	}

		// App-wide logging (core:log): info shows lifecycle + user actions,
	// debug hides self-test/LSP noise, warn for recoverable failures,
	// error for hard failures.
	context.logger = log.create_console_logger(log.Level.Info)

	// UI language (EN/ES/PT; core:text/i18n catalogs in i18n.odin),
	// restored from assets/i18n.lang.
	i18n_init()
	if notify_test {
		notify(.INFO, "notify test: info")
		notify(.WARN, "notify test: warning")
		notify(.ERROR, "notify test: error")
	}

	// Leak investigation: build with -define:MEM_TRACE=true to wrap the
	// heap in core:mem's tracking allocator; allocations still live at
	// exit are dumped with their allocation sites.
	when #config(MEM_TRACE, false) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			log.info("\n=== MEM TRACE: heap allocations still live at exit ===")
			for _, leak in track.allocation_map {
				log.errorf("LEAK: %v bytes allocated at %v", leak.size, leak.location)
			}
			for bad in track.bad_free_array {
				log.errorf("BAD FREE: %v at %v", bad.memory, bad.location)
			}
		}
	}

	// SDL validation errors (bad bindings, invalid GPU state) become
	// error toasts (notify.odin) instead of the abort dialog: the app
	// keeps running, the user sees what happened. The callback runs on
	// whatever thread tripped the assert, so it needs a saved context.
	g_sdl_context = context
	sdl.SetAssertionHandler(sdl_assert_notify, nil)

	if !sdl.Init({.VIDEO}) {
		log.errorf("failed to initialize SDL video: %s", sdl.GetError())
		return
	}
	// Borderless: the ImGui title bar (ui.odin) is the window chrome. The
	// hit test keeps native drag/resize working without a native frame.
	window := sdl.CreateWindow("shader_explorer", 800, 600, {.RESIZABLE, .BORDERLESS})
	if window == nil {
		log.errorf("failed to create SDL window: %s", sdl.GetError())
		return
	}
	if !sdl.SetWindowHitTest(window, window_hit_test, nil) {
		log.errorf("failed to install window hit test: %s", sdl.GetError())
		return
	}
	if !sdl.SetWindowMinimumSize(window, 480, 320) {
		log.errorf("failed to set minimum window size: %s", sdl.GetError())
		return
	}
	// Rounded corners (macOS, via the native NSWindow layer).
	window_round_corners(window)
	gpu := sdl.CreateGPUDevice({.SPIRV, .MSL, .DXBC, .DXIL}, true, nil)
	if gpu == nil {
		log.errorf("failed to create SDL GPU device: %s", sdl.GetError())
		return
	}
	if !sdl.ClaimWindowForGPUDevice(gpu, window) {
		log.errorf("failed to claim window for GPU device: %s", sdl.GetError())
		return
	}
	if benchmark_frames > 0 && sdl.WindowSupportsGPUPresentMode(gpu, window, .IMMEDIATE) {
		if sdl.SetGPUSwapchainParameters(gpu, window, .SDR, .IMMEDIATE) {
			log.info("[benchmark] present mode=immediate")
		}
	}

	// Catalog every scene, but compile/load only the selected startup scene.
	scene_mgr: SceneManager
	if !scene_rescan(&scene_mgr, gpu, start_scene) {
		log.error("failed to initialize scene catalog")
		return
	}

	// Blit: the only graphics pipeline besides the UI overlay.
	blit_pipeline := create_pipeline(
		gpu,
		window,
		shader_glue.blit_vertex(),
		shader_glue.blit_fragment(),
	)
	if blit_pipeline == nil {
		log.error("failed to create blit pipeline")
		return
	}

	// Develop: the darkroom transition (fx), a blit variant with its own
	// fragment uniforms; takes over the 2D blit for ~1s on scene switch.
	develop_pipeline := create_pipeline(
		gpu,
		window,
		shader_glue.develop_vertex(),
		shader_glue.develop_fragment(),
	)
	if develop_pipeline == nil {
		log.error("failed to create develop transition pipeline")
		return
	}
	develop_t := f32(1) // 1 = done (normal blit)
	fx_prev_scene := -1

	// 3D heightfield view of the same offscreen texture (button in UI).
	blit3d_vertex_glue := shader_glue.blit3d_vertex()
	blit3d_fragment_glue := shader_glue.blit3d_fragment()
	blit3d_vs := create_shader(gpu, blit3d_vertex_glue, .VERTEX)
	blit3d_fs := create_shader(gpu, blit3d_fragment_glue, .FRAGMENT)
	free_blob_if_hot(blit3d_vertex_glue)
	free_blob_if_hot(blit3d_fragment_glue)
	if blit3d_vs == nil || blit3d_fs == nil {
		if blit3d_vs != nil do sdl.ReleaseGPUShader(gpu, blit3d_vs)
		if blit3d_fs != nil do sdl.ReleaseGPUShader(gpu, blit3d_fs)
		log.error("failed to create blit3d shaders")
		return
	}
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
	)
	sdl.ReleaseGPUShader(gpu, blit3d_vs)
	sdl.ReleaseGPUShader(gpu, blit3d_fs)
	if blit3d_pipeline == nil {
		log.errorf("failed to create blit3d pipeline: %s", sdl.GetError())
		return
	}
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
	)
	if blit_sampler == nil {
		log.errorf("failed to create blit sampler: %s", sdl.GetError())
		return
	}

	ui := ui_init()
	if force3d do ui.params.view3d = true
	if pixel_test do ui.pixel_inspect_enabled = true
	if force_color do ui.params.color = true
	// Sound effects layer (fx_sound.odin): synthesizes the blips once;
	// fx_settings points at the live toggles.
	fx_settings = &ui.fx
	fx_sfx_init()

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
	imgui_gpu_ok := im_sdlgpu.Init(&imgui_init)
	if !imgui_gpu_ok {
		log.error("failed to initialize ImGui SDL_GPU backend")
		return
	}
	ied := ied_init()
	ing := ing_init()

	// The application (app.odin): everything that happens is a Msg,
	// applied in update; effects run through the interpreter below.
	app := App {
		ui  = ui,
		sm  = &scene_mgr,
		ed  = ied,
		ing = ing,
		win = window,
	}
	// The pan test needs the canvas unobstructed; the editor window
	// (restored open from imgui.ini) would hover over it.
	if pan_test do ied.open = false
	// The editor self-test drives the component directly; surface its
	if start_graph {
		ui.mode = .GRAPH
		ied.open = false
		ui.graph_max = true
	}
	if ied_selftest do ied.open = true
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
		if paper_textures[i] == nil {
			log.errorf("required paper texture could not be loaded: %s", path)
			return
		}
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
			if tex == nil {
				log.warnf("skipping skybox that could not be loaded: %s", entry.fullpath)
				continue
			}
			append(&skybox_names, strings.clone(name))
			append(&skybox_textures, tex)
		}
	}
	black_texture := create_black_texture(gpu)
	if black_texture == nil {
		log.errorf("failed to create pipeline fallback texture: %s", sdl.GetError())
		return
	}

	// All models in assets/models (+ generated icosphere fallback) for
	// model-viewer scenes; picked in the UI "model" group.
	models := model_load_all(gpu)
	if len(models) == 0 || models[0].vb == nil {
		log.error("no usable model could be loaded or generated")
		return
	}
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
	)
	if paper_sampler == nil {
		log.errorf("failed to create paper sampler: %s", sdl.GetError())
		return
	}

	// The panel grain background (fx): since ImGui 1.92.2 the sdlgpu3
	// backend expects a raw SDL_GPUTexture* as TextureID (it builds the
	// sampler binding itself), so we hand it the paper texture directly.
	fx_grain_binding = rawptr(paper_textures[0])

	// Offscreen texture presented by the viewport plus one stable target per
	// reflected pass. The JSON pipeline chooses which target is the output.
	scene_tex: ^sdl.GPUTexture
	tex_w, tex_h: i32
	depth_tex: ^sdl.GPUTexture
	pass_tex: [dynamic]^sdl.GPUTexture

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
	pixel_readback: PixelReadback
	benchmark_frame := 0
	benchmark_cpu_samples: [dynamic]f32
	benchmark_gpu_samples: [dynamic]f32
	debug_watch_buffer: ^sdl.GPUBuffer
	debug_watch_readback: DebugWatchReadback
	debug_watch_frame: u32
	pass_pixel_readback: PassPixelReadback

	set_title :: proc(window: ^sdl.Window, title: string) {
		if !sdl.SetWindowTitle(window, fmt.ctprint("shader_explorer · ", title)) {
			log.warnf("failed to update window title: %s", sdl.GetError())
		}
	}

	set_title(window, scene_mgr.scenes[scene_mgr.current].title)

	app_time: f32
	ui.time = &app_time
	prev_ticks := sdl.GetTicks()
	main_loop: for {
		// Reset the temp allocator every frame: every tprintf, file scan
		frame_counter_start := sdl.GetPerformanceCounter()
		// and JSON parse allocates into it, and without this it only ever
		// grows (the "memory keeps climbing" leak). Stored strings use
		// clones or fixed buffers, never temp.
		free_all(context.temp_allocator)

		scene_poll(&scene_mgr, gpu)
		pipeline_scene_refresh(&scene_mgr.scenes[scene_mgr.current])
		pixel_rgba, pixel_x, pixel_y, pixel_ready := pixel_readback_poll(&pixel_readback, gpu)
		if pixel_ready {
			ui.pixel_inspect_pending = false
			ui.pixel_inspect_valid = true
			ui.pixel_x, ui.pixel_y = pixel_x, pixel_y
			ui.pixel_rgba = pixel_rgba
			ui.debug_watch_request = true
			ui.debug_watch_sampled = false
			ui.debug_provenance_valid = {}
			ui.debug_provenance_rgba = {}
			ui.debug_provenance_path = pipeline_plan_path(
				&scene_mgr.scenes[scene_mgr.current].pipeline,
				len(scene_mgr.scenes[scene_mgr.current].passes),
			)
			if pixel_test {
				log.infof(
					"[pixel-test] pixel=(%d,%d) uv=(%.4f,%.4f) rgba=(%.3f,%.3f,%.3f,%.3f)",
					ui.pixel_x, ui.pixel_y,
					ui.pixel_uv[0], ui.pixel_uv[1],
					ui.pixel_rgba[0], ui.pixel_rgba[1], ui.pixel_rgba[2], ui.pixel_rgba[3],
				)
				if !watch_test do break main_loop
			}
		}
		watch_samples, watches_ready := debug_watch_readback_poll(&debug_watch_readback, gpu)
		if watches_ready {
			ui.debug_watch_pending = false
			ui.debug_watch_sampled = true
			ui.debug_watches = watch_samples
			if watch_test {
				for watch, record_index in ui.debug_watches {
					if !watch.valid do continue
					slot := record_index % DEBUG_WATCH_COUNT
					label := "?"
					if len(scene_mgr.scenes) > 0 && int(watch.pass) < len(scene_mgr.scenes[scene_mgr.current].passes) {
						watch_label := scene_mgr.scenes[scene_mgr.current].passes[watch.pass].debug_watch_labels[slot]
						if watch_label != "" do label = watch_label
					}
					log.infof(
						"[watch-test] slot=%d label=%s pass=%d type=%d value=(%.4f,%.4f,%.4f,%.4f)",
						slot, label, watch.pass, watch.type,
						watch.value[0], watch.value[1], watch.value[2], watch.value[3],
					)
				}
				watch_test_watches_ready = true
			}
		}
		provenance_changed, provenance_complete := pass_pixel_readback_poll(&pass_pixel_readback, gpu)
		if provenance_changed {
			ui.debug_provenance_valid = pass_pixel_readback.valid
			ui.debug_provenance_rgba = pass_pixel_readback.rgba
		}
		if provenance_complete {
			ui.debug_provenance_pending = false
			if watch_test && watch_test_watches_ready {
				path := pipeline_plan_path(&scene_mgr.scenes[scene_mgr.current].pipeline, len(scene_mgr.scenes[scene_mgr.current].passes))
				for pass, i in scene_mgr.scenes[scene_mgr.current].passes {
					if i >= DEBUG_WATCH_MAX_PASSES || !path[i] || !pass_pixel_readback.valid[i] do continue
					value := pass_pixel_readback.rgba[i]
					log.infof(
						"[provenance-test] pass=%d name=%s rgba=(%.4f,%.4f,%.4f,%.4f)",
						i, pass.name, value[0], value[1], value[2], value[3],
					)
				}
				break main_loop
			}
		}
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
					emit(SaveAll{})
					continue
				}
				if event.key.key == sdl.K_B && (event.key.mod & sdl.KMOD_GUI) != {} {
					// Toggle the whole sidebar (VS Code's Cmd+B).
					emit(ToggleSidebar{})
					continue
				}
				if event.key.key == sdl.K_MINUS && (event.key.mod & sdl.KMOD_ALT) != {} {
					// Option+'-': jump back through the cursor position
					// history (file, line, column).
					ied_nav_back(ied)
					continue
				}
				#partial switch event.key.scancode {
				case .F1:
					// The shader editor is a floating window, separate
					// from the sidebar by design.
					ied.open = !ied.open
				case .F3:
					// Theater mode: one-shortcut recording composition
					// (demo videos). Sidebar slides out, editor opens
					// docked right, type grows. Everything restores.
					emit(ToggleTheater{})
				case .F2:
					// Toggle glass mode on the code editor (transparency
					// configurable in the settings gear popup).
					ied.bg_transparent = !ied.bg_transparent
					ite_set_glass(ied.handle, ied.bg_transparent, ied.glass_alpha)
				case .ESCAPE:
					if !imgui_kb do break main_loop
				case .SPACE:
					if !imgui_kb {
						// Zen mode: hide the sidebar and the editor. The
						// title bar stays: it is the window chrome now.
						emit(ToggleZen{})
					}
				case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
					if !imgui_kb {
						n := int(event.key.scancode) - int(sdl.Scancode._1)
						emit(SceneSelected(n))
					}
				}
			case .KEY_UP:
				if event.key.key == sdl.K_LGUI || event.key.key == sdl.K_RGUI {
					ied_gui_held = false
				} else if event.key.key == sdl.K_LSHIFT || event.key.key == sdl.K_RSHIFT {
					ied_shift_held = false
				}
			}

			if event.type == .MOUSE_BUTTON_DOWN &&
			   event.button.button == sdl.BUTTON_LEFT &&
			   ui.pixel_inspect_enabled &&
			   !ui.pixel_inspect_pending &&
			   !imgui_mouse &&
			   !ui.captures_mouse {
				ui.pixel_request_pos = {event.button.x, event.button.y}
				ui.pixel_inspect_request = true
				ui.pixel_inspect_valid = false
			}

			// Orbit camera input (3D view only; left-drag rotates, wheel zooms).
			if ui.params.view3d && !ui.pixel_inspect_enabled && !imgui_mouse {
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
			   !ui.pixel_inspect_enabled &&
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

		// (Re)create offscreen targets before ImGui records preview TexIDs.
		pass_count := len(scene_mgr.scenes[scene_mgr.current].passes)
		if scene_tex == nil || tex_w != width || tex_h != height || len(pass_tex) != pass_count {
			if pixel_readback.pending do pixel_readback_cancel(&pixel_readback, gpu)
			if debug_watch_readback.pending do debug_watch_readback_cancel(&debug_watch_readback, gpu)
			if pass_pixel_readback.pending do pass_pixel_readback_cancel(&pass_pixel_readback, gpu)
			ui.pixel_inspect_pending = false
			ui.debug_watch_pending = false
			if scene_tex != nil do sdl.ReleaseGPUTexture(gpu, scene_tex)
			scene_tex = create_scene_target(gpu, width, height)
			if scene_tex == nil {
				log.errorf("failed to create scene texture %dx%d: %s", width, height, sdl.GetError())
				break main_loop
			}
			for t in pass_tex do if t != nil do sdl.ReleaseGPUTexture(gpu, t)
			clear(&pass_tex)
			for _ in 0 ..< pass_count {
				t := create_scene_target(gpu, width, height)
				if t == nil {
					log.errorf("failed to create pass texture %dx%d: %s", width, height, sdl.GetError())
					break main_loop
				}
				append(&pass_tex, t)
			}
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
			)
			if depth_tex == nil {
				log.errorf("failed to create depth texture %dx%d: %s", width, height, sdl.GetError())
				break main_loop
			}
			tex_w, tex_h = width, height
		}

		// ImGui frame: Controls + editor panel build their widgets here; the
		// draw data is rendered after the blit pass below.
		im_sdlgpu.NewFrame()
		im_sdl.NewFrame()
		if pan_test {
			// Fake the cursor hovering the node canvas (panel spans x
			// 46..46+52% of the window, below the 38px title bar) and, for
			// a stretch of frames, wheel deltas as a trackpad sends them.
			// Queued after the backend's NewFrame so its (possibly stale)
			// mouse-pos event doesn't override the fake one.
			w, h: i32
			sdl.GetWindowSize(window, &w, &h)
			im.IO_AddMousePosEvent(io, f32(46) + f32(w) * 0.26, f32(h) * 0.55)
			if pan_test_frame >= 10 && pan_test_frame < 40 {
				im.IO_AddMouseWheelEvent(io, 0.5, 0.8)
			}
			pan_test_frame += 1
		}
		im.NewFrame()
		// Node previews sample the previous frame's per-pass outputs.
		ing_pass_tex = pass_tex[:]
		ing_scene_tex = scene_tex
		ing_provenance_valid = ui.debug_provenance_valid
		ing_provenance_path = ui.debug_provenance_path
		ing_provenance_rgba = ui.debug_provenance_rgba
		ing_output_pass = scene_mgr.scenes[scene_mgr.current].pipeline.output_pass
		ing_runtime_pipeline_error = scene_mgr.scenes[scene_mgr.current].pipeline_error
		ing_n_passes = pass_count
		ui_build(ui, &scene_mgr, window, ied, ing, width, height)
		// The editor follows the active scene (its tab plus every imported
		// module) and keeps its background work (LSP sync, diagnostics)
		// flowing whether or not its window is visible.
		ied_open_scene(ied, scene_mgr.scenes[scene_mgr.current].title)
		ied_tick(ied)
		ied_frame(ied, &ui.fx)

		// Message pump (app.odin): every action queued by widgets or
		// events this frame is applied in update; the interpreter below
		// executes the resulting effects. Exports wait for their frame
		// point (scene_tex must hold the current frame first).
		cmds: Cmds
		quit := false
		export_pending: ExportRequest = .NONE
		for msg_count > 0 {
			m := msg_buf[0]
			msg_count -= 1
			for i in 0 ..< msg_count do msg_buf[i] = msg_buf[i + 1]
			cmds += update(&app, m)
		}
		for c in cmds {
			switch c {
			case .QUIT:
			if debug_watch_readback.pending {
				debug_watch_readback_cancel(&debug_watch_readback, gpu)
				ui.debug_watch_pending = false
				ui.debug_watch_sampled = false
			}
				quit = true
			case .MINIMIZE:
				sdl.MinimizeWindow(window)
			case .FULLSCREEN_ON:
				sdl.SetWindowFullscreen(window, true)
			case .FULLSCREEN_OFF:
				sdl.SetWindowFullscreen(window, false)
			case .SAVE_ALL:
				if n := ied_save_all(ied); n > 0 {
					// Save feedback on the floppy icon itself (amber
					// flash + check draw-in), plus the kalimba blip.
					ui.save_flash = 1
					fx_sfx_play(.SAVE)
				}
			case .EXPORT_PNG:
				export_pending = .PNG
			case .EXPORT_GIF:
				export_pending = .GIF
			case .DEVELOP:
				if fx_on(&ui.fx) && ui.fx.develop {
					develop_t = 0
				}
			}
		}
		if quit do break main_loop
		requested_scene := scene_mgr.current
		if scene_mgr.current != current {
			if pixel_readback.pending do pixel_readback_cancel(&pixel_readback, gpu)
			if debug_watch_readback.pending do debug_watch_readback_cancel(&debug_watch_readback, gpu)
			if pass_pixel_readback.pending do pass_pixel_readback_cancel(&pass_pixel_readback, gpu)
			ui.pixel_inspect_pending = false
			ui.pixel_inspect_valid = false
			ui.pixel_inspect_request = false
			ui.debug_watch_pending = false
			ui.debug_watch_sampled = false
			ui.debug_watch_request = false
			ui.debug_provenance_pending = false
			ui.debug_provenance_valid = {}
			ui.debug_provenance_path = {}
		}
		if requested_scene != current && !scene_ensure_loaded(&scene_mgr, gpu, requested_scene) {
			log.errorf("keeping scene %s because %s could not be loaded", scene_mgr.scenes[current].title, scene_mgr.scenes[requested_scene].title)
			scene_mgr.current = current
		}

		// FX trigger: any scene change (whatever the Msg path) runs the
		// develop transition, an ink burst at the scene selector, and the
		// per-change bookkeeping.
		if fx_prev_scene < 0 do fx_prev_scene = scene_mgr.current
		if scene_mgr.current != fx_prev_scene {
			fx_prev_scene = scene_mgr.current
			model_orbiting = false
			set_title(window, scene_mgr.scenes[scene_mgr.current].title)
			gen_initialized = false
			if fx_on(&ui.fx) && ui.fx.develop {
				develop_t = 0
			}
			fx_sfx_play(.SCENE_SWITCH)
			r := ui.scene_sel_rect
			fx_burst(&ui.fx, {(r[0] + r[2]) / 2, (r[1] + r[3]) / 2}, 60, 26, 220)
		}
		// Messages may have switched the scene this frame (update applied
		// them); refresh the local before rendering.
		if pixel_test && !ui.pixel_inspect_pending && !ui.pixel_inspect_valid {
			ui.pixel_request_pos = pixel_test_pos
			ui.pixel_inspect_request = true
		}
		current = scene_mgr.current
		if show_metrics {
			im.ShowMetricsWindow(nil)
		}
		// Error/notice toasts (SDL asserts, build failures) draw over
		// everything else, top-right. The self-test re-fires every second
		// so captures at any moment show all three kinds.
		if notify_test {
			notify_test_frame += 1
			if notify_test_frame % 60 == 1 {
				notify(.INFO, "notify test: info")
				notify(.WARN, "notify test: warning")
				notify(.ERROR, "notify test: error")
			}
		}
		notify_draw(io.DeltaTime)
		im.Render()

		ticks := sdl.GetTicks()
		dt := f32(ticks - prev_ticks) / 1000
		prev_ticks = ticks
		if !ui.params.paused {
			app_time += dt
		}
		// Advance the develop transition (paused clock or not: it is UI
		// chrome, not scene state).
		if develop_t < 1 {
			dur := f32(1.0) if ui.fx.intensity == .FULL else f32(0.7)
			develop_t = min(1, develop_t + dt / dur)
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
		mouse_click := .LEFT in buttons && !ui.captures_mouse && !ui.pixel_inspect_enabled

		camera_yaw := app_time * 0.4
		camera_pitch: f32 = 0.55
		if ui.params.interaction == .MOUSE_ROTATE {
			camera_yaw = model_yaw
			camera_pitch = model_pitch
		}
		camera := camera_orbit(camera_yaw, camera_pitch, f32(width) / f32(height))

		if scene_has_debug_watches(&scene_mgr.scenes[current]) && debug_watch_buffer == nil {
			debug_watch_buffer = sdl.CreateGPUBuffer(
				gpu,
				{
					usage = {.GRAPHICS_STORAGE_READ, .COMPUTE_STORAGE_WRITE},
					size = DEBUG_WATCH_BUFFER_SIZE,
				},
			)
			if debug_watch_buffer == nil {
				log.errorf("failed to create debug watch buffer: %s", sdl.GetError())
				break main_loop
			}
		}
		debug_watch_frame += 1
		debug_enabled := ui.pixel_inspect_valid && scene_has_debug_watches(&scene_mgr.scenes[current])
		debug_pixel_top := [2]i32{
			clamp(ui.pixel_x, 0, width - 1),
			clamp(ui.pixel_y, 0, height - 1),
		}
		scene_write_uniforms(
			&scene_mgr.scenes[current], {f32(width), f32(height)},
			app_time,
			ui.params.color,
			mouse_pos,
			mouse_click,
			&camera,
			debug_enabled,
			debug_pixel_top,
			debug_watch_frame,
		)

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
			if benchmark_frames > 0 && benchmark_frame >= benchmark_warmup && len(benchmark_gpu_samples) < benchmark_frames {
				append(&benchmark_gpu_samples, sample)
			}
		}
		// log.infof("gen %.3f ms", ui.gen_ms)

		// Shared resources for the frame (depth_tex recreates on resize).
		res := SceneResources {
			depth_tex       = depth_tex,
			sampler         = paper_sampler,
			paper_textures  = paper_textures[:],
			paper_index     = ui.params.paper,
			skybox_textures = skybox_textures[:],
			skybox_index    = ui.params.skybox,
			model           = &models[min(ui.params.model_index, len(models) - 1)],
			pass_tex        = pass_tex[:],
			black_texture   = black_texture,
			debug_watch_buffer = debug_watch_buffer,
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
			if pending_fence == nil {
				log.errorf("failed to submit scene frame: %s", sdl.GetError())
				break main_loop
			}
		}
		if ui.debug_watch_request {
			ui.debug_watch_request = false
			ui.debug_watch_sampled = false
			if scene_has_debug_watches(&scene_mgr.scenes[current]) && debug_watch_buffer != nil {
				if debug_watch_readback_begin(&debug_watch_readback, gpu, debug_watch_buffer, debug_watch_frame) {
					ui.debug_watch_pending = true
				}
			} else {
				ui.debug_watch_pending = false
				ui.debug_watch_sampled = true
				ui.debug_watches = {}
			}
			if pass_pixel_readback_begin(
				&pass_pixel_readback,
				gpu,
				&scene_mgr.scenes[current],
				scene_tex,
				&res,
				ui.pixel_x,
				ui.pixel_y,
				width,
				height,
			) {
				ui.debug_provenance_pending = true
			}
		}
		if ui.pixel_inspect_request {
			px := clamp(i32(ui.pixel_request_pos[0] * scale), i32(0), width - 1)
			py := clamp(i32(ui.pixel_request_pos[1] * scale), i32(0), height - 1)
			ui.pixel_inspect_request = false
			if pixel_readback_begin(&pixel_readback, gpu, scene_tex, px, py, width, height) {
				ui.pixel_inspect_pending = true
				ui.pixel_x, ui.pixel_y = px, py
				frag_x := f32(px) + 0.5
				frag_y := f32(height) - (f32(py) + 0.5)
				ui.pixel_uv = {frag_x / f32(width), frag_y / f32(height)}
				ui.pixel_scene_uv = {
					(frag_x - 0.5 * f32(width)) / f32(height),
					(frag_y - 0.5 * f32(height)) / f32(height),
				}
			}
		}

		// Frame export: download the just-submitted scene texture and exit.
		if shot_path != "" {
			save_texture_png(gpu, scene_tex, width, height, shot_path)
			break main_loop
		}

		// UI export buttons: scene_tex now holds the current frame.
		#partial switch export_pending {
		case .PNG:
			path := export_path(scene_mgr.scenes[current].title, "png")
			if save_texture_png(gpu, scene_tex, width, height, path) {
				log.infof("saved %s", path)
				fx_sfx_play(.EXPORT)
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
				ui.gif_start,
				ui.gif_end,
			)
			fx_sfx_play(.EXPORT)
		}

		// Graphics passes: blit the texture, then the UI overlay.
		frame_ok := true
		{
			cmd := sdl.AcquireGPUCommandBuffer(gpu)
			if cmd == nil {
				log.errorf("failed to acquire graphics command buffer: %s", sdl.GetError())
				break main_loop
			}
			defer {
				if !sdl.SubmitGPUCommandBuffer(cmd) {
					log.errorf("failed to submit graphics command buffer: %s", sdl.GetError())
					frame_ok = false
				}
			}

			swapchain_texture: ^sdl.GPUTexture
			if !sdl.WaitAndAcquireGPUSwapchainTexture(
				cmd,
				window,
				&swapchain_texture,
				nil,
				nil,
			) {
				log.errorf("failed to acquire swapchain texture: %s", sdl.GetError())
				frame_ok = false
			}

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
					if develop_t < 1 {
						sdl.BindGPUGraphicsPipeline(render_pass, develop_pipeline)
						variant := i32(0)
						if ui.fx.develop_style == .RANDOM {
							variant = i32(rand.int_max(3))
						} else {
							variant = i32(ui.fx.develop_style) - 1 // enum starts after RANDOM
						}
						r := ui.scene_sel_rect
						du := shader_glue.DevelopFragmentU {
							t       = develop_t,
							time    = app_time,
							res     = {f32(width), f32(height)},
							variant = variant,
							origin  = {
								(r[0] + r[2]) * 0.5 / f32(width),
								(r[1] + r[3]) * 0.5 / f32(height),
							},
						}
						sdl.PushGPUFragmentUniformData(
							cmd,
							shader_glue.DEVELOP_FRAGMENT_U.location.slot,
							&du,
							shader_glue.DEVELOP_FRAGMENT_U.size,
						)
					} else {
						sdl.BindGPUGraphicsPipeline(render_pass, blit_pipeline)
					}
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
		if !frame_ok do break main_loop

		latency_report()
		if benchmark_frames > 0 {
			frame_counter_end := sdl.GetPerformanceCounter()
			if benchmark_frame >= benchmark_warmup && len(benchmark_cpu_samples) < benchmark_frames {
				cpu_ms := f32(f64(frame_counter_end - frame_counter_start) / f64(sdl.GetPerformanceFrequency()) * 1000)
				append(&benchmark_cpu_samples, cpu_ms)
			}
			benchmark_frame += 1
			if benchmark_debug {
				ui.pixel_inspect_valid = true
				ui.pixel_x, ui.pixel_y = width / 2, height / 2
			}
			if len(benchmark_cpu_samples) >= benchmark_frames && len(benchmark_gpu_samples) >= benchmark_frames {
				mode := benchmark_debug ? "debug" : "baseline"
				benchmark_log(fmt.tprintf("cpu mode=%s scene=%s", mode, scene_mgr.scenes[current].title), benchmark_cpu_samples[:])
				benchmark_log(fmt.tprintf("gpu mode=%s scene=%s", mode, scene_mgr.scenes[current].title), benchmark_gpu_samples[:])
				break main_loop
			}
		}
		if once do break main_loop
	}

	for t in pass_tex do if t != nil do sdl.ReleaseGPUTexture(gpu, t)
	if black_texture != nil do sdl.ReleaseGPUTexture(gpu, black_texture)
	if pass_pixel_readback.pending do pass_pixel_readback_cancel(&pass_pixel_readback, gpu)
	if debug_watch_readback.pending do debug_watch_readback_cancel(&debug_watch_readback, gpu)
	if debug_watch_buffer != nil do sdl.ReleaseGPUBuffer(gpu, debug_watch_buffer)
	if pixel_readback.pending do pixel_readback_cancel(&pixel_readback, gpu)
	ite_destroy(ied.handle)
	im_sdlgpu.Shutdown()
	im_sdl.Shutdown()
	im.DestroyContext()
	log.info("Exiting")
}
