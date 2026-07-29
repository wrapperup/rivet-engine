#define TYPEDEF_VECTORS(T) \
typedef vector<T,4> Vec4 ## T; \
typedef vector<T,3> Vec3 ## T; \
typedef vector<T,2> Vec2 ## T; \
typedef vector<T,1> Vec1 ## T;

#define TYPEDEF_MATRICES_FOR_ROW(T, R) \
typedef matrix<T, R, 4> Mat ## R ## x4 ## T; \
typedef matrix<T, R, 3> Mat ## R ## x3 ## T; \
typedef matrix<T, R, 2> Mat ## R ## x2 ## T;

#define TYPEDEF_MATRICES_FOR_SCALAR(T) \
    TYPEDEF_MATRICES_FOR_ROW(T, 4) \
    TYPEDEF_MATRICES_FOR_ROW(T, 3) \
    TYPEDEF_MATRICES_FOR_ROW(T, 2)

// Basic types
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;

typedef float16_t f16;
typedef float32_t f32;
typedef float64_t f64;

// Non-owning view of a contiguous device-addressable buffer range.
// This deliberately carries no allocation or lifetime behavior.
struct Slice<T> {
    T* data;
    u32 count;
    // Keep the ABI at 16 bytes. Without this, scalar layout lets a following
    // u32 reuse the tail padding that Odin includes in GPUSlice<T>.
    u32 _padding;

    __subscript(u32 index) -> T {
        get { return data[index]; }
        set { data[index] = newValue; }
    }
};

TYPEDEF_VECTORS(u8);
TYPEDEF_VECTORS(u16);
TYPEDEF_VECTORS(u32);
TYPEDEF_VECTORS(u64);
TYPEDEF_VECTORS(i8);
TYPEDEF_VECTORS(i16);
TYPEDEF_VECTORS(i32);
TYPEDEF_VECTORS(i64);
TYPEDEF_VECTORS(f16);
TYPEDEF_VECTORS(f32);
TYPEDEF_VECTORS(f64);

TYPEDEF_MATRICES_FOR_SCALAR(u8);
TYPEDEF_MATRICES_FOR_SCALAR(u16);
TYPEDEF_MATRICES_FOR_SCALAR(u32);
TYPEDEF_MATRICES_FOR_SCALAR(u64);
TYPEDEF_MATRICES_FOR_SCALAR(i8);
TYPEDEF_MATRICES_FOR_SCALAR(i16);
TYPEDEF_MATRICES_FOR_SCALAR(i32);
TYPEDEF_MATRICES_FOR_SCALAR(i64);
TYPEDEF_MATRICES_FOR_SCALAR(f16);
TYPEDEF_MATRICES_FOR_SCALAR(f32);
TYPEDEF_MATRICES_FOR_SCALAR(f64);

// f32
typedef Vec2f32 Vec2;
typedef Vec3f32 Vec3;
typedef Vec4f32 Vec4;

typedef Mat4x4f32 Mat4x4;
typedef Mat4x3f32 Mat4x3;
typedef Mat4x2f32 Mat4x2;

typedef Mat3x4f32 Mat3x4;
typedef Mat3x3f32 Mat3x3;
typedef Mat3x2f32 Mat3x2;

typedef Mat2x4f32 Mat2x4;
typedef Mat2x3f32 Mat2x3;
typedef Mat2x2f32 Mat2x2;
