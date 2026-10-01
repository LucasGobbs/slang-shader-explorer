package goose

Platform :: enum {
	Metal,
	Vulkan,
	Direct3D,
}

CodeFormat :: enum {
	MetalSource,
	MetalLibrary,
	Spirv,
	HlslSource,
}

Stage :: enum {
	Vertex,
	Fragment,
	Compute,
}

Blob :: struct {
	data: [^]u8,
	size: uint,
}

Code :: struct {
	name:       string,
	entrypoint: cstring,
	platform:   Platform,
	format:     CodeFormat,
	blob:       Blob,
}

BindingTable :: struct {
	data:  [^]Binding,
	count: u32,
}

GraphicsResourceCounts :: struct {
	samplers:         u32,
	storage_textures: u32,
	storage_buffers:  u32,
	uniform_buffers:  u32,
}

GraphicsParameters :: struct {
	code:      Code,
	stage:     Stage,
	resources: GraphicsResourceCounts,
	bindings:  BindingTable,
}

ComputeResourceCounts :: struct {
	samplers:                   u32,
	readonly_storage_textures:  u32,
	readonly_storage_buffers:   u32,
	readwrite_storage_textures: u32,
	readwrite_storage_buffers:  u32,
	uniform_buffers:            u32,
}

ComputeParameters :: struct {
	code:         Code,
	resources:    ComputeResourceCounts,
	bindings:     BindingTable,
	thread_count: [3]u32,
}

VertexFormat :: enum {
	Int,
	Int2,
	Int3,
	Int4,
	Uint,
	Uint2,
	Uint3,
	Uint4,
	Float,
	Float2,
	Float3,
	Float4,
	Sint8,
	Sint8x2,
	Sint8x3,
	Sint8x4,
	Uint8,
	Uint8x2,
	Uint8x3,
	Uint8x4,
	Snorm8,
	Snorm8x2,
	Snorm8x3,
	Snorm8x4,
	Unorm8,
	Unorm8x2,
	Unorm8x3,
	Unorm8x4,
	Sint16,
	Sint16x2,
	Sint16x3,
	Sint16x4,
	Uint16,
	Uint16x2,
	Uint16x3,
	Uint16x4,
	Snorm16,
	Snorm16x2,
	Snorm16x3,
	Snorm16x4,
	Unorm16,
	Unorm16x2,
	Unorm16x3,
	Unorm16x4,
	Float16,
	Float16x2,
	Float16x3,
	Float16x4,
	Snorm1010102,
	Unorm1010102,
}

VertexAttribute :: struct {
	location:    u32,
	buffer_slot: u32,
	format:      VertexFormat,
	offset:      u32,
}

BindingLocation :: struct {
	space:   u32,
	binding: u32,
	slot:    u32,
	count:   u32,
}

UniformBlock :: struct {
	stage:    Stage,
	location: BindingLocation,
	size:     u32,
}

TextureBinding :: struct {
	stage:    Stage,
	location: BindingLocation,
}

SamplerBinding :: struct {
	stage:    Stage,
	location: BindingLocation,
}


ResourceAccess :: enum {
	ReadOnly,
	ReadWrite,
}


BindingKind :: enum {
	UniformBuffer,
	Texture,
	Sampler,
	StorageBuffer,
	StorageTexture,
}

Binding :: struct {
	name:     string,
	stage:    Stage,
	kind:     BindingKind,
	access:   ResourceAccess,
	location: BindingLocation,
	size:     u32,
}
