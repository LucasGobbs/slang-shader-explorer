#+build darwin

package adapters

import goose ".."
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

metal_vertex_format :: proc(format: goose.VertexFormat) -> MTL.VertexFormat {
	#partial switch format {
	case .Int: return .Int
	case .Int2: return .Int2
	case .Int3: return .Int3
	case .Int4: return .Int4
	case .Uint: return .UInt
	case .Uint2: return .UInt2
	case .Uint3: return .UInt3
	case .Uint4: return .UInt4
	case .Float: return .Float
	case .Float2: return .Float2
	case .Float3: return .Float3
	case .Float4: return .Float4
	case .Sint8: return .Char
	case .Sint8x2: return .Char2
	case .Sint8x3: return .Char3
	case .Sint8x4: return .Char4
	case .Uint8: return .UChar
	case .Uint8x2: return .UChar2
	case .Uint8x3: return .UChar3
	case .Uint8x4: return .UChar4
	case .Snorm8: return .CharNormalized
	case .Snorm8x2: return .Char2Normalized
	case .Snorm8x3: return .Char3Normalized
	case .Snorm8x4: return .Char4Normalized
	case .Unorm8: return .UCharNormalized
	case .Unorm8x2: return .UChar2Normalized
	case .Unorm8x3: return .UChar3Normalized
	case .Unorm8x4: return .UChar4Normalized
	case .Sint16: return .Short
	case .Sint16x2: return .Short2
	case .Sint16x3: return .Short3
	case .Sint16x4: return .Short4
	case .Uint16: return .UShort
	case .Uint16x2: return .UShort2
	case .Uint16x3: return .UShort3
	case .Uint16x4: return .UShort4
	case .Snorm16: return .ShortNormalized
	case .Snorm16x2: return .Short2Normalized
	case .Snorm16x3: return .Short3Normalized
	case .Snorm16x4: return .Short4Normalized
	case .Unorm16: return .UShortNormalized
	case .Unorm16x2: return .UShort2Normalized
	case .Unorm16x3: return .UShort3Normalized
	case .Unorm16x4: return .UShort4Normalized
	case .Float16: return .Half
	case .Float16x2: return .Half2
	case .Float16x3: return .Half3
	case .Float16x4: return .Half4
	case .Snorm1010102: return .Int1010102Normalized
	case .Unorm1010102: return .UInt1010102Normalized
	}
	return .Invalid
}

metal_apply_vertex_attributes :: proc(
	descriptor: ^MTL.VertexDescriptor,
	attributes: []goose.VertexAttribute,
) {
	assert(descriptor != nil)
	array := descriptor->attributes()
	for attribute in attributes {
		format := metal_vertex_format(attribute.format)
		assert(format != .Invalid)
		native := array->object(NS.UInteger(attribute.location))
		native->setFormat(format)
		native->setOffset(NS.UInteger(attribute.offset))
		native->setBufferIndex(NS.UInteger(attribute.buffer_slot))
	}
}
