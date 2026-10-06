# Generate Tex.get_dimensions
shapes = [
    ("1D", [(0, "non-array"), (1, "array")]),
    ("2D", [(0, "non-array"), (1, "array")]),
    ("3D", [(0, "")]),
    ("Cube", [(0, "non-array"), (1, "array")])
]

ms_statuses = {
    "1D": [0],
    "2D": [0, 1],
    "3D": [0],
    "Cube": [0]
}

types = [
    "float",
    "int",
    "uint"
]

access_image_array = [
    (0, "Images", "Read-Only"),
    (1, "RWImages", "Read/Write")
]

# Shape-specific parameters
shape_parameters = {
    "1D": ["width"],
    "2D": ["width", "height"],
    "3D": ["width", "height", "depth"],
    "Cube": ["width", "height"]
}

array_extra_params = "elements"
ms_extra_params = "sampleCount"
number_of_levels = "numberOfLevels"

def add_comment(shape, array_desc, ms_status, rw_text):
    array_text = "Array" if array_desc == "array" else "Non-array"
    ms_text = "MS" if ms_status == 1 else "Non-MS"
    return f"// Shape {shape}, {rw_text}, {array_text}, {ms_text}"


def generate_code():
    code = []
    code.append(f"// Generated boilerplate code for _Image.get_dimensions method.\n")

    code.append(f"implementing bindless;\n")

    for shape, array_status_list in shapes:
        for array_status, array_desc in array_status_list:
            for ms_status in ms_statuses[shape]:
                for access_int, image_array, rw_text in access_image_array:
                    code.append(add_comment(shape, array_desc, ms_status, rw_text))

                    code.append(f"__generic<T:ITexelElement, let sampleCount:int, let format:int>")
                    code.append(f"public extension _Image<T, __Shape{shape}, {array_status}, {ms_status}, sampleCount, {access_int}, format> {{")

                    # Generate method overloads
                    for type_name in types:
                        base_params = shape_parameters[shape].copy()

                        if array_status == 1:
                            base_params.append(array_extra_params)
                        if ms_status == 1:
                            base_params.append(ms_extra_params)

                        # Without mipLevel
                        param_list = ", ".join([f"out {type_name} {param}" for param in base_params])
                        code.append(f"    public void get_dimensions({param_list}) {{")
                        code.append(f"        ImageType image = get();")
                        code.append(f"        image.GetDimensions({', '.join(base_params)});")
                        code.append(f"    }}")

                        # With mipLevel
                        if ms_status == 0:
                            base_params.append(number_of_levels)
                            param_list = ", ".join([f"out {type_name} {param}" for param in base_params])
                            code.append(f"    public void get_dimensions(uint mipLevel, {param_list}) {{")
                            code.append(f"        ImageType image = get();")
                            code.append(f"        image.GetDimensions(mipLevel, {', '.join(base_params)});")
                            code.append(f"    }}")

                    code.append(f"}}\n")

    return "\n".join(code)

with open("./gen_get_dimensions.slang", "w") as file:
    file.write(generate_code())
