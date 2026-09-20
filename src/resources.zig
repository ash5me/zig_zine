const std = @import("std");
const zstbi = @import("zstbi");

// CPU-side asset caches.
//
// PNG decoding is done by zig-gamedev/zstbi (a Zig wrapper over stb_image),
// replacing the old libpng dependency. This module deliberately stops at
// "pixels in RAM": uploading to a VkImage needs a working renderer (command
// buffers, staging buffers, layout transitions) which doesn't exist yet, and
// keeping the decode step GPU-free means it can be unit-tested headlessly.
// See docs/resources.md.

/// Every texture is decoded to 4 channels (RGBA). stb_image expands
/// grayscale / grayscale+alpha / RGB / palette PNGs for us and fills alpha
/// with 255 where the file has none, so the future GPU upload path only
/// ever has to deal with one pixel layout.
pub const texture_channels: u32 = 4;

/// A decoded image living in CPU memory.
///
/// Note: stb_image reports 16-bit-per-channel PNGs as 16-bit data.
/// `image.bytes_per_component` is 1 for ordinary 8-bit PNGs and 2 for
/// 16-bit ones; check it before assuming the data is RGBA8.
pub const Texture = struct {
    image: zstbi.Image,

    pub fn width(self: Texture) u32 {
        return self.image.width;
    }

    pub fn height(self: Texture) u32 {
        return self.image.height;
    }

    /// Tightly packed pixel rows, top row first.
    pub fn pixels(self: Texture) []const u8 {
        return self.image.data;
    }
};

pub const TextureCache = struct {
    allocator: std.mem.Allocator,
    textures: std.StringHashMapUnmanaged(*Texture) = .empty,

    /// zstbi keeps its allocator in a process-wide global, so it is
    /// initialised here and torn down in deinit(). Only one TextureCache
    /// should be alive at a time.
    pub fn init(allocator: std.mem.Allocator) TextureCache {
        zstbi.init(allocator);
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TextureCache) void {
        var it = self.textures.iterator();
        while (it.next()) |entry| {
            const texture = entry.value_ptr.*;
            texture.image.deinit();
            self.allocator.destroy(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.textures.deinit(self.allocator);
        // Must come after every Image has been freed above.
        zstbi.deinit();
    }

    /// Decodes the image file at `path` (relative to the working directory)
    /// on first use; later calls with the same path return the cached
    /// texture. The cache owns the result: do not free it.
    pub fn getOrLoadFile(self: *TextureCache, path: []const u8) !*Texture {
        if (self.textures.get(path)) |existing| return existing;

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const image = try zstbi.Image.loadFromFile(path_z, texture_channels);
        return self.insert(path, image);
    }

    /// Same as getOrLoadFile but decodes from bytes already in memory
    /// (e.g. from @embedFile). `key` is the cache key.
    pub fn getOrLoadMemory(self: *TextureCache, key: []const u8, bytes: []const u8) !*Texture {
        if (self.textures.get(key)) |existing| return existing;

        const image = try zstbi.Image.loadFromMemory(bytes, texture_channels);
        return self.insert(key, image);
    }

    /// Takes ownership of `image`, freeing it if anything below fails.
    fn insert(self: *TextureCache, key: []const u8, image: zstbi.Image) !*Texture {
        var owned_image = image;
        errdefer owned_image.deinit();

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const texture = try self.allocator.create(Texture);
        errdefer self.allocator.destroy(texture);
        texture.* = .{ .image = owned_image };

        try self.textures.put(self.allocator, owned_key, texture);
        return texture;
    }
};

// Fonts and shaders are still stubs: they fail loudly instead of returning
// blank data. Shader loading needs SPIR-V + a Vulkan device, so it lands with
// the renderer; fonts have no consumer yet.

pub const Font = struct {
    placeholder: u32 = 0,
};

pub const FontCache = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FontCache {
        return .{ .allocator = allocator };
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
    placeholder: u32 = 0,
};

pub const ShaderCache = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShaderCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShaderCache) void {
        _ = self;
    }

    pub fn getOrLoad(self: *ShaderCache, key: []const u8) !*Shader {
        _ = self;
        _ = key;
        return error.ShaderLoadingNotImplemented;
    }
};

// ---------------------------------------------------------------------------
// Built-in placeholder texture + tests. The PNGs are tiny, generated offline
// and embedded as bytes, so nothing here needs files on disk or a GPU.
// ---------------------------------------------------------------------------

/// Built-in 2x2, 8-bit RGBA placeholder texture: red, green / blue, white at
/// alpha 128. Also serves as the test fixture and as a run-time smoke test that
/// the zstbi/stb_image path is linked and working.
pub const placeholder_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00,
    0x13, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x0c, 0x81, 0x34, 0x08, 0x34, 0x00, 0x00, 0x49, 0x49, 0x09, 0x78,
    0x9c, 0x51, 0x17, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
};

/// 1x1, 8-bit RGB (the file itself has no alpha channel): (10, 20, 30).
const png_1x1_rgb = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
    0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xe0, 0x12, 0x91, 0x03,
    0x00, 0x00, 0x68, 0x00, 0x3d, 0x6a, 0xf5, 0x70, 0x5b, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "decodes an RGBA PNG from memory" {
    var cache = TextureCache.init(std.testing.allocator);
    defer cache.deinit();

    const texture = try cache.getOrLoadMemory("rgba.png", &placeholder_png);
    try std.testing.expectEqual(@as(u32, 2), texture.width());
    try std.testing.expectEqual(@as(u32, 2), texture.height());
    try std.testing.expectEqual(@as(usize, 2 * 2 * 4), texture.pixels().len);

    const expected = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 128, // white, half alpha
    };
    try std.testing.expectEqualSlices(u8, &expected, texture.pixels());
}

test "RGB PNG is expanded to RGBA with opaque alpha" {
    var cache = TextureCache.init(std.testing.allocator);
    defer cache.deinit();

    const texture = try cache.getOrLoadMemory("rgb.png", &png_1x1_rgb);
    try std.testing.expectEqual(@as(u32, 1), texture.width());
    try std.testing.expectEqual(@as(u32, 1), texture.height());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 255 }, texture.pixels());
}

test "same key returns the cached texture" {
    var cache = TextureCache.init(std.testing.allocator);
    defer cache.deinit();

    const first = try cache.getOrLoadMemory("rgba.png", &placeholder_png);
    const second = try cache.getOrLoadMemory("rgba.png", &placeholder_png);
    try std.testing.expect(first == second);
    try std.testing.expectEqual(@as(u32, 1), cache.textures.count());
}

test "garbage bytes fail to decode and leave the cache empty" {
    var cache = TextureCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(std.meta.isError(cache.getOrLoadMemory("junk", "definitely not a png")));
    try std.testing.expectEqual(@as(u32, 0), cache.textures.count());
}

test "font and shader stubs report not-implemented" {
    var fonts = FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    try std.testing.expectError(error.FontLoadingNotImplemented, fonts.getOrLoad("x"));

    var shaders = ShaderCache.init(std.testing.allocator);
    defer shaders.deinit();
    try std.testing.expectError(error.ShaderLoadingNotImplemented, shaders.getOrLoad("x"));
}
