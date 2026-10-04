package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import gltf "vendor:cgltf"
import sdl "vendor:sdl3"

// Default 3D model for model-viewer scenes. At startup the app loads the
// first .glb/.gltf found in assets/ (cgltf) and interleaves
// POSITION/NORMAL/TEXCOORD_0 into the fixed vertex layout below; without
// a file it falls back to a generated UV sphere, so a default model
// always exists. Graphics scenes whose vertex entry takes a [[stage_in]]
// struct get this model drawn indexed (see scene_runtime.odin); the
// buffers also carry COMPUTE_STORAGE_READ for compute scenes later.

MODEL_PITCH   :: 32 // bytes per vertex: float3 + float3 + float2
MODEL_OFF_POS :: 0
MODEL_OFF_NRM :: 12
MODEL_OFF_UV  :: 24

Model :: struct {
	vb, ib:      ^sdl.GPUBuffer,
	index_count: u32,
	name:        string, // UI label (from filename or "icosphere")
	source:      string, // file path or generator note
}

// Attribute offsets in the fixed model layout, by shader attribute
// location: 0 = position, 1 = normal, 2 = uv.
model_attr_offset :: proc(location: int) -> (u32, bool) {
	switch location {
	case 0:
		return MODEL_OFF_POS, true
	case 1:
		return MODEL_OFF_NRM, true
	case 2:
		return MODEL_OFF_UV, true
	}
	return 0, false
}

// Recenters and rescales interleaved vertices so the model fits the
// unit sphere (max radius 1 from its bounds center). Required for
// real-world meshes like the dragon, which are not unit-sized.
model_normalize_bounds :: proc(vertices: []u8) {
	n := len(vertices) / MODEL_PITCH
	if n == 0 do return
	min_v := [3]f32{1e30, 1e30, 1e30}
	max_v := [3]f32{-1e30, -1e30, -1e30}
	for i in 0 ..< n {
		p := ([^]f32)(&vertices[i * MODEL_PITCH])
		for c in 0 ..< 3 {
			min_v[c] = min(min_v[c], p[c])
			max_v[c] = max(max_v[c], p[c])
		}
	}
	center := [3]f32 {
		(min_v[0] + max_v[0]) / 2,
		(min_v[1] + max_v[1]) / 2,
		(min_v[2] + max_v[2]) / 2,
	}
	max_r: f32 = 1e-30
	for i in 0 ..< n {
		p := ([^]f32)(&vertices[i * MODEL_PITCH])
		d := p[0] - center[0]
		e := p[1] - center[1]
		f := p[2] - center[2]
		r := d * d + e * e + f * f
		max_r = max(max_r, r)
	}
	scale := 1 / math.sqrt(max_r)
	for i in 0 ..< n {
		p := ([^]f32)(&vertices[i * MODEL_PITCH])
		p[0] = (p[0] - center[0]) * scale
		p[1] = (p[1] - center[1]) * scale
		p[2] = (p[2] - center[2]) * scale
	}
}

model_upload :: proc(gpu: ^sdl.GPUDevice, vertices: []u8, indices: []u32, source: string) -> Model {
	model: Model
	model.source = source
	model.index_count = u32(len(indices))

	vb := sdl.CreateGPUBuffer(
		gpu,
		{usage = {.VERTEX, .COMPUTE_STORAGE_READ}, size = u32(len(vertices))},
	)
	ib := sdl.CreateGPUBuffer(
		gpu,
		{usage = {.INDEX, .COMPUTE_STORAGE_READ}, size = u32(len(indices) * 4)},
	)
	if vb == nil || ib == nil {
		if vb != nil do sdl.ReleaseGPUBuffer(gpu, vb)
		if ib != nil do sdl.ReleaseGPUBuffer(gpu, ib)
		log.errorf("model: failed to create buffers for %s: %s", source, sdl.GetError())
		return model
	}
	model.vb = vb
	model.ib = ib

	total := len(vertices) + len(indices) * 4
	upload := sdl.CreateGPUTransferBuffer(gpu, {usage = .UPLOAD, size = u32(total)})
	if upload == nil {
		log.errorf("model: failed to create upload buffer for %s: %s", source, sdl.GetError())
		sdl.ReleaseGPUBuffer(gpu, vb)
		sdl.ReleaseGPUBuffer(gpu, ib)
		return {}
	}
	defer sdl.ReleaseGPUTransferBuffer(gpu, upload)
	ptr := sdl.MapGPUTransferBuffer(gpu, upload, false)
	if ptr == nil {
		log.errorf("model: failed to map upload buffer for %s: %s", source, sdl.GetError())
		sdl.ReleaseGPUBuffer(gpu, vb)
		sdl.ReleaseGPUBuffer(gpu, ib)
		return {}
	}
	verts_dst := ([^]u8)(ptr)
	idx_dst := ([^]u32)(uintptr(ptr) + uintptr(len(vertices)))
	for b, i in vertices do verts_dst[i] = b
	for v, i in indices do idx_dst[i] = v
	sdl.UnmapGPUTransferBuffer(gpu, upload)

	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = upload, offset = 0},
		{buffer = vb, offset = 0, size = u32(len(vertices))},
		false,
	)
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = upload, offset = u32(len(vertices))},
		{buffer = ib, offset = 0, size = u32(len(indices) * 4)},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		log.errorf("model: failed to submit upload for %s: %s", source, sdl.GetError())
		sdl.ReleaseGPUBuffer(gpu, vb)
		sdl.ReleaseGPUBuffer(gpu, ib)
		return {}
	}
	return model
}

// Loads every .glb/.gltf in assets/models plus the generated icosphere
// as a fallback entry, sorted by filename. Names come from the files.
model_load_all :: proc(gpu: ^sdl.GPUDevice) -> [dynamic]Model {
	models: [dynamic]Model
	entries, err := os.read_directory_by_path("assets/models", 0, context.temp_allocator)
	if err == nil {
		paths: [dynamic]string
		defer delete(paths)
		for entry in entries {
			lower := strings.to_lower(entry.name, context.temp_allocator)
			if strings.has_suffix(lower, ".glb") || strings.has_suffix(lower, ".gltf") {
				append(&paths, strings.clone(entry.fullpath))
			}
		}
		slice.sort(paths[:])
		for path in paths {
			if model, ok := model_load_gltf(gpu, path); ok {
				base := filepath.base(path)
				dot := strings.last_index(base, ".")
				if dot > 0 do base = base[:dot]
				model.name = strings.clone(base)
				append(&models, model)
				log.infof("model: loaded %s", path)
			}
		}
	}
	if len(models) == 0 {
		log.info("model: no .glb/.gltf in assets/models/, using generated icosphere")
	}
	fallback := model_load_sphere(gpu)
	fallback.name = "icosphere"
	append(&models, fallback)
	return models
}

model_load_gltf :: proc(gpu: ^sdl.GPUDevice, path: string) -> (Model, bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	options: gltf.options
	data, res := gltf.parse_file(options, path_c)
	if res != .success || data == nil {
		log.errorf("model: failed to parse %s", path)
		return {}, false
	}
	defer gltf.free(data)
	if gltf.load_buffers(options, data, path_c) != .success {
		log.errorf("model: failed to load buffers of %s", path)
		return {}, false
	}

	vertices: [dynamic]u8
	indices: [dynamic]u32
	defer delete(vertices)
	defer delete(indices)

	for mesh in data.meshes {
		for prim in mesh.primitives {
			if prim.type != .triangles do continue
			pos, nrm, uv: ^gltf.accessor
			for attr in prim.attributes {
				#partial switch attr.type {
				case .position:
					pos = attr.data
				case .normal:
					nrm = attr.data
				case .texcoord:
					uv = attr.data
				}
			}
			if pos == nil do continue

			// Unpack each attribute stream once, then interleave.
			count := int(pos.count)
			positions := make([]f32, count * 3, context.temp_allocator)
			_ = gltf.accessor_unpack_floats(pos, raw_data(positions), uint(count * 3))
			normals: []f32
			if nrm != nil {
				normals = make([]f32, count * 3, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(nrm, raw_data(normals), uint(count * 3))
			}
			uvs: []f32
			if uv != nil {
				uvs = make([]f32, count * 2, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(uv, raw_data(uvs), uint(count * 2))
			}

			base := u32(len(vertices) / MODEL_PITCH)
			for i in 0 ..< count {
				vtx: [MODEL_PITCH]u8
				put3 :: proc(v: ^[MODEL_PITCH]u8, off: int, x, y, z: f32) {
					(^f32)(&v[off + 0])^ = x
					(^f32)(&v[off + 4])^ = y
					(^f32)(&v[off + 8])^ = z
				}
				put3(&vtx, MODEL_OFF_POS, positions[i*3], positions[i*3+1], positions[i*3+2])
				if normals != nil {
					put3(&vtx, MODEL_OFF_NRM, normals[i*3], normals[i*3+1], normals[i*3+2])
				}
				if uvs != nil {
					(^f32)(&vtx[MODEL_OFF_UV + 0])^ = uvs[i*2]
					(^f32)(&vtx[MODEL_OFF_UV + 4])^ = uvs[i*2+1]
				}
				append(&vertices, ..vtx[:])
			}
			if prim.indices != nil {
				for i in 0 ..< int(prim.indices.count) {
					append(&indices, base + u32(gltf.accessor_read_index(prim.indices, uint(i))))
				}
			} else {
				for i in 0 ..< count {
					append(&indices, base + u32(i))
				}
			}
		}
	}
	if len(indices) == 0 {
		log.errorf("model: %s has no triangles", path)
		return {}, false
	}
	model_normalize_bounds(vertices[:])
	return model_upload(gpu, vertices[:], indices[:], path), true
}

// Icosphere fallback: subdivided icosahedron. Uniform triangles, no
// pole singularity and no UV seam — UV spheres show cap seams and sliver
// artifacts under shading; an icosphere avoids the whole class.
model_load_sphere :: proc(gpu: ^sdl.GPUDevice) -> Model {
	SUBDIV :: 4
	PHI :: 1.6180339887498948482
	base_verts := [12][3]f32 {
		{-1, PHI, 0}, {1, PHI, 0}, {-1, -PHI, 0}, {1, -PHI, 0},
		{0, -1, PHI}, {0, 1, PHI}, {0, -1, -PHI}, {0, 1, -PHI},
		{PHI, 0, -1}, {PHI, 0, 1}, {-PHI, 0, -1}, {-PHI, 0, 1},
	}
	faces := [20][3]u32 {
		{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
		{1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
		{3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
		{4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
	}

	normalize :: proc(v: [3]f32) -> [3]f32 {
		l := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		return {v.x / l, v.y / l, v.z / l}
	}
	verts: [dynamic][3]f32
	defer delete(verts)
	for v in base_verts do append(&verts, normalize(v))

	indices: [dynamic]u32
	defer delete(indices)
	for f in faces do append(&indices, f[0], f[1], f[2])
	when SUBDIV > 0 {
	for level in 1 ..= SUBDIV {
		// Split every triangle at its edge midpoints (normalized back to
		// the unit sphere); winding follows the parent face.
		next_verts: [dynamic][3]f32
		next_indices: [dynamic]u32
		push_v :: proc(list: ^[dynamic][3]f32, v: [3]f32) -> u32 {
			append(list, v)
			return u32(len(list) - 1)
		}
		for i := 0; i < len(indices); i += 3 {
			a := verts[indices[i]]
			b := verts[indices[i + 1]]
			c := verts[indices[i + 2]]
			ab := normalize({(a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2})
			bc := normalize({(b.x + c.x) / 2, (b.y + c.y) / 2, (b.z + c.z) / 2})
			ca := normalize({(c.x + a.x) / 2, (c.y + a.y) / 2, (c.z + a.z) / 2})
			ia := push_v(&next_verts, a)
			ib := push_v(&next_verts, b)
			ic := push_v(&next_verts, c)
			iab := push_v(&next_verts, ab)
			ibc := push_v(&next_verts, bc)
			ica := push_v(&next_verts, ca)
			append(&next_indices, ia, iab, ica, ib, ibc, iab, ic, ica, ibc, iab, ibc, ica)
		}
		clear(&verts)
		append(&verts, ..next_verts[:])
		delete(next_verts)
		clear(&indices)
		append(&indices, ..next_indices[:])
		delete(next_indices)
	}
	}

	vertices: [dynamic]u8
	defer delete(vertices)
	write_f :: proc(v: ^[MODEL_PITCH]u8, off: int, val: f32) {
		(^f32)(&v[off])^ = val
	}
	for p in verts {
		u := math.atan2(p.z, p.x) / (2 * math.PI) + 0.5
		v := math.acos(clamp(p.y, -1, 1)) / math.PI
		vtx: [MODEL_PITCH]u8
		write_f(&vtx, MODEL_OFF_POS + 0, p.x)
		write_f(&vtx, MODEL_OFF_POS + 4, p.y)
		write_f(&vtx, MODEL_OFF_POS + 8, p.z)
		write_f(&vtx, MODEL_OFF_NRM + 0, p.x)
		write_f(&vtx, MODEL_OFF_NRM + 4, p.y)
		write_f(&vtx, MODEL_OFF_NRM + 8, p.z)
		write_f(&vtx, MODEL_OFF_UV + 0, u)
		write_f(&vtx, MODEL_OFF_UV + 4, v)
		append(&vertices, ..vtx[:])
	}
	return model_upload(gpu, vertices[:], indices[:], "generated icosphere")
}
