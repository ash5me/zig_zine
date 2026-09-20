const std = @import("std");
const vk = @import("vulkan");
const VSC = @import("vulkan_swapchain.zig");

// This file is a STUB. The previous implementation depended on a "libpng"
// Zig binding that was never actually added to build.zig.zon and whose API
// (png.createReadStruct, png.setStrip16, etc.) doesn't match any real
// library — it couldn't have compiled as written. Rather than patch invented
// API calls, this replaces the three caches with no-op implementations that
// compile and satisfy Engine's existing init()/deinit() calls, so the rest
// of the engine (physics, window, render loop) can be built and tested
// independently of texture/font loading.
//
// Real texture loading should be rebuilt against zig-gamedev/zstbi
// (https://github.com/zig-gamedev/zstbi) — a real, maintained Zig binding
// for stb_image that decodes PNG with a plain
// `zstbi.Image.loadFromFile(path, forced_num_components) !Image` call and
// no manual PNG chunk/color-type handling. That's a separate, dedicated
// step: add zstbi to build.zig.zon, then replace loadTextureFromFile below
// with real decode + Vulkan image upload logic.

/// Represents a texture loaded into GPU memory. Placeholder fields only —
/// no GPU resources are actually created by this stub.
pub const Texture = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: vk.Format = .undefined,

    pub fn deinit(self: *Texture, vkd: *vk.DeviceWrapper, device: vk.Device) void {
        _ = self;
        _ = vkd;
        _ = device;
    }
};

pub const TextureCache = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, vulkan: *VSC.VulkanSwapchain) !TextureCache {
        _ = vulkan;
        return TextureCache{ .allocator = allocator };
    }

    pub fn deinit(self: *TextureCache) void {
        _ = self;
    }

    /// Stub: always fails until real loading is implemented against zstbi.
    /// Callers should treat texture loading as not-yet-available rather
    /// than silently getting a blank/garbage texture back.
    pub fn getOrLoad(self: *TextureCache, key: []const u8) !*Texture {
        _ = self;
        _ = key;
        return error.TextureLoadingNotImplemented;
    }
};

pub const Font = struct {
    placeholder: u32 = 0,
};

pub const FontCache = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !FontCache {
        return FontCache{ .allocator = allocator };
    }

    pub fn deinit(self: *FontCache) void {
        _ = self;
    }

    pub fn getOrLoad(self: *FontCache, key: []const u8) !*Font {
        _ = self;
        _ = key;
        return error.FontLoadingNotImplemented;
    }
};

pub const Shader = struct {
    module: vk.ShaderModule = .null_handle,

    pub fn deinit(self: *Shader, vkd: *vk.DeviceWrapper, device: vk.Device) void {
        if (self.module != .null_handle) {
            vkd.destroyShaderModule(device, self.module, null);
        }
    }
};

pub const ShaderCache = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, vulkan: *VSC.VulkanSwapchain) !ShaderCache {
        _ = vulkan;
        return ShaderCache{ .allocator = allocator };
    }

    pub fn deinit(self: *ShaderCache) void {
        _ = self;
    }

    /// Stub: always fails until real SPIR-V loading is implemented.
    pub fn getOrLoad(self: *ShaderCache, key: []const u8) !*Shader {
        _ = self;
        _ = key;
        return error.ShaderLoadingNotImplemented;
    }
};
