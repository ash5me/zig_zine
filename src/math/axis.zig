const std = @import("std");

/// Mask for controlling per-axis behavior (movement locks, collision participation)
pub const AxisMask = struct {
    x: bool = false,
    y: bool = false,
    z: bool = false,
};

/// Convert AxisMask to a Vec3 where true axes = 1.0, false axes = 0.0
pub fn toVec3(mask: AxisMask) Vec3 {
    return .{
        if (mask.x) 1.0 else 0.0,
        if (mask.y) 1.0 else 0.0,
        if (mask.z) 1.0 else 0.0,
    };
}

/// Invert AxisMask for use as inhibition mask (true axes = 0.0, false axes = 1.0)
pub fn invertedVec3(mask: AxisMask) Vec3 {
    return .{
        if (mask.x) 0.0 else 1.0,
        if (mask.y) 0.0 else 1.0,
        if (mask.z) 0.0 else 1.0,
    };
}

/// Elementwise multiplication of two Vec3 vectors
pub fn mul(a: Vec3, b: Vec3) Vec3 {
    return a * b;
}

/// Elementwise subtraction of two Vec3 vectors
pub fn sub_vec3(a: Vec3, b: Vec3) Vec3 {
    return a - b;
}
