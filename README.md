# Shader Explorer

A desktop live-coding environment for learning and experimenting with real-time GPU
shaders: no windowing, buffers, or pipeline boilerplate between you and the first
pixel. Scenes are plain [Slang](https://shader-slang.org/) files discovered from a
folder; saving a file recompiles it incrementally on a background thread and hot-swaps
the pipeline. A failed build never blanks the screen: the last working pipeline stays
up and the error comes back into the editor as an annotation.

![status](https://img.shields.io/badge/status-research%20prototype-orange)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23150234.svg)](https://doi.org/10.5281/zenodo.23150234)

## Features

- **Zero-boilerplate scenes**: a scene is a folder with a `.slang` file in
  `src/shaders/scenes/`; it appears in the app automatically. Ships a designed
  ten-scene learning trail (`01_hello_pixel` … `10_multipass`, one concept per
  scene with live "Try:" exercises) plus older development fixtures.
- **Selective builds**: startup and hot reload compile only the active scene,
  its `pass_*.slang` modules, and imported utilities. Other scene titles stay in
  the catalog and are compiled when selected.
- **Language-server editing**: the code editor embeds `slangd`, the official Slang
  language server: diagnostics, hover docs, go-to-definition, rename, completion.
- **Reflection-checked pipeline graph**: reflection derives typed ports from the
  Slang declarations; `graph.json` stores the executable pass topology. Creating
  or detaching an edge in the node editor changes the runtime pipeline after a
  confirmation step. Invalid JSON, cycles, duplicate producers, missing outputs,
  or incompatible endpoints keep the last valid pipeline active.
- **Failure-preserving hot reload**: dependency-tracked incremental builds on a
  worker thread; broken code keeps the previous pipeline on screen.
- **Assets**: OBJ model loading and texture import (stb_image); scene templates for
  compute / 2D / 3D graphics.
- **Visual debugging**: `debug_scalar`, `debug_signed`, `debug_vector`,
  `debug_normal`, `debug_mask`, `debug_nan_inf`, compiler squiggles, async
  1×1 pixel inspection, eight GPU-watch slots per pass, multipass pixel
  provenance, and restore to the last loadable source version.
- **Cross-platform GPU**: built on the SDL3 GPU API (Metal on macOS, SPIR-V/Vulkan
  on Linux/Windows). Currently validated on macOS/Metal (Apple Silicon).

## Requirements

- [Odin](https://odin-lang.org/) `dev-2026-08` or newer
- [SDL3](https://wiki.libsdl.org/SDL3) (Odin's `vendor:sdl3` bindings)
- The [goose](https://github.com/LucasGobbs/goose) shader-build toolkit checked out
  as a **sibling directory** (`git clone https://github.com/LucasGobbs/goose ../goose`);
  override with `GOOSE_DIR=/path/to/goose`
- A C++17 toolchain (`clang++`) for the vendored editor/node-graph wrappers

Slang (`slangc`, `slangd`) and all UI libraries are vendored under `vendor/`.

## Build & run

```sh
make shaders   # bake scene artifacts (slangc, both msl and spv targets)
make run       # release build + run (hot reload enabled)
make debug     # debug build (main_debug)
```

Optional leak investigation build:

```sh
odin build ./src -define:HOT_RELOAD=true -define:MEM_TRACE=true -debug -out:main_memtrace
# heap allocations still live at exit are dumped with their allocation sites
```

## Layout

```
src/
  main.odin            app loop, GPU device, blit, frame orchestration
  scene_runtime.odin   scene discovery, async incremental builds, reflection parsing
  pipeline.odin        graph.json schema, validation, DAG plan, last-known-good
  imgui_editor.odin    code editor UI (ImGuiColorTextEdit + slangd LSP client)
  imgui_nodes.odin     node editor (imnodes), reflection-driven pins, layout
  scene_templates.odin new-scene templates
  shaders/scenes/      the scene corpus (one folder per scene)
vendor/                slang, odin-imgui, ImGuiColorTextEdit, imnodes, fonts
```

## Editable pipeline graph

Each scene may persist `graph.json`. Shader source remains authoritative for pass
interfaces; reflection supplies the available typed pins. JSON links are
authoritative for execution order and resource routing:

```json
{
  "version": 1,
  "scene": "10_multipass",
  "links": [
    {
      "from": "comp:scenes/10_multipass/10_multipass:computeMain:out_tex",
      "to": "comp:scenes/10_multipass/pass_1:computeMain:input_tex"
    },
    {
      "from": "comp:scenes/10_multipass/pass_1:computeMain:out_tex",
      "to": "show2d:frame"
    }
  ]
}
```

The runtime topologically sorts the pass DAG and allocates a stable output target
for every pass. The editor stages `connect`/`disconnect`, displays the endpoints,
and writes JSON only after confirmation. A disconnected `input_tex` samples a
black fallback; reconnecting restores the producer without editing either shader.

## GPU debug watches

Enable **Debug → pixel inspector**, then click the scene. Instrument up to eight
`float`, `float2`, `float3`, or `float4` expressions in each pass:

```slang
// Fragment shader
debug_watch_fragment(0, color, uint2(input.gl_FragCoord.xy), Uniforms);

// Compute shader
debug_watch_compute(0, value, id.xy, Uniforms);
```

Only the selected fragment or dispatch thread writes. Records are indexed by
`pass × slot`, copied asynchronously after the frame, and shown on the next
frame. Labels (`color`, `value`) are extracted from the source expression;
strings never cross the GPU boundary. The same selection downloads the output
pixel from every upstream pass and displays its causal chain in the Debug panel
and graph nodes. Scenes `01_hello_pixel`, `09_compute`, and `10_multipass` are
working examples. `./main_debug --scene 10 --watch-test 400 300` exercises
selection, multipass GPU writes, readback, type, pass, label, and provenance.

## Measuring edit→pixel latency

Every hot reload logs a line:

```
[INFO ] [latency] edit->pixel: 582.1 ms
```

(measured from build request to the first submitted frame; median ≈ 0.58 s
across the corpus on an Apple M4. This endpoint does not include display
presentation, and the compiler/reflection/pipeline cost breakdown is not yet profiled.)

## Reproducing technical benchmarks

`--benchmark N` records N release-frame samples after a 60-frame warm-up;
`--benchmark-debug N` selects the center invocation so watches write once per
instrumented pass. When supported, the app requests SDL GPU `IMMEDIATE` present.

```sh
make build
./main --scene 1  --benchmark 300
./main --scene 1  --benchmark-debug 300
./main --scene 9  --benchmark 300
./main --scene 9  --benchmark-debug 300
./main --scene 10 --benchmark 300
./main --scene 10 --benchmark-debug 300
```

The CPU metric is the full application frame. The GPU-labelled metric is scene
submit→fence and includes queue wait; it is not a hardware timestamp query.

## License

MIT (see LICENSE). Vendored components keep their own licenses.
