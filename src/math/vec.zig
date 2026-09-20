const std = @import("std");

/// Zig's SIMD vector builtin — the closest thing the standard library
/// has to a "vector type". Elementwise +, -, *, and indexing with
/// v[0]/v[1]/v[2] all work natively on @Vector, no hand-rolled struct
/// math needed.
pub const Vec3 = @Vector(3, f32);

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return a + b;
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return a - b;
}

pub fn scale(a: Vec3, s: f32) Vec3 {
    return a * @as(Vec3, @splat(s));
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn zero() Vec3 {
    return @splat(0);
}

pub const gravity: Vec3 = Vec3{ 0, -9.81, 0 };
