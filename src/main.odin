package main

import goose "../vendor/goose/src"
import shader_glue "./generated"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import sdl "vendor:sdl3"

// Inktober procedural shaders: every prompt is a scene on keys 1-9. Every
// scene is a COMPUTE shader writing an offscreen texture; a single
// graphics blit pipeline samples it, and the UI overlay draws on top.
// Texture generation time is measured per frame with a GPU fence,
// accumulated, and shown as an average in the UI.
//
// Built with -define:HOT_RELOAD:true (`make run` / `make debug`) the glue
// loads shader code from disk per call and src/hotreload.odin swaps
// pipelines on .slang edits.

HOT_RELOAD :: #config(HOT_RELOAD, false)

Scene :: struct {
	title:    string,
	pipeline: ^sdl.GPUComputePipeline,
	glue:     proc() -> goose.ComputeParameters,
}

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

create_compute_pipeline :: proc(
	gpu: ^sdl.GPUDevice,
	glue_proc: proc() -> goose.ComputeParameters,
) -> ^sdl.GPUComputePipeline {
	parameters := glue_proc()
	defer when HOT_RELOAD {
		if parameters.code.blob.size > 0 {
			delete(parameters.code.blob.data[:parameters.code.blob.size])
		}
	}
	resources := parameters.resources
	pipeline := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = parameters.code.blob.data,
			code_size = parameters.code.blob.size,
			entrypoint = parameters.code.entrypoint,
			format = parameters.code.format == .MetalSource ? {.MSL} : {.SPIRV},
			num_samplers = resources.samplers,
			num_readonly_storage_textures = resources.readonly_storage_textures,
			num_readonly_storage_buffers = resources.readonly_storage_buffers,
			num_readwrite_storage_textures = resources.readwrite_storage_textures,
			num_readwrite_storage_buffers = resources.readwrite_storage_buffers,
			num_uniform_buffers = resources.uniform_buffers,
			threadcount_x = parameters.thread_count.x,
			threadcount_y = parameters.thread_count.y,
			threadcount_z = parameters.thread_count.z,
		},
	)
	if pipeline == nil {
		fmt.eprintfln("failed to create compute pipeline %s", parameters.code.name)
	}
	return pipeline
}

main :: proc() {
	once := false
	start_scene := 0
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
		}
	}

	ok := sdl.Init({.VIDEO}); assert(ok)
	window := sdl.CreateWindow("Inktober — procedural shaders", 800, 600, {})
	assert(window != nil)
	gpu := sdl.CreateGPUDevice({.SPIRV, .MSL, .DXBC, .DXIL}, true, nil)
	assert(gpu != nil)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

	// Every scene is named after its compute shader file; one per inktober
	// prompt. Add the shader to src/shaders, goose.json, and this list.
	scenes := [1]Scene {
		{title = "apple", glue = shader_glue.apple_compute},
	}
	for &scene in scenes {
		scene.pipeline = create_compute_pipeline(gpu, scene.glue)
		assert(scene.pipeline != nil)
	}

	scene_names: [1]string
	for scene, i in scenes {
		scene_names[i] = scene.title
	}

	// Overlay descriptions (top-center panel, max 5 lines each): what the
	// scene shows, what the colors mean, and any controls that affect it.
	scene_descriptions := [1]string {
		"Inktober day 1: apple.\nProcedural ink apple on grained paper.\n'color' = shaded red apple instead of black ink.\nSliders drive paper grain and edge wobble.",
	}

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

	ui := ui_init(gpu, window)
	if force3d do ui.params.view3d = true
	if force_color do ui.params.color = true

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

	// Texture generation timing: fence per frame, EMA of submit→completion.
	pending_fence: ^sdl.GPUFence
	fence_t0: u64
	gen_initialized := false

	set_title :: proc(window: ^sdl.Window, title: string) {
		ok := sdl.SetWindowTitle(window, fmt.ctprint("Inktober — ", title))
		assert(ok)
	}

	current := start_scene
	ui_open := true
	set_title(window, scenes[current].title)

	watcher: HotReload
	app_time: f32
	prev_ticks := sdl.GetTicks()
	main_loop: for {
		hot_reload_poll(&watcher, gpu, scenes[:])

		width, height: i32
		sdl.GetWindowSizeInPixels(window, &width, &height)

		event: sdl.Event
		for sdl.PollEvent(&event) {
			ui_handle_event(ui, event)
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch event.key.scancode {
				case .ESCAPE:
					break main_loop
				case .SPACE:
					ui_open = !ui_open
					if !ui_open do ui.captures_mouse = false
				case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
					n := int(event.key.scancode) - int(sdl.Scancode._1)
					if n < len(scenes) {
						current = n
						set_title(window, scenes[current].title)
						gen_initialized = false
					}
				}
			}

			// Orbit camera input (3D view only; left-drag rotates, wheel zooms).
			if ui.params.view3d {
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
		}

		scene_request := -1
		if ui_open {
			scene_request = ui_build(
				ui,
				current,
				scene_names[:],
				scene_descriptions[:],
				width,
				height,
			)
			if scene_request >= 0 {
				current = scene_request
				set_title(window, scenes[current].title)
				gen_initialized = false
			}
		} else {
			ui.captures_mouse = false
		}

		ticks := sdl.GetTicks()
		dt := f32(ticks - prev_ticks) / 1000
		prev_ticks = ticks
		if !ui.params.paused {
			app_time += dt
		}

		win_w, win_h: i32
		sdl.GetWindowSize(window, &win_w, &win_h)
		ui.scale = f32(width) / f32(win_w)

		uniform_block := shader_glue.AppleComputeUniforms {
			iResolution = {f32(width), f32(height), 1},
			iTime       = app_time,
			iFbm        = {ui.params.octaves, ui.params.lacunarity, ui.params.gain, 0},
			iColorMode  = ui.params.color ? 1 : 0,
			iManual     = 1,
		}

		// (Re)create the offscreen texture on resize.
		if scene_tex == nil || tex_w != width || tex_h != height {
			if scene_tex != nil do sdl.ReleaseGPUTexture(gpu, scene_tex)
			scene_tex = sdl.CreateGPUTexture(
				gpu,
				{
					type = .D2,
					format = .R8G8B8A8_UNORM,
					usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE},
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
				ui.gen_ms = 0.95*ui.gen_ms + 0.05*sample
			}
		}
		fmt.printfln("gen %.3f ms", ui.gen_ms)

		// Compute pass: the scene renders the offscreen texture, timed by fence.
		{
			tex_binding := sdl.GPUStorageTextureReadWriteBinding {
				texture = scene_tex,
				cycle   = true,
			}
			cmd := sdl.AcquireGPUCommandBuffer(gpu)
			compute_pass := sdl.BeginGPUComputePass(cmd, &tex_binding, 1, nil, 0)
			pipeline := scenes[current].pipeline
			sdl.BindGPUComputePipeline(compute_pass, pipeline)
			sdl.PushGPUComputeUniformData(
				cmd,
				shader_glue.APPLE_COMPUTE_UNIFORMS.location.slot,
				&uniform_block,
				shader_glue.APPLE_COMPUTE_UNIFORMS.size,
			)
			sdl.DispatchGPUCompute(compute_pass, u32((width + 7) / 8), u32((height + 7) / 8), 1)
			sdl.EndGPUComputePass(compute_pass)
			fence_t0 = sdl.GetPerformanceCounter()
			pending_fence = sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
			assert(pending_fence != nil)
		}

		// Frame export: download the just-submitted scene texture and exit.
		if shot_path != "" {
			save_texture_png(gpu, scene_tex, width, height, shot_path)
			break main_loop
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
					to_origin := [3]f32{origin.x - camPos.x, origin.y - camPos.y, origin.z - camPos.z}
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

				if ui_open {
					ui_build_geometry(ui, width, height)
					ui_upload(ui, gpu, cmd)
					ui_draw(ui, gpu, cmd, swapchain_texture, width, height)
				}
			}
		}

		if once do break main_loop
	}

	fmt.println("Exiting")
}
