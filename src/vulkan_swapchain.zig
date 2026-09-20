const std = @import("std");
const vk = @import("vulkan");
const c = @import("sdl_bindings.zig");

pub const Matrix4x4 = [4][4]f32;
pub const max_instance_count: usize = 10_000;

// vulkan-zig dispatch tables — list only the functions this module
// calls. Extend these lists as later steps need more Vulkan calls.
const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceExtensionProperties = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .createDevice = true,
    .getDeviceProcAddr = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .cmdBindIndexBuffer = true,
    .cmdBindVertexBuffers = true,
    .cmdDrawIndexed = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,
    .createImageView = true,
    .destroyImageView = true,
    .acquireNextImageKHR = true,
    .queuePresentKHR = true,
    .deviceWaitIdle = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
});

pub const QueueFamilyIndices = struct {
    graphics_family: u32,
    present_family: u32,
};

/// Result of acquiring a swapchain image: which image to render into, and
/// whether the swapchain is stale and needs to be recreated before use.
pub const AcquireResult = struct {
    image_index: u32,
    needs_recreation: bool,
};

/// Everything downstream code (the renderer) needs to draw a frame.
/// Owns its Vulkan handles and the dispatch tables used to call them —
/// deinit() tears all of it down in reverse order of creation.
pub const VulkanSwapchain = struct {
    allocator: std.mem.Allocator,

    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    queue_families: QueueFamilyIndices,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    command_pool: vk.CommandPool,

    swapchain: vk.SwapchainKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    format: vk.Format,
    extent: vk.Extent2D,

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window) !VulkanSwapchain {
        var vkb = try BaseDispatch.load(getInstanceProcAddress);

        const instance = try createInstance(allocator, &vkb, window);
        var vki = try InstanceDispatch.load(instance, getInstanceProcAddress);
        errdefer vki.destroyInstance(instance, null);

        const surface = try createSurface(window, instance);
        errdefer vki.destroySurfaceKHR(instance, surface, null);

        const physical_device, const queue_families =
            try pickPhysicalDevice(allocator, &vki, instance, surface);

        const device = try createLogicalDevice(&vki, physical_device, queue_families);
        var vkd = try DeviceDispatch.load(device, vki.dispatch.vkGetDeviceProcAddr);
        errdefer vkd.destroyDevice(device, null);

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = queue_families.graphics_family,
        };
        const command_pool = try vkd.createCommandPool(device, &pool_info, null);
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        const graphics_queue = vkd.getDeviceQueue(device, queue_families.graphics_family, 0);
        const present_queue = vkd.getDeviceQueue(device, queue_families.present_family, 0);

        var swapchain_result = try createSwapchain(
            allocator,
            &vki,
            &vkd,
            physical_device,
            device,
            surface,
            queue_families,
            window,
        );
        errdefer swapchain_result.deinitHandles(&vkd, device, allocator);

        const image_views = try createImageViews(
            allocator,
            &vkd,
            device,
            swapchain_result.images,
            swapchain_result.format,
        );

        return VulkanSwapchain{
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .queue_families = queue_families,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .command_pool = command_pool,
            .swapchain = swapchain_result.swapchain,
            .images = swapchain_result.images,
            .image_views = image_views,
            .format = swapchain_result.format,
            .extent = swapchain_result.extent,
        };
    }

    pub fn deinit(self: *VulkanSwapchain) void {
        for (self.image_views) |view| self.vkd.destroyImageView(self.device, view, null);
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);

        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    /// Copies ECS transforms into a persistently mapped instance buffer and
    /// records one indexed instanced draw. The graphics pipeline must define
    /// vertex binding 0 for mesh data and binding 1, with input rate instance,
    /// for the four vec4 columns of Matrix4x4.
    pub fn drawInstanced(
        self: *VulkanSwapchain,
        command_buffer: vk.CommandBuffer,
        vertex_buffer: vk.Buffer,
        index_buffer: vk.Buffer,
        instance_buffer: vk.Buffer,
        mapped_instance_data: [*]Matrix4x4,
        transforms: []const Matrix4x4,
        index_count: u32,
    ) !void {
        if (transforms.len > max_instance_count) return error.TooManyInstances;

        @memcpy(mapped_instance_data[0..transforms.len], transforms);

        const buffers = [_]vk.Buffer{ vertex_buffer, instance_buffer };
        const offsets = [_]vk.DeviceSize{ 0, 0 };
        self.vkd.cmdBindVertexBuffers(command_buffer, 0, buffers[0..], offsets[0..]);
        self.vkd.cmdBindIndexBuffer(command_buffer, index_buffer, 0, .uint32);
        self.vkd.cmdDrawIndexed(command_buffer, index_count, @intCast(transforms.len), 0, 0, 0);
    }

    /// Acquires the next available swapchain image for rendering. Caller
    /// passes an explicit timeout (e.g. std.math.maxInt(u64) to wait
    /// indefinitely) — Zig doesn't support default parameter values on
    /// functions.
    pub fn acquire_next_image(self: *VulkanSwapchain, timeout: u64) !AcquireResult {
        var image_index: u32 = undefined;
        const result = self.vkd.acquireNextImageKHR(
            self.device,
            self.swapchain,
            timeout,
            .null_handle, // semaphore
            .null_handle, // fence
            &image_index,
        );
        if (result == .error_out_of_date_khr) {
            return .{ .image_index = 0, .needs_recreation = true };
        }
        if (result != .success and result != .suboptimal_khr) {
            return error.SwapchainAcquisitionFailed;
        }
        return .{ .image_index = image_index, .needs_recreation = false };
    }

    /// Presents the rendered image to the swapchain.
    /// Returns whether the swapchain needs to be recreated.
    pub fn present(self: *VulkanSwapchain, image_index: u32, wait_semaphore: vk.Semaphore) !bool {
        const wait_semaphores = [_]vk.Semaphore{wait_semaphore};
        const swapchains = [_]vk.SwapchainKHR{self.swapchain};
        const image_indices = [_]u32{image_index};
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = if (wait_semaphore == .null_handle) 0 else 1,
            .p_wait_semaphores = if (wait_semaphore == .null_handle) null else &wait_semaphores,
            .swapchain_count = 1,
            .p_swapchains = &swapchains,
            .p_image_indices = &image_indices,
        };
        const result = try self.vkd.queuePresentKHR(self.present_queue, &present_info);
        if (result == .error_out_of_date_khr or result == .suboptimal_khr) {
            return true;
        }
        if (result != .success) {
            return error.SwapchainPresentationFailed;
        }
        return false;
    }

    /// Recreates the swapchain and related resources when needed (e.g., after window resize).
    pub fn recreate_swapchain(self: *VulkanSwapchain, window: *c.SDL_Window) !void {
        // Wait for GPU to finish using current resources before cleaning up
        try self.vkd.deviceWaitIdle(self.device);

        // Clean up old swapchain resources
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);
        for (self.image_views) |view| self.vkd.destroyImageView(self.device, view, null);
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);

        // Recreate swapchain with new window size
        var swapchain_result = try createSwapchain(
            self.allocator,
            &self.vki,
            &self.vkd,
            self.physical_device,
            self.device,
            self.surface,
            self.queue_families,
            window,
        );
        errdefer swapchain_result.deinitHandles(&self.vkd, self.device, self.allocator);

        const image_views = try createImageViews(
            self.allocator,
            &self.vkd,
            self.device,
            swapchain_result.images,
            swapchain_result.format,
        );

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.queue_families.graphics_family,
        };
        const command_pool = try self.vkd.createCommandPool(self.device, &pool_info, null);

        self.swapchain = swapchain_result.swapchain;
        self.images = swapchain_result.images;
        self.format = swapchain_result.format;
        self.extent = swapchain_result.extent;
        self.image_views = image_views;
        self.command_pool = command_pool;
    }
};

/// vulkan-zig's dispatch-table loaders take a proc-address function
/// with this exact signature; SDL doesn't hand us one directly, so we
/// wrap SDL_Vulkan_GetVkGetInstanceProcAddr.
fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    const get_proc_addr: c.PFN_vkGetInstanceProcAddr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
    return @ptrCast(get_proc_addr.?(@as(c.VkInstance, @ptrFromInt(@intFromEnum(instance))), name));
}

fn createInstance(allocator: std.mem.Allocator, vkb: *BaseDispatch, window: *c.SDL_Window) !vk.Instance {
    _ = window; // SDL3's extension list is global, not window-specific.

    var ext_count: u32 = 0;
    const sdl_extensions = c.SDL_Vulkan_GetInstanceExtensions(&ext_count) orelse
        return error.SdlVulkanExtensionsUnavailable;

    var extension_names = try std.ArrayList([*:0]const u8).initCapacity(allocator, ext_count);
    defer extension_names.deinit();
    for (0..ext_count) |i| {
        try extension_names.append(sdl_extensions[i]);
    }

    const app_info = vk.ApplicationInfo{
        .p_application_name = "engine",
        .application_version = vk.makeApiVersion(0, 0, 1, 0),
        .p_engine_name = "engine",
        .engine_version = vk.makeApiVersion(0, 0, 1, 0),
        .api_version = vk.API_VERSION_1_2,
    };

    return vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
    }, null);
}

fn createSurface(window: *c.SDL_Window, instance: vk.Instance) !vk.SurfaceKHR {
    var surface: c.VkSurfaceKHR = undefined;
    const raw_instance: c.VkInstance = @ptrFromInt(@intFromEnum(instance));
    if (!c.SDL_Vulkan_CreateSurface(window, raw_instance, null, &surface)) {
        return error.SurfaceCreationFailed;
    }
    return @enumFromInt(@intFromPtr(surface.?));
}

fn findQueueFamilies(
    allocator: std.mem.Allocator,
    vki: *InstanceDispatch,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !?QueueFamilyIndices {
    var count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(device, &count, null);
    const families = try allocator.alloc(vk.QueueFamilyProperties, count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(device, &count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |family, i| {
        const idx: u32 = @intCast(i);

        if (family.queue_flags.graphics_bit) graphics_family = idx;

        const present_support = try vki.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface);
        if (present_support == vk.TRUE) present_family = idx;

        if (graphics_family != null and present_family != null) break;
    }

    if (graphics_family == null or present_family == null) return null;
    return QueueFamilyIndices{
        .graphics_family = graphics_family.?,
        .present_family = present_family.?,
    };
}

fn pickPhysicalDevice(
    allocator: std.mem.Allocator,
    vki: *InstanceDispatch,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
) !struct { vk.PhysicalDevice, QueueFamilyIndices } {
    var count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &count, null);
    if (count == 0) return error.NoVulkanCapableDevice;

    const devices = try allocator.alloc(vk.PhysicalDevice, count);
    defer allocator.free(devices);
    _ = try vki.enumeratePhysicalDevices(instance, &count, devices.ptr);

    for (devices) |device| {
        if (try findQueueFamilies(allocator, vki, device, surface)) |families| {
            return .{ device, families };
        }
    }
    return error.NoSuitableDevice;
}

fn createLogicalDevice(
    vki: *InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    families: QueueFamilyIndices,
) !vk.Device {
    const priority: f32 = 1.0;
    const unique_families: [2]u32 = .{ families.graphics_family, families.present_family };
    const family_count: usize = if (families.graphics_family == families.present_family) 1 else 2;

    var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
    for (0..family_count) |i| {
        queue_infos[i] = .{
            .queue_family_index = unique_families[i],
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&priority),
        };
    }

    const device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

    return vki.createDevice(physical_device, &.{
        .queue_create_info_count = @intCast(family_count),
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = device_extensions.len,
        .pp_enabled_extension_names = &device_extensions,
    }, null);
}

const SwapchainResult = struct {
    swapchain: vk.SwapchainKHR,
    images: []vk.Image,
    format: vk.Format,
    extent: vk.Extent2D,

    fn deinitHandles(self: *SwapchainResult, vkd: *DeviceDispatch, device: vk.Device, allocator: std.mem.Allocator) void {
        vkd.destroySwapchainKHR(device, self.swapchain, null);
        allocator.free(self.images);
    }
};

fn createSwapchain(
    allocator: std.mem.Allocator,
    vki: *InstanceDispatch,
    vkd: *DeviceDispatch,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    families: QueueFamilyIndices,
    window: *c.SDL_Window,
) !SwapchainResult {
    const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    var format_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);
    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(formats);
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, formats.ptr);

    var chosen_format = formats[0];
    for (formats) |fmt| {
        if (fmt.format == .b8g8r8a8_srgb and fmt.color_space == .srgb_nonlinear_khr) {
            chosen_format = fmt;
            break;
        }
    }

    var present_mode: vk.PresentModeKHR = .fifo_khr; // guaranteed available, vsync'd
    var mode_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, null);
    const modes = try allocator.alloc(vk.PresentModeKHR, mode_count);
    defer allocator.free(modes);
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, modes.ptr);
    for (modes) |mode| {
        if (mode == .mailbox_khr) {
            present_mode = mode;
            break;
        }
    }

    const extent = if (capabilities.current_extent.width != std.math.maxInt(u32))
        capabilities.current_extent
    else blk: {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &w, &h);
        break :blk vk.Extent2D{
            .width = std.math.clamp(@as(u32, @intCast(w)), capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(@as(u32, @intCast(h)), capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        };
    };

    var image_count = capabilities.min_image_count + 1;
    if (capabilities.max_image_count > 0 and image_count > capabilities.max_image_count) {
        image_count = capabilities.max_image_count;
    }

    const same_family = families.graphics_family == families.present_family;
    const queue_indices = [_]u32{ families.graphics_family, families.present_family };

    const swapchain = try vkd.createSwapchainKHR(device, &.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = chosen_format.format,
        .image_color_space = chosen_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = if (same_family) .exclusive else .concurrent,
        .queue_family_index_count = if (same_family) 0 else queue_indices.len,
        .p_queue_family_indices = if (same_family) null else &queue_indices,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    }, null);

    var actual_count: u32 = 0;
    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &actual_count, null);
    const images = try allocator.alloc(vk.Image, actual_count);
    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &actual_count, images.ptr);

    return SwapchainResult{
        .swapchain = swapchain,
        .images = images,
        .format = chosen_format.format,
        .extent = extent,
    };
}

fn createImageViews(
    allocator: std.mem.Allocator,
    vkd: *DeviceDispatch,
    device: vk.Device,
    images: []const vk.Image,
    format: vk.Format,
) ![]vk.ImageView {
    const views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(views);

    for (images, 0..) |image, i| {
        views[i] = try vkd.createImageView(device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }
    return views;
}
