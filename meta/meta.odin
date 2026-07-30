package meta

import "base:intrinsics"
import "base:runtime"
import "core:strconv"

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Type_Mapping :: struct {
	from: string,
	to:   string,
}

type_map := []Type_Mapping {
	// { "f32", "float" },
	// { "f64", "double" },
	// { "i32", "int" },
	// { "u32", "uint" },
	// { "u8" , "uint8_t" },
}

templated_type_map := []string {
	"Image1D_",
	"Image2D_",
	"Image3D_",
	"ImageCube_",
	"Image1DArray_",
	"Image2DArray_",
	"Image3DArray_",
	"ImageCubeArray_",
	"RWImage1D_",
	"RWImage2D_",
	"RWImage3D_",
}

banned_types := []Type_Mapping {
	{"ImageId", "Tag the struct with an `Image*` type."},
	{"SamplerId", "Tag the struct with `Sampler` or `SamplerComparison`."},
}

error_reported := false

report_warning :: proc(message: string, node: ^ast.Node, file: ^ast.File, suggestion := "") {
	report(message, "\x1b[31mWarning:\x1b[0m", node, file, suggestion)
}

report_error :: proc(message: string, node: ^ast.Node, file: ^ast.File, suggestion := "") {
	report(message, "\x1b[31mError:\x1b[0m", node, file, suggestion)
	error_reported = true
}

report :: proc(message: string, level: string, node: ^ast.Node, file: ^ast.File, suggestion := "") {
	fmt.eprintln("\x1b[1m", node.pos.file, "(", node.pos.line, ":", node.pos.column, ")\x1b[22m ", level, " ", message, sep = "")

	fmt.eprint("        ")
	file_src := file.src
	i := 0
	for line in strings.split_lines_iterator(&file_src) {
		if i == node.pos.line - 1 {
			fmt.eprintln(strings.trim_space(line))
			break
		}
		i += 1
	}

	fmt.eprint("        ")
	for i in 2 ..< node.pos.column {
		fmt.eprint(" ")
	}
	fmt.eprint("^")
	if node.end.column != node.pos.column {
		for i in 2 ..< (node.end.column - node.pos.column) {
			fmt.eprint("~")
		}
		fmt.eprint("^")
	}
	fmt.eprintln("")
	if suggestion != "" {
		fmt.eprint("        ")
		fmt.eprintln("Suggestion:", suggestion)
	}
}

map_type_to_slang :: proc(ty: string, node: ^ast.Node, file: ^ast.File) -> string {
	for mapping in type_map {
		if mapping.from == ty {
			return mapping.to
		}
	}

	for name in templated_type_map {
		if strings.starts_with(ty, name) {
			start := name[:len(name) - 1]
			rest := ty[len(name):]
			return fmt.tprint(start, "<", rest, ">", sep = "")
		}
	}

	return strip_gpu_name(ty)
}

strip_gpu_name :: proc(s: string) -> string {
	if strings.has_prefix(s, "GPU_") {
		return s[4:]
	} else if strings.has_prefix(s, "GPU") {
		return s[3:]
	}

	return s
}

collect_files :: proc(path: string, allocator: runtime.Allocator) -> (ast_files: [dynamic]^ast.File, success: bool) {
	NO_POS :: tokenizer.Pos{}

	pkg_path, pkg_path_err := filepath.abs(path, allocator)
	assert(pkg_path_err == nil)

	files: [dynamic]string
	fullpaths: [dynamic]string

	walker := filepath.walker_create(pkg_path)
	defer os.walker_destroy(&walker)

	// TODO: This probably needs cleanup, I just made it work with os2->os breaking changes.

	for info in os.walker_walk(&walker) {
		if filepath.ext(info.fullpath) != ".odin" do continue

		fullpath := strings.clone(info.fullpath)

		base := filepath.base(fullpath)
		if base == "generated.odin" {
			delete(fullpath)
			continue
		}

		src, err := os.read_entire_file(fullpath, allocator)
		if err != nil {
			delete(fullpath)
			fmt.eprintln("Couldn't read file:", fullpath)
			assert(false, "YAY")
		}

		if strings.trim_space(string(src)) == "" {
			delete(fullpath)
			delete(src)
			continue
		}

		append(&fullpaths, string(fullpath))
		append(&files, string(src))
	}

	resize(&ast_files, len(files))

	p := parser.default_parser()

	for i in 0 ..< len(files) {
		src_file := files[i]
		fullpath := fullpaths[i]

		file := ast.new(ast.File, NO_POS, NO_POS)
		file.src = string(src_file)
		file.fullpath = fullpath

		assert(parser.parse_file(&p, file))

		ast_files[i] = file
	}

	success = true
	return
}

get_named_type_reference :: proc(expr: ^ast.Expr) -> (
	package_name: string,
	type_name: string,
	ok: bool,
) {
	#partial switch ty in expr.derived {
	case ^ast.Ident:
		return "", ty.name, true
	case ^ast.Selector_Expr:
		package_ident, package_ok := ty.expr.derived.(^ast.Ident)
		if !package_ok {
			return
		}
		return package_ident.name, ty.field.name, true
	}
	return
}

get_type_string :: proc(expr: ^ast.Expr, file: ^ast.File) -> (type_name: string, array_name: string) {
	builder: strings.Builder
	arr_builder: strings.Builder

	node := expr.derived

	#partial switch ty in node {
	case ^ast.Selector_Expr:
		return get_type_string(ty.field, file)
	case ^ast.Ident:
		return map_type_to_slang(ty.name, &ty.node, file), ""
	case ^ast.Call_Expr:
		if len(ty.args) == 1 {
			package_name, generic_name, named_type_ok := get_named_type_reference(ty.expr)
			if !named_type_ok {
				report_error(
					"Parametric shader field type must be a named type.",
					&ty.node,
					file,
				)
				break
			}

			inner_name, inner_array_name := get_type_string(ty.args[0], file)

			if package_name == "gfx" && generic_name == "Ptr" {
				array_name = inner_array_name
				fmt.sbprint(&builder, inner_name, "*", sep = "")
				break
			} else if package_name == "gfx" && generic_name == "Slice" {
				assert(inner_array_name == "", "GPU slices cannot contain fixed-size array elements.")
				fmt.sbprint(&builder, "Slice<", inner_name, ">", sep = "")
				break
			}

			report_error(
				"Parametric shader field type is not supported.",
				&ty.node,
				file,
				"Use gfx.Ptr(T) or gfx.Slice(T).",
			)
		}
	case ^ast.Array_Type:
		assert(ty.len != nil, "Arrays must be fixed length.")

		lit, ok := ty.len.derived_expr.(^ast.Basic_Lit)
		assert(ok, "Array length must be positive.")

		len_string := lit.tok.text

		inner_type_name, inner_array_name := get_type_string(ty.elem, file)
		fmt.sbprint(&builder, inner_type_name)
		fmt.sbprint(&arr_builder, inner_array_name, "[", len_string, "]", sep = "")
	case:
		assert(false, "Type is not supported.")
	}

	return strings.to_string(builder), strings.to_string(arr_builder)
}

generate_shader_bindings :: proc(files: []^ast.File) {
	builder: strings.Builder
	strings.builder_init(&builder)

	strings.write_string(&builder, "//\n")
	strings.write_string(&builder, "// This is a generated file, do not modify. See src/meta.odin\n")
	strings.write_string(&builder, "//")

	for file in files {
		printed_header_once := false
		for decl in file.decls {
			value, ok := decl.derived_stmt.(^ast.Value_Decl)
			if !ok do continue

			if len(value.attributes) <= 0 do continue

			found := false
			for attr in value.attributes {
				for elem in attr.elems {
					i, iok := elem.derived.(^ast.Ident)
					if iok && i.name == "shader_shared" {
						found = true
					}
				}
			}

			if !found do continue

			if len(value.values) != 1 {
				report_error("Declaration has multiple values. This is not supported with @shader_shared.", value, file)
				continue
			}
			if len(value.names) != 1 {
				report_error("Declaration has names. This is not supported with @shader_shared.", value, file)
				continue
			}

			ident, nok := value.names[0].derived.(^ast.Ident)
			if !nok {
				report_error("Declaration name must be an identifier.", value.names[0], file)
				continue
			}

			name := ident.name

			if !printed_header_once {
				strings.write_string(&builder, "\n\n")
				strings.write_string(&builder, "//\n")
				strings.write_string(&builder, "// Generated from ")
				strings.write_string(&builder, file.fullpath)
				strings.write_string(&builder, "\n")
				strings.write_string(&builder, "//\n")
				printed_header_once = true
			}

			#partial switch expr in value.values[0].derived_expr {
			case ^ast.Struct_Type:
				generate_bind_struct(&builder, name, expr, file)
			case ^ast.Basic_Lit:
				if value.type != nil {
					report_warning("Shader shared define will ignore the type.", value, file)
				}
				generate_bind_lit(&builder, name, expr, file)
			}
		}
	}

	str := strings.to_string(builder)
	str = strings.trim(str, "\n")

	if !error_reported {
		err_wef := os.write_entire_file("shaders/generated.slang", transmute([]u8)str)
		assert(err_wef == nil)
	}
}

generate_bind_lit :: proc(builder: ^strings.Builder, name: string, expr: ^ast.Basic_Lit, src_file: ^ast.File) {
	fmt.sbprintln(builder, "#define", name, expr.tok.text)
}

generate_bind_struct :: proc(builder: ^strings.Builder, name: string, expr: ^ast.Struct_Type, src_file: ^ast.File) {
	strings.write_string(builder, "struct ")
	strings.write_string(builder, strip_gpu_name(name))

	if expr.max_field_align != nil {
		text := ""

		#partial switch e in expr.max_field_align.derived {
		case ^ast.Basic_Lit:
			text = e.tok.text
		case ^ast.Paren_Expr:
			text = e.expr.derived.(^ast.Basic_Lit).tok.text
		case:
			unreachable()
		}

		max_field_align, ok := strconv.parse_int(text)
		if max_field_align > 16 || !ok {
			report_error("Struct must have a max field align of 16.", expr, src_file)
		}
	} else {
		report_error("Struct must have a max field align of 16.", expr, src_file, "Add #max_field_align(16)")
	}

	if len(expr.fields.list) > 0 {
		strings.write_string(builder, " {\n")

		for field in expr.fields.list {
			field_type, array_decl: string
			if field.tag.text != "" {
				field_type = field.tag.text[1:len(field.tag.text) - 1]
			} else {
				field_type, array_decl = get_type_string(field.type, src_file)
			}

			for banned_name in banned_types {
				if banned_name.from == field_type {
					report_error("Type is not allowed in a shader struct.", &field.type.expr_base, src_file, banned_name.to)
				}
			}

			field_name := field.names[0].derived_expr.(^ast.Ident).name

			strings.write_string(builder, "  ")
			strings.write_string(builder, field_type)
			strings.write_string(builder, " ")
			strings.write_string(builder, field_name)
			if len(array_decl) > 0 {
				strings.write_string(builder, array_decl)
			}
			strings.write_string(builder, ";\n")
		}

		strings.write_string(builder, "}")
	}
	strings.write_string(builder, ";\n\n")
}

ShaderDecl :: struct {
	expr:     ^ast.Struct_Type,
	name:     string,
	src_file: ^ast.File,
}

generate :: proc() -> bool {
	start_time := time.now()
	error_reported = false

	files, ok := collect_files("./src", context.allocator)
	assert(ok)

	generate_shader_bindings(files[:])
	generate_assets(files[:])

	if !error_reported {
		fmt.println("Parsed and generated code in", time.since(start_time))
		return true
	}
	return false
}

main :: proc() {
	if !generate() {
		os.exit(1)
	}
}

has_shader_shared_attr :: proc(value: ^ast.Value_Decl) -> bool {
	for attr in value.attributes {
		for elem in attr.elems {
			if i, ok := elem.derived.(^ast.Ident); ok && i.name == "shader_shared" {
				return true
			}
		}
	}
	return false
}

collect_matrix_aliases :: proc(files: []^ast.File) -> map[string]bool {
	set := make(map[string]bool)
	for file in files {
		for decl in file.decls {
			value, ok := decl.derived_stmt.(^ast.Value_Decl)
			if !ok do continue
			if len(value.names) != 1 || len(value.values) != 1 do continue
			ident, iok := value.names[0].derived.(^ast.Ident)
			if !iok do continue
			if _, mok := value.values[0].derived_expr.(^ast.Matrix_Type); mok {
				set[ident.name] = true
			}
		}
	}
	return set
}

// Matrices are the ONLY type whose Odin layout diverges from scalar layout
type_is_matrix :: proc(expr: ^ast.Expr, matrix_aliases: map[string]bool) -> bool {
	#partial switch t in expr.derived_expr {
	case ^ast.Matrix_Type:
		return true
	case ^ast.Ident:
		return matrix_aliases[t.name]
	case ^ast.Selector_Expr:
		return matrix_aliases[t.field.name]
	case ^ast.Array_Type:
		return type_is_matrix(t.elem, matrix_aliases)
	}
	return false
}

append_layout_asserts :: proc(b: ^strings.Builder, files: []^ast.File) {
	matrix_aliases := collect_matrix_aliases(files)

	for file in files {
		for decl in file.decls {
			value, ok := decl.derived_stmt.(^ast.Value_Decl)
			if !ok || !has_shader_shared_attr(value) do continue
			if len(value.values) != 1 || len(value.names) != 1 do continue
			ident, nok := value.names[0].derived.(^ast.Ident)
			if !nok do continue
			st, sok := value.values[0].derived_expr.(^ast.Struct_Type)
			if !sok do continue

			name := ident.name

			// Only matrices need asserts. Other types are scalar so will emit correctly in scalar block.
			prev_name := ""
			struct_header_written := false

			for field in st.fields.list {
				is_mat := type_is_matrix(field.type, matrix_aliases)

				for nm in field.names {
					id, iok := nm.derived_expr.(^ast.Ident)
					if !iok do continue
					fname := id.name

					if is_mat {
						if !struct_header_written {
							fmt.sbprintf(b, "\n// %s\n", name)
							struct_header_written = true
						}
						if prev_name == "" {
							fmt.sbprintf(b, "#assert(offset_of(%s, %s) == 0)\n", name, fname)
						} else {
							// Scalar offset = the previous field's end, rounded up to a matrix's
							// scalar alignment (4 for an f32 matrix). `size_of(type_of(S{}.field))`
							// sizes the previous field WITHOUT naming its type, so file-private
							// field types (gfx.Ptr, ImageId, ...) that aren't in scope in this
							// generated file don't matter — only struct/field names are referenced. The `{}`
							// is written literally (fmt treats it as a format verb otherwise).
							fmt.sbprintf(b, "#assert(offset_of(%s, %s) == (offset_of(%s, %s) + size_of(type_of(", name, fname, name, prev_name)
							strings.write_string(b, name)
							strings.write_string(b, "{}.")
							strings.write_string(b, prev_name)
							strings.write_string(b, ")) + 3) / 4 * 4)\n")
						}
					}

					prev_name = fname
				}
			}
		}
	}
}

// Keep in sync with `asset_type_from_base` in src/assets.odin — only extensions the engine can
// actually load should become Asset_Name entries. Everything else (.blend, .exr, .aup3, ...) is
// skipped so source files sitting in assets/ don't pollute the generated enum.
is_supported_asset :: proc(path: string) -> bool {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".glb", ".ktx2", ".wav", ".txt", ".ttf":
		return true
	}
	return false
}

generate_assets :: proc(files: []^ast.File) {
	b: strings.Builder

	bpln :: fmt.sbprintln

	bpln(&b, "//")
	bpln(&b, "// This is a generated file, do not modify. See src/meta.odin")
	bpln(&b, "//\n")

	asset_files: [dynamic]os.File_Info

	// TODO: This probably needs cleanup, I just made it work with os2->os breaking changes.
	walker := filepath.walker_create("assets")
	defer os.walker_destroy(&walker)

	for info in os.walker_walk(&walker) {
		if info.type == .Directory do continue
		if !is_supported_asset(info.fullpath) do continue // skip source files (.blend, .exr, .aup3, ...)

		cloned, clone_err := os.file_info_clone(info, context.allocator)
		assert(clone_err == nil)
		append(&asset_files, cloned)
	}

	working_directory, err_wd := os.get_working_directory(context.temp_allocator)
	assert(err_wd == nil, "Can't get working directory")

	bpln(&b, "package game")
	bpln(&b, "")
	bpln(&b, "// Assets")
	bpln(&b, "Asset_Name :: enum {")
	for file in asset_files {
		stem := filepath.stem(file.name)
		bpln(&b, "    ", stem, ",", sep = "")
	}
	bpln(&b, "}")
	bpln(&b, "")
	bpln(&b, "asset_map: [Asset_Name]Asset")
	bpln(&b, "")
	bpln(&b, "load_generated_assets :: proc() -> bool {")
	for file in asset_files {
		base := filepath.stem(file.name)
		rel_path, k := filepath.rel(working_directory, file.fullpath)
		assert(k == nil, "Couldn't get relative path")
		fixed_path, ok := strings.replace_all(rel_path, "\\", "/")
		bpln(&b, "    asset_map[.", base, "] = load_asset(\"", fixed_path, "\") or_return", sep = "")
	}
	bpln(&b, "    return true")
	bpln(&b, "}")

	append_layout_asserts(&b, files)

	if !error_reported {
		err_wef := os.write_entire_file("src/generated.odin", transmute([]u8)strings.to_string(b))
		assert(err_wef == nil, "Couldn't write generated.odin")
	}
}
