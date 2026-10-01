package main

import goose "../.."
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

ResourceCounts :: struct {
	samplers:                   int,
	readonly_storage_textures:  int,
	readonly_storage_buffers:   int,
	readwrite_storage_textures: int,
	readwrite_storage_buffers:  int,
	uniform_buffers:            int,
}

ReflectionParameter :: struct {
	name:    string,
	type_:   json.Value `json:"type"`,
	binding: ReflectionBindingInfo,
}

ReflectionBindingInfo :: struct {
	kind:           string,
	index:          int,
	space:          int,
	used:           int,
	count:          int,
	offset:         int,
	size:           int,
	element_stride: int `json:"elementStride"`,
}

ReflectionBinding :: struct {
	name:    string,
	binding: ReflectionBindingInfo,
}

ReflectionEntryPoint :: struct {
	name:              string,
	stage:             string,
	thread_group_size: [3]int `json:"threadGroupSize"`,
	parameters:        []ReflectionParameter,
	bindings:          []ReflectionBinding,
}

ReflectionDocument :: struct {
	version:      string,
	parameters:   []ReflectionParameter,
	entry_points: []ReflectionEntryPoint `json:"entryPoints"`,
}

VertexAttribute :: struct {
	name:     string,
	format:   string,
	location: int,
}

UniformBlock :: struct {
	name:           string,
	slot:           int,
	space:          int,
	native_binding: int,
	type_:          json.Value,
	count:          int,
}

UniformField :: struct {
	name:         string,
	type_value:   json.Value,
	offset, size: int,
}

UniformEmitter :: struct {
	builder: strings.Builder,
	emitted: map[string]bool,
	prefix:  string,
	path:    string,
}

TextureBinding :: struct {
	name:           string,
	slot:           int,
	space:          int,
	native_binding: int,
	count:          int,
}

SamplerBinding :: struct {
	name:           string,
	slot:           int,
	space:          int,
	native_binding: int,
	count:          int,
}

StorageBinding :: struct {
	name:           string,
	slot:           int,
	space:          int,
	native_binding: int,
	count:          int,
	kind:           string,
	writable:       bool,
}
StageReflection :: struct {
	stage:             string,
	entrypoint:        string,
	counts:            ResourceCounts,
	thread_count:      [3]int,
	vertex_attributes: []VertexAttribute,
	uniform_blocks:    []UniformBlock,
	textures:          []TextureBinding,
	samplers:          []SamplerBinding,
	storage_resources: []StorageBinding,
}

Options :: struct {
	name:         string,
	package_name: string,
	goose_import: string,
	output:       string,
	reflections:  [dynamic]string,
	platform:     goose.Platform,
	check:        bool,
	platform_set: bool,
	hot_reload:   bool,
}

fatal :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

parse_options :: proc() -> Options {
	options: Options
	args := os.args[1:]
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch argument {
		case "--check":
			options.check = true
		case "--hot-reload":
			options.hot_reload = true
		case "--name", "--package", "--goose-import", "--output", "--reflection", "--platform":
			if index + 1 >= len(args) do fatal("missing value for %s", argument)
			index += 1
			value := args[index]
			switch argument {
			case "--name":
				options.name = value
			case "--package":
				options.package_name = value
			case "--goose-import":
				options.goose_import = value
			case "--output":
				options.output = value
			case "--reflection":
				append_elem(&options.reflections, value)
			case "--platform":
				switch value {
				case "metal":
					options.platform = .Metal
				case "vulkan":
					options.platform = .Vulkan
				case "direct3d":
					options.platform = .Direct3D
				case:
					fatal("unsupported Goose platform: %s", value)
				}
				options.platform_set = true
			}
		case:
			fatal("unknown argument: %s", argument)
		}
	}
	if options.name == "" do fatal("--name is required")
	if options.package_name == "" do fatal("--package is required")
	if options.goose_import == "" do fatal("--goose-import is required")
	if options.output == "" do fatal("--output is required")
	if len(options.reflections) == 0 do fatal("at least one --reflection is required")
	if !options.platform_set do fatal("--platform is required")
	return options
}

find_parameter :: proc(
	parameters: []ReflectionParameter,
	name: string,
) -> (
	^ReflectionParameter,
	bool,
) {
	for &parameter in parameters {
		if parameter.name == name do return &parameter, true
	}
	return nil, false
}

json_object :: proc(value: json.Value, description: string) -> json.Object {
	object, ok := value.(json.Object)
	if !ok do fatal("expected JSON object for %s", description)
	return object
}

json_array :: proc(value: json.Value, description: string) -> json.Array {
	array, ok := value.(json.Array)
	if !ok do fatal("expected JSON array for %s", description)
	return array
}

json_value :: proc(object: json.Object, key, description: string) -> json.Value {
	value, ok := object[key]
	if !ok do fatal("missing %s.%s", description, key)
	return value
}

json_string :: proc(object: json.Object, key, description: string, default := "") -> string {
	value, ok := object[key]
	if !ok do return default
	string_value, string_ok := value.(json.String)
	if !string_ok do fatal("expected string for %s.%s", description, key)
	return string(string_value)
}

json_int :: proc(object: json.Object, key, description: string, default := 0) -> int {
	value, ok := object[key]
	if !ok do return default
	integer, integer_ok := value.(json.Integer)
	if !integer_ok do fatal("expected integer for %s.%s", description, key)
	return int(integer)
}

vertex_format :: proc(path, field_name: string, type_value: json.Value) -> string {
	type_ := json_object(type_value, field_name)
	kind := json_string(type_, "kind", field_name)
	component_count := 1
	scalar_type := json_string(type_, "scalarType", field_name)
	if kind == "vector" {
		component_count = json_int(type_, "elementCount", field_name)
		element_type := json_object(json_value(type_, "elementType", field_name), field_name)
		scalar_type = json_string(element_type, "scalarType", field_name)
	} else if kind != "scalar" {
		fatal("%s: unsupported vertex type %s for %s", path, kind, field_name)
	}
	if component_count < 1 || component_count > 4 {
		fatal(
			"%s: unsupported vertex component count %d for %s",
			path,
			component_count,
			field_name,
		)
	}

	prefix := ""
	switch scalar_type {
	case "float32":
		prefix = "Float"
	case "int32":
		prefix = "Int"
	case "uint32":
		prefix = "Uint"
	case "float16":
		prefix = "Float16"
	case "int8":
		prefix = "Sint8"
	case "uint8":
		prefix = "Uint8"
	case "int16":
		prefix = "Sint16"
	case "uint16":
		prefix = "Uint16"
	case:
		fatal("%s: unsupported vertex scalar type %s for %s", path, scalar_type, field_name)
	}
	if scalar_type == "float32" || scalar_type == "int32" || scalar_type == "uint32" {
		if component_count == 1 do return fmt.tprintf(".%s", prefix)
		return fmt.tprintf(".%s%d", prefix, component_count)
	}
	if component_count == 1 do return fmt.tprintf(".%s", prefix)
	return fmt.tprintf(".%sx%d", prefix, component_count)
}

load_stage :: proc(path: string) -> StageReflection {
	context.allocator = context.temp_allocator
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do fatal("failed to read reflection %s: %v", path, read_error)
	document: ReflectionDocument
	unmarshal_error := json.unmarshal(data, &document, allocator = context.temp_allocator)
	if unmarshal_error != nil do fatal("failed to parse reflection %s: %v", path, unmarshal_error)
	if document.version != "1.1" do fatal("%s: unsupported reflection version %s", path, document.version)
	if len(document.entry_points) != 1 {
		fatal("%s: expected one entry point, found %d", path, len(document.entry_points))
	}
	entry := &document.entry_points[0]
	if entry.stage != "vertex" && entry.stage != "fragment" && entry.stage != "compute" {
		fatal("%s: unsupported stage %s", path, entry.stage)
	}
	uniform_blocks: [dynamic]UniformBlock
	textures: [dynamic]TextureBinding
	samplers: [dynamic]SamplerBinding
	storage_resources: [dynamic]StorageBinding
	counts: ResourceCounts
	for reflected_binding in entry.bindings {
		if reflected_binding.binding.used == 0 do continue
		parameter, found := find_parameter(document.parameters, reflected_binding.name)
		if !found do fatal("%s: unknown parameter %s", path, reflected_binding.name)
		type_ := json_object(parameter.type_, reflected_binding.name)
		kind := json_string(type_, "kind", reflected_binding.name)
		switch kind {
		case "constantBuffer", "uniform":
			append_elem(
				&uniform_blocks,
				UniformBlock {
					name = reflected_binding.name,
					slot = counts.uniform_buffers,
					space = parameter.binding.space,
					native_binding = parameter.binding.index,
					count = max(parameter.binding.count, 1),
					type_ = json_value(type_, "elementType", reflected_binding.name),
				},
			)
			counts.uniform_buffers += 1
		case "samplerState":
			append_elem(
				&samplers,
				SamplerBinding {
					name = reflected_binding.name,
					slot = len(samplers),
					space = parameter.binding.space,
					native_binding = parameter.binding.index,
					count = max(parameter.binding.count, 1),
				},
			)
		case "resource":
			access := json_string(type_, "access", reflected_binding.name, "read")
			base_shape := json_string(type_, "baseShape", reflected_binding.name)
			writable := access == "readWrite"
			if strings.starts_with(base_shape, "texture") {
				if writable {
					append_elem(
						&storage_resources,
						StorageBinding {
							name = reflected_binding.name,
							slot = counts.readwrite_storage_textures,
							space = parameter.binding.space,
							native_binding = parameter.binding.index,
							count = max(parameter.binding.count, 1),
							kind = "StorageTexture",
							writable = true,
						},
					)
					counts.readwrite_storage_textures += 1
				} else {
					append_elem(
						&textures,
						TextureBinding {
							name = reflected_binding.name,
							slot = len(textures),
							space = parameter.binding.space,
							native_binding = parameter.binding.index,
							count = max(parameter.binding.count, 1),
						},
					)
					counts.samplers += 1
				}
			} else if strings.contains(
				strings.to_lower(base_shape, context.temp_allocator),
				"buffer",
			) {
				if writable {
					append_elem(
						&storage_resources,
						StorageBinding {
							name = reflected_binding.name,
							slot = counts.readwrite_storage_buffers,
							space = parameter.binding.space,
							native_binding = parameter.binding.index,
							count = max(parameter.binding.count, 1),
							kind = "StorageBuffer",
							writable = true,
						},
					)
					counts.readwrite_storage_buffers += 1
				} else {
					append_elem(
						&storage_resources,
						StorageBinding {
							name = reflected_binding.name,
							slot = counts.readonly_storage_buffers,
							space = parameter.binding.space,
							native_binding = parameter.binding.index,
							count = max(parameter.binding.count, 1),
							kind = "StorageBuffer",
							writable = false,
						},
					)
					counts.readonly_storage_buffers += 1
				}
			} else {
				fatal("%s: unsupported resource shape %s", path, base_shape)
			}
		case:
			fatal("%s: unsupported parameter kind %s", path, kind)
		}
	}

	vertex_attributes: [dynamic]VertexAttribute
	if entry.stage == "vertex" {
		for parameter in entry.parameters {
			if parameter.binding.kind != "varyingInput" do continue
			parameter_type := json_object(parameter.type_, parameter.name)
			if json_string(parameter_type, "kind", parameter.name) != "struct" do continue
			fields := json_array(
				json_value(parameter_type, "fields", parameter.name),
				parameter.name,
			)
			for field_value in fields {
				field := json_object(field_value, parameter.name)
				field_name := json_string(field, "name", parameter.name)
				binding := json_object(json_value(field, "binding", field_name), field_name)
				if json_string(binding, "kind", field_name) != "varyingInput" {
					fatal("%s: vertex field %s has no varyingInput binding", path, field_name)
				}
				append_elem(
					&vertex_attributes,
					VertexAttribute {
						name = field_name,
						format = vertex_format(
							path,
							field_name,
							json_value(field, "type", field_name),
						),
						location = json_int(binding, "index", field_name),
					},
				)
			}
		}
		// A vertex stage may legitimately take no vertex-buffer inputs, e.g.
		// when positions come from SV_VertexID; then no attributes proc is emitted.
		for index in 1 ..< len(vertex_attributes) {
			for cursor := index;
			    cursor > 0 &&
			    vertex_attributes[cursor].location < vertex_attributes[cursor - 1].location;
			    cursor -= 1 {
				temporary := vertex_attributes[cursor]
				vertex_attributes[cursor] = vertex_attributes[cursor - 1]
				vertex_attributes[cursor - 1] = temporary
			}
		}
	}
	if entry.name == "" do fatal("%s: entry point has no name", path)
	if entry.stage == "compute" {
		for value in entry.thread_group_size {
			if value <= 0 do fatal("%s: invalid compute thread group size", path)
		}
	}
	return {
		stage = entry.stage,
		entrypoint = entry.name,
		counts = counts,
		thread_count = entry.thread_group_size,
		vertex_attributes = vertex_attributes[:],
		uniform_blocks = uniform_blocks[:],
		textures = textures[:],
		samplers = samplers[:],
		storage_resources = storage_resources[:],
	}
}

identifier :: proc(name: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte, index in transmute([]byte)name {
		value := byte
		is_letter := value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z'
		is_digit := value >= '0' && value <= '9'
		if is_letter {
			if value >= 'A' && value <= 'Z' do value += 'a' - 'A'
			strings.write_byte(&builder, value)
		} else if is_digit && index > 0 {
			strings.write_byte(&builder, value)
		} else {
			strings.write_byte(&builder, '_')
		}
	}
	return strings.to_string(builder)
}

uniform_size :: proc(type_value: json.Value, description: string) -> int {
	type_ := json_object(type_value, description)
	sizes := json_array(json_value(type_, "sizes", description), description)
	for size_value in sizes {
		size := json_object(size_value, description)
		if json_string(size, "kind", description) == "uniform" {
			return json_int(size, "value", description)
		}
	}
	fatal("no uniform size reflected for %s", description)
}

uniform_scalar_type :: proc(scalar_type, description: string) -> string {
	switch scalar_type {
	case "bool":
		return "bool"
	case "float16":
		return "f16"
	case "float32":
		return "f32"
	case "float64":
		return "f64"
	case "int8":
		return "i8"
	case "int16":
		return "i16"
	case "int32":
		return "i32"
	case "int64":
		return "i64"
	case "uint8":
		return "u8"
	case "uint16":
		return "u16"
	case "uint32":
		return "u32"
	case "uint64":
		return "u64"
	case:
		fatal("unsupported uniform scalar type %s for %s", scalar_type, description)
	}
}

uniform_scalar_size :: proc(scalar_type, description: string) -> int {
	switch scalar_type {
	case "bool", "int8", "uint8":
		return 1
	case "float16", "int16", "uint16":
		return 2
	case "float32", "int32", "uint32":
		return 4
	case "float64", "int64", "uint64":
		return 8
	case:
		fatal("unsupported uniform scalar type %s for %s", scalar_type, description)
	}
}

uniform_type_symbol :: proc(prefix: string, type_value: json.Value, fallback: string) -> string {
	type_ := json_object(type_value, fallback)
	reflected_name := json_string(type_, "name", fallback, fallback)
	type_name := strings.to_pascal_case(reflected_name, context.temp_allocator) or_else ""
	return fmt.tprintf("%s%s", prefix, type_name)
}

uniform_array_slot_symbol :: proc(prefix, fallback: string) -> string {
	name := strings.to_pascal_case(fallback, context.temp_allocator) or_else ""
	return fmt.tprintf("%s%sElement", prefix, name)
}

uniform_odin_type :: proc(prefix: string, type_value: json.Value, fallback: string) -> string {
	type_ := json_object(type_value, fallback)
	kind := json_string(type_, "kind", fallback)
	switch kind {
	case "scalar":
		return uniform_scalar_type(json_string(type_, "scalarType", fallback), fallback)
	case "vector":
		element := json_object(json_value(type_, "elementType", fallback), fallback)
		scalar := uniform_scalar_type(json_string(element, "scalarType", fallback), fallback)
		return fmt.tprintf("[%d]%s", json_int(type_, "elementCount", fallback), scalar)
	case "matrix":
		element := json_object(json_value(type_, "elementType", fallback), fallback)
		scalar := uniform_scalar_type(json_string(element, "scalarType", fallback), fallback)
		return fmt.tprintf(
			"matrix[%d, %d]%s",
			json_int(type_, "columnCount", fallback),
			json_int(type_, "rowCount", fallback),
			scalar,
		)
	case "struct":
		return uniform_type_symbol(prefix, type_value, fallback)
	case "array":
		element := json_value(type_, "elementType", fallback)
		count := json_int(type_, "elementCount", fallback)
		stride := json_int(
			type_,
			"uniformStride",
			fallback,
			uniform_native_size(element, fallback),
		)
		element_size := uniform_native_size(element, fallback)
		element_type := uniform_odin_type(prefix, element, fallback)
		if stride > element_size do element_type = uniform_array_slot_symbol(prefix, fallback)
		return fmt.tprintf("[%d]%s", count, element_type)
	case:
		fatal("unsupported uniform type %s for %s", kind, fallback)
	}
}

uniform_native_size :: proc(type_value: json.Value, description: string) -> int {
	type_ := json_object(type_value, description)
	kind := json_string(type_, "kind", description)
	switch kind {
	case "scalar":
		return uniform_scalar_size(json_string(type_, "scalarType", description), description)
	case "vector":
		element := json_value(type_, "elementType", description)
		return(
			json_int(type_, "elementCount", description) *
			uniform_native_size(element, description) \
		)
	case "matrix":
		element := json_value(type_, "elementType", description)
		return(
			json_int(type_, "rowCount", description) *
			json_int(type_, "columnCount", description) *
			uniform_native_size(element, description) \
		)
	case "struct":
		result := uniform_size(type_value, description)
		for field in uniform_fields(type_value, description) {
			result = max(result, field.offset + uniform_native_size(field.type_value, field.name))
		}
		return result
	case "array":
		element := json_value(type_, "elementType", description)
		stride := json_int(type_, "uniformStride", description, uniform_native_size(element, description))
		return json_int(type_, "elementCount", description) * stride
	case:
		fatal("unsupported uniform type %s for %s", kind, description)
	}
}

uniform_fields :: proc(type_value: json.Value, description: string) -> []UniformField {
	type_ := json_object(type_value, description)
	fields := json_array(json_value(type_, "fields", description), description)
	result := make([dynamic]UniformField, context.temp_allocator)
	for field_value in fields {
		field := json_object(field_value, description)
		name := json_string(field, "name", description)
		binding := json_object(json_value(field, "binding", name), name)
		append_elem(
			&result,
			UniformField {
				name = name,
				type_value = json_value(field, "type", name),
				offset = json_int(binding, "offset", name),
				size = json_int(binding, "size", name),
			},
		)
	}
	for index in 1 ..< len(result) {
		for cursor := index;
		    cursor > 0 && result[cursor].offset < result[cursor - 1].offset;
		    cursor -= 1 {
			temporary := result[cursor]
			result[cursor] = result[cursor - 1]
			result[cursor - 1] = temporary
		}
	}
	return result[:]
}

emit_uniform_array_type :: proc(
	emitter: ^UniformEmitter,
	type_value: json.Value,
	description: string,
) {
	type_ := json_object(type_value, description)
	if json_string(type_, "kind", description) != "array" do fatal("%s is not a uniform array", description)
	element := json_value(type_, "elementType", description)
	element_type := json_object(element, description)
	element_kind := json_string(element_type, "kind", description)
	if element_kind == "array" do fatal("nested uniform arrays are not supported for %s", description)
	if element_kind == "struct" {
		nested_symbol := uniform_type_symbol(emitter.prefix, element, description)
		emit_uniform_struct(emitter, element, nested_symbol, description)
	}
	stride := json_int(
		type_,
		"uniformStride",
		description,
		uniform_native_size(element, description),
	)
	element_size := uniform_native_size(element, description)
	if stride < element_size do fatal("uniform array stride is smaller than its element for %s", description)
	if stride == element_size do return

	symbol := uniform_array_slot_symbol(emitter.prefix, description)
	if emitter.emitted[symbol] do return
	emitter.emitted[symbol] = true
	odin_type := uniform_odin_type(emitter.prefix, element, description)
	fmt.sbprintf(
		&emitter.builder,
		`%s :: struct #max_field_align(16) {{
	value: %s,
	_padding: [%d]u8,
}}

#assert(offset_of(%s, value) == 0)
#assert(size_of(%s) == %d)

`,
		symbol,
		odin_type,
		stride - element_size,
		symbol,
		symbol,
		stride,
	)
}

emit_uniform_struct :: proc(
	emitter: ^UniformEmitter,
	type_value: json.Value,
	symbol, description: string,
) {
	if emitter.emitted[symbol] do return
	type_ := json_object(type_value, description)
	if json_string(type_, "kind", description) != "struct" {
		fatal("uniform block %s is not a struct", description)
	}
	fields := uniform_fields(type_value, description)
	for field in fields {
		field_type := json_object(field.type_value, field.name)
		field_kind := json_string(field_type, "kind", field.name)
		if field_kind == "struct" {
			nested_symbol := uniform_type_symbol(emitter.prefix, field.type_value, field.name)
			emit_uniform_struct(emitter, field.type_value, nested_symbol, field.name)
		} else if field_kind == "array" {
			emit_uniform_array_type(emitter, field.type_value, field.name)
		}
	}

	emitter.emitted[symbol] = true
	fmt.sbprintf(&emitter.builder, `%s :: struct #max_field_align(16) {{
`, symbol)
	cursor := 0
	padding_index := 0
	for field in fields {
		if field.offset < cursor do fatal("overlapping uniform field %s", field.name)
		if field.offset > cursor {
			fmt.sbprintf(
				&emitter.builder,
				`	_padding_%d: [%d]u8,
`,
				padding_index,
				field.offset - cursor,
			)
			padding_index += 1
		}
		field_type := uniform_odin_type(emitter.prefix, field.type_value, field.name)
		fmt.sbprintf(&emitter.builder, `	%s: %s,
`, field.name, field_type)
		native_size := uniform_native_size(field.type_value, field.name)
		effective_size := max(native_size, field.size)
		if native_size < field.size {
			fmt.sbprintf(
				&emitter.builder,
				`	_padding_%d: [%d]u8,
`,
				padding_index,
				field.size - native_size,
			)
			padding_index += 1
		}
		cursor = field.offset + effective_size
	}
	struct_size := max(uniform_size(type_value, description), cursor)
	if cursor < struct_size {
		fmt.sbprintf(
			&emitter.builder,
			`	_padding_%d: [%d]u8,
`,
			padding_index,
			struct_size - cursor,
		)
	}
	fmt.sbprintf(&emitter.builder, `}}

`)
	for field in fields {
		fmt.sbprintf(
			&emitter.builder,
			`#assert(offset_of(%s, %s) == %d)
`,
			symbol,
			field.name,
			field.offset,
		)
	}
	fmt.sbprintf(&emitter.builder, `#assert(size_of(%s) == %d)

`, symbol, struct_size)
}

emit_uniform_blocks :: proc(name, stage_name: string, blocks: []UniformBlock) -> string {
	if len(blocks) == 0 do return ""
	prefix := fmt.tprintf(
		"%s%s",
		strings.to_pascal_case(name, context.temp_allocator) or_else "",
		strings.to_pascal_case(stage_name, context.temp_allocator) or_else "",
	)
	emitter := UniformEmitter {
		builder = strings.builder_make(context.temp_allocator),
		emitted = make(map[string]bool, context.temp_allocator),
		prefix  = prefix,
	}
	for block in blocks {
		block_name := strings.to_pascal_case(block.name, context.temp_allocator) or_else ""
		block_symbol := fmt.tprintf("%s%s", prefix, block_name)
		emit_uniform_struct(&emitter, block.type_, block_symbol, block.name)
		constant :=
			strings.to_upper_snake_case(
				fmt.tprintf(
					"%s_%s_%s",
					strings.to_snake_case(name, context.temp_allocator) or_else "",
					stage_name,
					block.name,
				),
				context.temp_allocator,
			) or_else ""
		block_size := uniform_native_size(block.type_, block.name)
		stage := "Compute"
		if stage_name == "vertex" do stage = "Vertex"
		if stage_name == "fragment" do stage = "Fragment"
		fmt.sbprintf(
			&emitter.builder,
			`%s_SLOT :: %d
%s_SPACE :: %d
%s_BINDING :: %d
%s_COUNT :: %d
%s_SIZE :: %d
%s :: goose.UniformBlock {{
	stage = .%s,
	location = {{space = %s_SPACE, binding = %s_BINDING, slot = %s_SLOT, count = %s_COUNT}},
	size = %s_SIZE,
}}

`,
			constant,
			block.slot,
			constant,
			block.space,
			constant,
			block.native_binding,
			constant,
			block.count,
			constant,
			block_size,
			constant,
			stage,
			constant,
			constant,
			constant,
			constant,
			constant,
		)
	}
	return strings.to_string(emitter.builder)
}

artifact_load_path :: proc(output, reflection, extension: string) -> string {
	artifact := artifact_runtime_path(reflection, extension)
	relative, relative_error := filepath.rel(
		filepath.dir(output),
		artifact,
		context.temp_allocator,
	)
	if relative_error != .None do fatal("cannot make %s relative to %s", artifact, output)
	normalized, _ := filepath.replace_separators(relative, '/', context.temp_allocator)
	return normalized
}

// Artifact path as written, relative to the goose-build working directory.
// Runtime-loading glue (--hot-reload) reads this path, so the application
// must run from the same directory goose-build ran in.
artifact_runtime_path :: proc(reflection, extension: string) -> string {
	base := strings.trim_suffix(reflection, ".refl.json")
	if !strings.ends_with(base, fmt.tprintf(".%s", extension)) {
		return fmt.tprintf("%s.%s", base, extension)
	}
	return base
}

// How a generated proc obtains its shader blob: baked compile-time #load
// constant, or a runtime file read (--hot-reload) that re-reads the
// artifact on every call so a file watcher can pick up rebuilt shaders.
emit_blob_source :: proc(
	constant, reflection, output, extension: string,
	hot_reload: bool,
) -> (
	declaration, prelude, expression: string,
) {
	if hot_reload {
		declaration = fmt.tprintf(
			`%s_PATH :: "%s"`,
			constant,
			artifact_runtime_path(reflection, extension),
		)
		prelude = fmt.tprintf(
			"\tblob, blob_error := os.read_entire_file(%s_PATH, context.allocator)\n" +
			"\tif blob_error != nil do fmt.eprintfln(\"goose: failed to read %%s\", %s_PATH)\n",
			constant,
			constant,
		)
		expression = "{data = raw_data(blob), size = len(blob)}"
		return
	}
	declaration = fmt.tprintf(
		`%s_CODE :: #load("%s")`,
		constant,
		artifact_load_path(output, reflection, extension),
	)
	expression = fmt.tprintf("{{data = raw_data(%s_CODE), size = len(%s_CODE)}}", constant, constant)
	return
}

emit_vertex_attributes :: proc(prefix: string, attributes: []VertexAttribute) -> string {
	if len(attributes) == 0 do return ""
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&builder,
		`%s_attributes :: proc($Vertex: typeid) -> [%d]goose.VertexAttribute {{
	return {{
`,
		prefix,
		len(attributes),
	)
	for attribute in attributes {
		fmt.sbprintf(
			&builder,
			`		{{location = %d, format = %s, offset = u32(offset_of(Vertex, %s))}},
`,
			attribute.location,
			attribute.format,
			attribute.name,
		)
	}
	fmt.sbprintf(&builder, `	}}
}}

`)
	return strings.to_string(builder)
}

emit_resource_bindings :: proc(
	name, stage_name: string,
	textures: []TextureBinding,
	samplers: []SamplerBinding,
	storage_resources: []StorageBinding,
) -> string {
	if len(textures) == 0 && len(samplers) == 0 && len(storage_resources) == 0 do return ""
	builder := strings.builder_make(context.temp_allocator)
	shader_prefix := fmt.tprintf("%s_%s", identifier(name), stage_name)
	stage := "Compute"
	if stage_name == "vertex" do stage = "Vertex"
	if stage_name == "fragment" do stage = "Fragment"
	for binding in textures {
		binding_name := strings.to_snake_case(binding.name, context.temp_allocator) or_else ""
		constant :=
			strings.to_upper_snake_case(
				fmt.tprintf("%s_%s", shader_prefix, binding_name),
				context.temp_allocator,
			) or_else ""
		fmt.sbprintf(
			&builder,
			`%s :: goose.TextureBinding {{stage = .%s, location = {{space = %d, binding = %d, slot = %d, count = %d}}}}
`,
			constant,
			stage,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	for binding in samplers {
		binding_name := strings.to_snake_case(binding.name, context.temp_allocator) or_else ""
		constant :=
			strings.to_upper_snake_case(
				fmt.tprintf("%s_%s", shader_prefix, binding_name),
				context.temp_allocator,
			) or_else ""
		fmt.sbprintf(
			&builder,
			`%s :: goose.SamplerBinding {{stage = .%s, location = {{space = %d, binding = %d, slot = %d, count = %d}}}}
`,
			constant,
			stage,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	for binding in storage_resources {
		binding_name := strings.to_snake_case(binding.name, context.temp_allocator) or_else ""
		constant :=
			strings.to_upper_snake_case(
				fmt.tprintf("%s_%s", shader_prefix, binding_name),
				context.temp_allocator,
			) or_else ""
		access := "ReadWrite" if binding.writable else "ReadOnly"
		fmt.sbprintf(
			&builder,
			`%s :: goose.Binding {{name = "%s", stage = .%s, kind = .%s, access = .%s, location = {{space = %d, binding = %d, slot = %d, count = %d}}}}
`,
			constant,
			binding.name,
			stage,
			binding.kind,
			access,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	fmt.sbprintf(&builder, "\n")
	return strings.to_string(builder)
}

emit_binding_table :: proc(
	prefix, stage_name: string,
	stage: StageReflection,
) -> (
	string,
	string,
) {
	total :=
		len(stage.uniform_blocks) +
		len(stage.textures) +
		len(stage.samplers) +
		len(stage.storage_resources)
	if total == 0 do return "", "{}"
	constant :=
		strings.to_upper_snake_case(
			fmt.tprintf("%s_bindings", prefix),
			context.temp_allocator,
		) or_else ""
	stage_value := "Compute"
	if stage_name == "vertex" do stage_value = "Vertex"
	if stage_name == "fragment" do stage_value = "Fragment"
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, `%s := [%d]goose.Binding {{
`, constant, total)
	for binding in stage.uniform_blocks {
		fmt.sbprintf(
			&builder,
			`	{{name = "%s", stage = .%s, kind = .UniformBuffer, access = .ReadOnly, location = {{space = %d, binding = %d, slot = %d, count = %d}}, size = %d}},
`,
			binding.name,
			stage_value,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
			uniform_native_size(binding.type_, binding.name),
		)
	}
	for binding in stage.textures {
		fmt.sbprintf(
			&builder,
			`	{{name = "%s", stage = .%s, kind = .Texture, access = .ReadOnly, location = {{space = %d, binding = %d, slot = %d, count = %d}}}},
`,
			binding.name,
			stage_value,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	for binding in stage.samplers {
		fmt.sbprintf(
			&builder,
			`	{{name = "%s", stage = .%s, kind = .Sampler, access = .ReadOnly, location = {{space = %d, binding = %d, slot = %d, count = %d}}}},
`,
			binding.name,
			stage_value,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	for binding in stage.storage_resources {
		access := "ReadWrite" if binding.writable else "ReadOnly"
		fmt.sbprintf(
			&builder,
			`	{{name = "%s", stage = .%s, kind = .%s, access = .%s, location = {{space = %d, binding = %d, slot = %d, count = %d}}}},
`,
			binding.name,
			stage_value,
			binding.kind,
			access,
			binding.space,
			binding.native_binding,
			binding.slot,
			binding.count,
		)
	}
	fmt.sbprintf(&builder, `}}

`)
	expression := fmt.tprintf("{{data = &%s[0], count = len(%s)}}", constant, constant)
	return strings.to_string(builder), expression
}

platform_extension :: proc(platform: goose.Platform) -> string {
	switch platform {
	case .Metal:    return "msl"
	case .Vulkan:   return "spv"
	case .Direct3D: return "hlsl"
	}
	return ""
}

platform_name :: proc(platform: goose.Platform) -> string {
	switch platform {
	case .Metal:    return "Metal"
	case .Vulkan:   return "Vulkan"
	case .Direct3D: return "Direct3D"
	}
	return ""
}

code_format_name :: proc(platform: goose.Platform) -> string {
	switch platform {
	case .Metal:    return "MetalSource"
	case .Vulkan:   return "Spirv"
	case .Direct3D: return "HlslSource"
	}
	return ""
}

emit_graphics :: proc(
	name: string,
	stage: StageReflection,
	reflection, output: string,
	platform: goose.Platform,
	hot_reload: bool,
) -> string {
	prefix := fmt.tprintf("%s_%s", identifier(name), stage.stage)
	constant := strings.to_upper(prefix, context.temp_allocator)
	extension := platform_extension(platform)
	platform_name := platform_name(platform)
	format_name := code_format_name(platform)
	declaration, prelude, blob_expression := emit_blob_source(
		constant,
		reflection,
		output,
		extension,
		hot_reload,
	)
	counts := stage.counts
	storage_textures := counts.readonly_storage_textures + counts.readwrite_storage_textures
	storage_buffers := counts.readonly_storage_buffers + counts.readwrite_storage_buffers
	stage_name := "Vertex" if stage.stage == "vertex" else "Fragment"
	vertex_attributes := emit_vertex_attributes(prefix, stage.vertex_attributes)
	uniform_blocks := emit_uniform_blocks(name, stage.stage, stage.uniform_blocks)
	resource_bindings := emit_resource_bindings(
		name,
		stage.stage,
		stage.textures,
		stage.samplers,
		stage.storage_resources,
	)
	binding_declaration, binding_expression := emit_binding_table(prefix, stage.stage, stage)

	return fmt.aprintf(
		`%s

%s_SAMPLERS :: %d
%s_STORAGE_TEXTURES :: %d
%s_STORAGE_BUFFERS :: %d
%s_UNIFORM_BUFFERS :: %d

%s%s%s%s%s :: proc() -> goose.GraphicsParameters {{
%s	return {{
		code = {{
			name = "%s.%s",
			entrypoint = "%s",
			platform = .%s,
			format = .%s,
			blob = %s,
		}},
		stage = .%s,
		resources = {{
			samplers = %s_SAMPLERS,
			storage_textures = %s_STORAGE_TEXTURES,
			storage_buffers = %s_STORAGE_BUFFERS,
			uniform_buffers = %s_UNIFORM_BUFFERS,
		}},
		bindings = %s,
	}}
}}

`,
		declaration,
		constant,
		counts.samplers,
		constant,
		storage_textures,
		constant,
		storage_buffers,
		constant,
		counts.uniform_buffers,
		uniform_blocks,
		vertex_attributes,
		resource_bindings,
		binding_declaration,
		prefix,
		prelude,
		name,
		stage.stage,
		stage.entrypoint,
		platform_name,
		format_name,
		blob_expression,
		stage_name,
		constant,
		constant,
		constant,
		constant,
		binding_expression,
		allocator = context.temp_allocator,
	)
}

emit_compute :: proc(
	name: string,
	stage: StageReflection,
	reflection, output: string,
	platform: goose.Platform,
	hot_reload: bool,
) -> string {
	base := identifier(name)
	prefix := base if base == "compute" else fmt.tprintf("%s_compute", base)
	constant := strings.to_upper(prefix, context.temp_allocator)
	extension := platform_extension(platform)
	platform_name := platform_name(platform)
	format_name := code_format_name(platform)
	declaration, prelude, blob_expression := emit_blob_source(
		constant,
		reflection,
		output,
		extension,
		hot_reload,
	)
	counts := stage.counts
	uniform_blocks := emit_uniform_blocks(name, stage.stage, stage.uniform_blocks)
	resource_bindings := emit_resource_bindings(
		name,
		stage.stage,
		stage.textures,
		stage.samplers,
		stage.storage_resources,
	)
	binding_declaration, binding_expression := emit_binding_table(prefix, stage.stage, stage)

	return fmt.aprintf(
		`%s

%s_SAMPLERS :: %d
%s_READONLY_STORAGE_TEXTURES :: %d
%s_READONLY_STORAGE_BUFFERS :: %d
%s_READWRITE_STORAGE_TEXTURES :: %d
%s_READWRITE_STORAGE_BUFFERS :: %d
%s_UNIFORM_BUFFERS :: %d
%s_THREAD_COUNT :: [3]u32{{%d, %d, %d}}

%s%s%s%s :: proc() -> goose.ComputeParameters {{
%s	return {{
		code = {{
			name = "%s.%s",
			entrypoint = "%s",
			platform = .%s,
			format = .%s,
			blob = %s,
		}},
		resources = {{
			samplers = %s_SAMPLERS,
			readonly_storage_textures = %s_READONLY_STORAGE_TEXTURES,
			readonly_storage_buffers = %s_READONLY_STORAGE_BUFFERS,
			readwrite_storage_textures = %s_READWRITE_STORAGE_TEXTURES,
			readwrite_storage_buffers = %s_READWRITE_STORAGE_BUFFERS,
			uniform_buffers = %s_UNIFORM_BUFFERS,
		}},
		thread_count = %s_THREAD_COUNT,
		bindings = %s,
	}}
}}

`,
		declaration,
		constant,
		counts.samplers,
		constant,
		counts.readonly_storage_textures,
		constant,
		counts.readonly_storage_buffers,
		constant,
		counts.readwrite_storage_textures,
		constant,
		counts.readwrite_storage_buffers,
		constant,
		counts.uniform_buffers,
		constant,
		stage.thread_count[0],
		stage.thread_count[1],
		stage.thread_count[2],
		uniform_blocks,
		resource_bindings,
		binding_declaration,
		prefix,
		prelude,
		name,
		stage.stage,
		stage.entrypoint,
		platform_name,
		format_name,
		blob_expression,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		binding_expression,
		allocator = context.temp_allocator,
	)
}

generate_body :: proc(options: Options) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for reflection in options.reflections {
		stage := load_stage(reflection)
		if stage.stage == "compute" {
			strings.write_string(
				&builder,
				emit_compute(
					options.name,
					stage,
					reflection,
					options.output,
					options.platform,
					options.hot_reload,
				),
			)
		} else {
			strings.write_string(
				&builder,
				emit_graphics(
					options.name,
					stage,
					reflection,
					options.output,
					options.platform,
					options.hot_reload,
				),
			)
		}
	}
	return strings.clone(strings.to_string(builder)) or_else ""
}

generate :: proc(options: Options) -> string {
	body := generate_body(options)
	defer delete(body)
	hot_imports := ""
	if options.hot_reload {
		hot_imports = "import \"core:fmt\"\nimport \"core:os\"\n\n"
	}
	return fmt.aprintf(
		`// Generated by goose/tools/build. Do not edit.
package %s

import goose "%s"

%s%s`,
		options.package_name,
		options.goose_import,
		hot_imports,
		body,
	)
}

main :: proc() {
	if try_build_manifest() do return
	options := parse_options()
	defer delete(options.reflections)
	content := generate(options)
	defer delete(content)
	if options.check {
		current, read_error := os.read_entire_file(options.output, context.allocator)
		if read_error != nil do fatal("generated shader parameters missing: %v", read_error)
		defer delete(current)
		if string(current) != content do fatal("generated shader parameters are stale: %s", options.output)
		return
	}
	mkdir_error := os.mkdir_all(filepath.dir(options.output))
	if mkdir_error != nil && mkdir_error != .Exist do fatal("failed to create output directory: %v", mkdir_error)
	write_error := os.write_entire_file(options.output, content)
	if write_error != nil do fatal("failed to write %s: %v", options.output, write_error)
}
