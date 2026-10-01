#+build windows

package adapters

import goose ".."
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

direct3d_vertex_format :: proc(format: goose.VertexFormat) -> dxgi.FORMAT {
	#partial switch format {
	case .Int: return .R32_SINT
	case .Int2: return .R32G32_SINT
	case .Int3: return .R32G32B32_SINT
	case .Int4: return .R32G32B32A32_SINT
	case .Uint: return .R32_UINT
	case .Uint2: return .R32G32_UINT
	case .Uint3: return .R32G32B32_UINT
	case .Uint4: return .R32G32B32A32_UINT
	case .Float: return .R32_FLOAT
	case .Float2: return .R32G32_FLOAT
	case .Float3: return .R32G32B32_FLOAT
	case .Float4: return .R32G32B32A32_FLOAT
	case .Sint8x2: return .R8G8_SINT
	case .Sint8x4: return .R8G8B8A8_SINT
	case .Uint8x2: return .R8G8_UINT
	case .Uint8x4: return .R8G8B8A8_UINT
	case .Snorm8x2: return .R8G8_SNORM
	case .Snorm8x4: return .R8G8B8A8_SNORM
	case .Unorm8x2: return .R8G8_UNORM
	case .Unorm8x4: return .R8G8B8A8_UNORM
	case .Sint16x2: return .R16G16_SINT
	case .Sint16x4: return .R16G16B16A16_SINT
	case .Uint16x2: return .R16G16_UINT
	case .Uint16x4: return .R16G16B16A16_UINT
	case .Snorm16x2: return .R16G16_SNORM
	case .Snorm16x4: return .R16G16B16A16_SNORM
	case .Unorm16x2: return .R16G16_UNORM
	case .Unorm16x4: return .R16G16B16A16_UNORM
	case .Float16x2: return .R16G16_FLOAT
	case .Float16x4: return .R16G16B16A16_FLOAT
	case .Unorm1010102: return .R10G10B10A2_UNORM
	}
	return .UNKNOWN
}

Direct3DVertexSemantic :: struct {
	name:  cstring,
	index: u32,
}

direct3d_convert_vertex_attributes :: proc(
	attributes: []goose.VertexAttribute,
	semantics: []Direct3DVertexSemantic,
	allocator := context.allocator,
) -> []d3d11.INPUT_ELEMENT_DESC {
	assert(len(attributes) == len(semantics))
	result := make([]d3d11.INPUT_ELEMENT_DESC, len(attributes), allocator)
	for attribute, index in attributes {
		format := direct3d_vertex_format(attribute.format)
		assert(format != .UNKNOWN)
		result[index] = {
			SemanticName = semantics[index].name,
			SemanticIndex = semantics[index].index,
			Format = format,
			InputSlot = attribute.buffer_slot,
			AlignedByteOffset = attribute.offset,
			InputSlotClass = .VERTEX_DATA,
		}
	}
	return result
}
