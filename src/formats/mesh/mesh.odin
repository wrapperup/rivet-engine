package formats_mesh

MAGIC :: [3]u8 {'M', 'S', 'H'}

Header :: struct {
    magic: [3]u8,
}
