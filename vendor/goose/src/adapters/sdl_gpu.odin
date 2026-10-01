package adapters

import goose ".."
import sdl "vendor:sdl3"

// Maps goose vertex formats to SDL_GPU vertex element formats.
vertex_format :: proc(format: goose.VertexFormat) -> sdl.GPUVertexElementFormat {
	#partial switch format {
	case .Int:
		return .INT
	case .Int2:
		return .INT2
	case .Int3:
		return .INT3
	case .Int4:
		return .INT4
	case .Uint:
		return .UINT
	case .Uint2:
		return .UINT2
	case .Uint3:
		return .UINT3
	case .Uint4:
		return .UINT4
	case .Float:
		return .FLOAT
	case .Float2:
		return .FLOAT2
	case .Float3:
		return .FLOAT3
	case .Float4:
		return .FLOAT4
	case .Sint8x2:
		return .BYTE2
	case .Sint8x4:
		return .BYTE4
	case .Uint8x2:
		return .UBYTE2
	case .Uint8x4:
		return .UBYTE4
	case .Snorm8x2:
		return .BYTE2_NORM
	case .Snorm8x4:
		return .BYTE4_NORM
	case .Unorm8x2:
		return .UBYTE2_NORM
	case .Unorm8x4:
		return .UBYTE4_NORM
	case .Sint16x2:
		return .SHORT2
	case .Sint16x4:
		return .SHORT4
	case .Uint16x2:
		return .USHORT2
	case .Uint16x4:
		return .USHORT4
	case .Snorm16x2:
		return .SHORT2_NORM
	case .Snorm16x4:
		return .SHORT4_NORM
	case .Unorm16x2:
		return .USHORT2_NORM
	case .Unorm16x4:
		return .USHORT4_NORM
	case .Float16x2:
		return .HALF2
	case .Float16x4:
		return .HALF4
	}
	return .INVALID
}

// Converts goose-reflected vertex attributes into the SDL_GPU array expected
// by GPUGraphicsPipelineCreateInfo.vertex_input_state.
convert_vertex_attributes :: proc(
	attributes: []goose.VertexAttribute,
	allocator := context.allocator,
) -> []sdl.GPUVertexAttribute {
	result := make([]sdl.GPUVertexAttribute, len(attributes), allocator)
	for attribute, index in attributes {
		format := vertex_format(attribute.format)
		assert(format != .INVALID, "Goose vertex format is unsupported by SDL GPU")
		result[index] = {
			location    = attribute.location,
			buffer_slot = attribute.buffer_slot,
			format      = format,
			offset      = attribute.offset,
		}
	}
	return result
}
