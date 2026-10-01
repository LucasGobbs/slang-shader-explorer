package adapters

import goose ".."
import vk "vendor:vulkan"

vulkan_vertex_format :: proc(format: goose.VertexFormat) -> vk.Format {
	#partial switch format {
	case .Int: return .R32_SINT
	case .Int2: return .R32G32_SINT
	case .Int3: return .R32G32B32_SINT
	case .Int4: return .R32G32B32A32_SINT
	case .Uint: return .R32_UINT
	case .Uint2: return .R32G32_UINT
	case .Uint3: return .R32G32B32_UINT
	case .Uint4: return .R32G32B32A32_UINT
	case .Float: return .R32_SFLOAT
	case .Float2: return .R32G32_SFLOAT
	case .Float3: return .R32G32B32_SFLOAT
	case .Float4: return .R32G32B32A32_SFLOAT
	case .Sint8: return .R8_SINT
	case .Sint8x2: return .R8G8_SINT
	case .Sint8x3: return .R8G8B8_SINT
	case .Sint8x4: return .R8G8B8A8_SINT
	case .Uint8: return .R8_UINT
	case .Uint8x2: return .R8G8_UINT
	case .Uint8x3: return .R8G8B8_UINT
	case .Uint8x4: return .R8G8B8A8_UINT
	case .Snorm8: return .R8_SNORM
	case .Snorm8x2: return .R8G8_SNORM
	case .Snorm8x3: return .R8G8B8_SNORM
	case .Snorm8x4: return .R8G8B8A8_SNORM
	case .Unorm8: return .R8_UNORM
	case .Unorm8x2: return .R8G8_UNORM
	case .Unorm8x3: return .R8G8B8_UNORM
	case .Unorm8x4: return .R8G8B8A8_UNORM
	case .Sint16: return .R16_SINT
	case .Sint16x2: return .R16G16_SINT
	case .Sint16x3: return .R16G16B16_SINT
	case .Sint16x4: return .R16G16B16A16_SINT
	case .Uint16: return .R16_UINT
	case .Uint16x2: return .R16G16_UINT
	case .Uint16x3: return .R16G16B16_UINT
	case .Uint16x4: return .R16G16B16A16_UINT
	case .Snorm16: return .R16_SNORM
	case .Snorm16x2: return .R16G16_SNORM
	case .Snorm16x3: return .R16G16B16_SNORM
	case .Snorm16x4: return .R16G16B16A16_SNORM
	case .Unorm16: return .R16_UNORM
	case .Unorm16x2: return .R16G16_UNORM
	case .Unorm16x3: return .R16G16B16_UNORM
	case .Unorm16x4: return .R16G16B16A16_UNORM
	case .Float16: return .R16_SFLOAT
	case .Float16x2: return .R16G16_SFLOAT
	case .Float16x3: return .R16G16B16_SFLOAT
	case .Float16x4: return .R16G16B16A16_SFLOAT
	case .Unorm1010102: return .A2B10G10R10_UNORM_PACK32
	}
	return .UNDEFINED
}

vulkan_convert_vertex_attributes :: proc(
	attributes: []goose.VertexAttribute,
	allocator := context.allocator,
) -> []vk.VertexInputAttributeDescription {
	result := make([]vk.VertexInputAttributeDescription, len(attributes), allocator)
	for attribute, index in attributes {
		format := vulkan_vertex_format(attribute.format)
		assert(format != .UNDEFINED)
		result[index] = {
			location = attribute.location,
			binding = attribute.buffer_slot,
			format = format,
			offset = attribute.offset,
		}
	}
	return result
}
