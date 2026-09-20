const vk = @import("vulkan");
const std = @import("std");

pub const SDL_Window = opaque {};
pub const VkInstance = ?*anyopaque;
pub const VkSurfaceKHR = ?*anyopaque;
pub const PFN_vkGetInstanceProcAddr = *const fn (VkInstance, [*:0]const u8) callconv(.c) vk.PfnVoidFunction;

// SDL3 event type for quit
pub const SDL_EVENT_QUIT: u32 = 0x100;

// We define SDL_Event as a struct with at least the type field accessible.
// The actual SDL_Event is a union, but we only need the type for now.
// We'll pad to the known size of SDL_Event (56 bytes) to avoid size mismatches.
// Note: This is a simplification and assumes the SDL_Event layout is as expected.
// For a more robust solution, we would use the actual SDL headers via cimport,
// but for simplicity we define a struct with the type field and padding.
pub const SDL_Event = struct {
    type: u32,
    _: [52]u8, // 52 bytes padding to make total 56 bytes (size of SDL_Event in SDL3)
};

pub extern fn SDL_Init(flags: u32) i32;
pub extern fn SDL_Quit() void;
pub extern fn SDL_CreateWindow(title: [*]const u8, width: i32, height: i32, flags: u64) *SDL_Window;
pub extern fn SDL_DestroyWindow(window: *SDL_Window) void;
pub extern fn SDL_PollEvent(event: *SDL_Event) i32;
pub extern fn SDL_GetPerformanceCounter() u64;
pub extern fn SDL_GetPerformanceFrequency() u64;
pub extern fn SDL_Vulkan_GetVkGetInstanceProcAddr() ?*const anyopaque;
pub extern fn SDL_Vulkan_GetInstanceExtensions(count: *u32) ?[*:0]const [*:0]const u8;
pub extern fn SDL_Vulkan_CreateSurface(
    window: *SDL_Window,
    instance: VkInstance,
    allocator_callbacks: ?*anyopaque,
    surface: *VkSurfaceKHR,
) bool;
pub extern fn SDL_GetWindowSizeInPixels(window: *SDL_Window, width: *c_int, height: *c_int) bool;

/// Context for managing SDL window and events.
pub const SDLContext = struct {
    window: *SDL_Window,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator, title: []const u8, width: i32, height: i32) !SDLContext {
        if (SDL_Init(.init_video | .init_event) != 0) {
            return error.SdlInitFailed;
        }
        const window = SDL_CreateWindow(title, width, height, .window_vulkan);
        if (window == null) {
            SDL_Quit();
            return error.SdlCreateWindowFailed;
        }
        return SDLContext{
            .window = window,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SDLContext) void {
        SDL_DestroyWindow(self.window);
        SDL_Quit();
    }

    /// Polls events and returns true if we should quit (i.e., received SDL_QUIT)
    pub fn pollEvents(self: *SDLContext) bool {
        var event: SDL_Event = undefined;
        while (SDL_PollEvent(&event) == 1) {
            if (event.type == SDL_EVENT_QUIT) {
                return true;
            }
        }
        return false;
    }
};
