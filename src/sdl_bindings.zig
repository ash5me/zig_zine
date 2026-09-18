const vk = @import("vulkan");

pub const SDL_Window = opaque {};
pub const VkInstance = ?*anyopaque;
pub const VkSurfaceKHR = ?*anyopaque;
pub const PFN_vkGetInstanceProcAddr = *const fn (VkInstance, [*:0]const u8) callconv(.c) vk.PfnVoidFunction;

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
