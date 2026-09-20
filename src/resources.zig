const std = @import("std");
const vk = @import("vulkan");
const c = @import("sdl_bindings.zig");
const png = @import("libpng"); // TODO: Verify libpng import works

/// Represents a texture loaded into GPU memory.
pub const Texture = struct {
    allocator: std.mem.Allocator,
    image: vk.Image,
    image_memory: vk.DeviceSize,
    image_view: vk.ImageView,
    sampler: vk.Sampler,
    width: u32,
    height: u32,
    format: vk.Format,
    pub fn deinit(self: *Texture, vkd: *vk.DeviceWrapper, device: vk.Device) void {
        vkd.destroyImageView(device, self.image_view, null);
        vkd.destroyImage(device, self.image, null);
        self.allocator.free(self.image_memory);
    }
};

/// Cache for textures with reference counting and automatic cleanup.
pub const TextureCache = struct {
    allocator: std::mem.Allocator,
    vulkan: *VulkanSwapchain,
    textures: std.ArrayList(Texture),
    key_to_index: std.StringHashMap(usize),
    sampler: vk.Sampler,
    pub fn init(allocator: std.mem.Allocator, vulkan: *VulkanSwapchain) !TextureCache {
        // Create a default sampler for all textures in this cache
        const sampler = try createSampler(&vulkan.vkd, vulkan.device);
        defer |err| {
            vulkan.vkd.destroySampler(vulkan.device, sampler, null);
        };
        return TextureCache{
            .allocator = allocator,
            .vulkan = vulkan,
            .textures = try std.ArrayList(Texture).initCapacity(allocator, 16),
            .key_to_index = try std.StringHashMap(usize).initCapacity(allocator, 16),
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *TextureCache) void {
        // Destroy all textures
        for (self.textures.items) |texture| {
            texture.deinit(&self.vulkan.vkd, self.vulkan.device);
        }
        self.textures.deinit();
        self.key_to_index.deinit();
        self.vulkan.vkd.destroySampler(self.vulkan.device, self.sampler, null);
    }

    /// Get a texture by key, loading it if necessary.
    pub fn getOrLoad(self: *TextureCache, key: []const u8) !*Texture {
        if (self.key_to_index.get(key)) |index| {
            return &self.textures.items[index.*];
        }

        // Load texture from file
        const texture = try self.loadTextureFromFile(key);
        const index = self.textures.append(texture);
        try self.key_to_index.put(key, index);
        return &self.textures.items[index];
    }

    fn loadTextureFromFile(self: *TextureCache, file_path: []const u8) !Texture {
        // Load PNG file using libpng
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const png_struct = try png.createReadStruct();
        defer png.destroyReadStruct(&png_struct);
        const png_info = try png.createInfoStruct(png_struct.ptr);
        defer png.destroyInfoStruct(png_struct.ptr, &png_info);
        if (png.setjmp(png_struct.ptr, png_info.ptr) != 0) {
            return error.PngLoadFailed;
        }
        png.initIO(png_struct.ptr, file.handle);
        png.readInfo(png_struct.ptr, png_info.ptr);
        const width = png.getImageWidth(png_struct.ptr, png_info.ptr);
        const height = png.getImageHeight(png_struct.ptr, png_info.ptr);
        const color_type = png.getColorType(png_struct.ptr, png_info.ptr);
        const bit_depth = png.getBitDepth(png_struct.ptr, png_info.ptr);
        // Convert to RGBA8
        if (bit_depth == 16) png.setStrip16(png_struct.ptr);
        if (color_type == .png_COLOR_TYPE_PALETTE) png.setPaletteToRGB(png_struct.ptr);
        if (color_type == .png_COLOR_TYPE_GRAY and bit_depth < 8) png.setExpandGRAYToRGB(png_struct.ptr);
        if (png.getValid(png_struct.ptr, png_info.ptr, .png_VALID_tRNS)) png.setTNSToAlpha(png_struct.ptr);
        if (color_type == .png_COLOR_TYPE_RGB or color_type == .png_COLOR_TYPE_GRAY or color_type == .png_COLOR_TYPE_PALETTE)
            png.setAddAlpha(png_struct.ptr);
        if (color_type == .png_COLOR_TYPE_GRAY or color_type == .png_COLOR_TYPE_GRAY_ALPHA)
            png.setGrayToRGB(png_struct.ptr);
        png.readUpdateInfo(png_struct.ptr, png_info.ptr);
        const rowbytes = png.getRowBytes(png_struct.ptr, png_info.ptr);
        const pixels = try self.allocator.alloc(u8, rowbytes * @intCast(height));
        defer self.allocator.free(pixels);
        var row_pointers: [*:0]*u8 = undefined;
        for (0..height) |i| {
            row_pointers[i] = pixels[@intCast(i) * rowbytes..];
        }
        png.readImage(png_struct.ptr, &row_pointers);
        // Create Vulkan image
        const image_info = vk.ImageCreateInfo{
            .imageType = vk.IMAGE_TYPE_2D,
            .format = vk.FORMAT_R8G8B8A8_SRGB,
            .extent = vk.Extent3D{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SAMPLE_COUNT_1_BIT,
            .tiling = vk.IMAGE_TILING_OPTIMAL,
            .usage = vk.ImageUsageFlags{ .transfer_destination_bit = true, .sampled_bit = true },
            .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
        };
        const image = try self.vulkan.vkd.createImage(self.vulkan.device, &image_info, null);
        // Allocate memory
        const mem_requirements = self.vulkan.vkd.getImageMemoryRequirements(self.vulkan.device, image);
        const mem_type_index = try findMemoryType(self.vulkan.allocator, self.vulkan.vki, self.vulkan.physical_device, mem_requirements, vk.MemoryPropertyFlags{ .device_local_bit = true });
        const alloc_info = vk.MemoryAllocateInfo{
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };
        const image_memory = try self.vulkan.vkd.allocateMemory(self.vulkan.device, &alloc_info, null);
        try self.vulkan.vkd.bindImageMemory(self.vulkan.device, image, image_memory, 0);
        // Copy pixel data to image via staging buffer
        const buffer_info = vk.BufferCreateInfo{
            .size = @intCast(rowbytes * height),
            .usage = vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
        };
        const staging_buffer = try self.vulkan.vkd.createBuffer(self.vulkan.device, &buffer_info, null);
        const buf_mem_req = self.vulkan.vkd.getBufferMemoryRequirements(self.vulkan.device, staging_buffer);
        const buf_mem_type_index = try findMemoryType(self.vulkan.allocator, self.vulkan.vki, self.vulkan.physical_device, buf_mem_req, vk.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true });
        const buf_alloc_info = vk.MemoryAllocateInfo{
            .allocationSize = buf_mem_req.size,
            .memoryTypeIndex = buf_mem_type_index,
        };
        const staging_buffer_memory = try self.vulkan.vkd.allocateMemory(self.vulkan.device, &buf_alloc_info, null);
        defer self.vulkan.vkd.freeMemory(self.vulkan.device, staging_buffer_memory, null);
        defer self.vulkan.vkd.destroyBuffer(self.vulkan.device, staging_buffer, null);
        try self.vulkan.vkd.bindBufferMemory(self.vulkan.device, staging_buffer, staging_buffer_memory, 0);
        // Map memory and copy pixel data
        const data = try self.vulkan.vkd.mapMemory(self.vulkan.device, staging_buffer_memory, 0, buf_mem_req.size, vk.MemoryMapFlags{});
        @memcpy(data[0..@intCast(rowbytes * height)], pixels[0..@intCast(rowbytes * height)]);
        self.vulkan.vkd.unmapMemory(self.vulkan.device, staging_buffer_memory);
        // Transition image layout and copy buffer to image
        const command_buffer = try beginSingleTimeCommands(self.vulkan);
        transitionImageLayout(command_buffer, image, vk.FORMAT_R8G8B8A8_SRGB, vk.IMAGE_LAYOUT_UNDEFINED, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        copyBufferToImage(command_buffer, staging_buffer, image, @intCast(width), @intCast(height));
        transitionImageLayout(command_buffer, image, vk.FORMAT_R8G8B8A8_SRGB, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        endSingleTimeCommands(self.vulkan, command_buffer);
        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .image = image,
            .viewType = vk.IMAGE_VIEW_TYPE_2D,
            .format = vk.FORMAT_R8G8B8A8_SRGB,
            .components = vk.ComponentMapping{
                .r = vk.COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = vk.ImageSubresourceRange{
                .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        const view = try self.vulkan.vkd.createImageView(self.vulkan.device, &view_info, null);
        return Texture{
            .allocator = self.allocator,
            .image = image,
            .image_memory = image_memory,
            .image_view = view,
            .sampler = self.sampler,
            .width = @intCast(width),
            .height = @intCast(height),
            .format = vk.FORMAT_R8G8B8A8_SRGB,
        };
    }
};

fn createSampler(vkd: *vk.DeviceWrapper, device: vk.Device) !vk.Sampler {
    const sampler_info = vk.SamplerCreateInfo{
        .magFilter = vk.FILTER_LINEAR,
        .minFilter = vk.FILTER_LINEAR,
        .addressModeU = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = vk.TRUE,
        .maxAnisotropy = 16,
        .borderColor = vk.BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.FALSE,
        .compareEnable = vk.FALSE,
        .mipmapMode = vk.SAMPLER_MIPMAP_MODE_LINEAR,
    };
    return vkd.createDevice(device, &sampler_info, null);
}

fn findMemoryType(allocator: std.mem.Allocator, vki: *vk.InstanceWrapper, physical_device: vk.PhysicalDevice, mem_requirements: vk.MemoryRequirements, required_properties: vk.MemoryPropertyFlags) !u32 {
    const mem_properties = vki.getPhysicalDeviceMemoryProperties(physical_device);
    for (mem_properties.memoryTypes, 0..) |mem_type, index| {
        if (mem_requirements.memoryTypeBits & (1 @shLt index) != 0 and
            (mem_type.propertyFlags & required_properties) == required_properties) {
            return @intCast(index);
        }
    }
    return error.NoSuitableMemoryType;
}

fn beginSingleTimeCommands(vulkan: *VulkanSwapchain) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = vulkan.command_pool, // TODO: Add command_pool to VulkanSwapchain
        .commandBufferCount = 1,
    };
    var command_buffers: [1]vk.CommandBuffer = undefined;
    vulkan.vkd.allocateCommandBuffers(vulkan.device, &alloc_info, &command_buffers);
    const command_buffer = command_buffers[0];
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vulkan.vkd.beginCommandBuffer(command_buffer, &begin_info);
    return command_buffer;
}

fn endSingleTimeCommands(vulkan: *VulkanSwapchain, command_buffer: vk.CommandBuffer) void {
    vulkan.vkd.endCommandBuffer(command_buffer);
    const submit_info = vk.SubmitInfo{
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    vulkan.vkd.queueSubmit(vulkan.graphics_queue, 1, &submit_info, .null_handle);
    vulkan.vkd.queueWaitIdle(vulkan.graphics_queue);
    vulkan.vkd.freeCommandBuffers(vulkan.device, vulkan.command_pool, 1, &command_buffer); // TODO: Add command_pool
}

fn transitionImageLayout(command_buffer: vk.CommandBuffer, image: vk.Image, format: vk.Format, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const barrier = vk.ImageMemoryBarrier{
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = vk.ImageSubresourceRange{
            .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    const src_access_mask = if (old_layout == vk.IMAGE_LAYOUT_UNDEFINED) vk.AccessFlags{} else vk.AccessFlags{ .transfer_write_bit = true };
    const dst_access_mask = if (new_layout == vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) vk.AccessFlags{ .transfer_write_bit = true } else if (new_layout == vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) vk.AccessFlags{ .shader_read_bit = true } else vk.AccessFlags{};
    barrier.srcAccessMask = src_access_mask;
    barrier.dstAccessMask = dst_access_mask;
    vulkan.vkd.cmdPipelineBarrier(command_buffer, vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
}

fn copyBufferToImage(command_buffer: vk.CommandBuffer, buffer: vk.Buffer, image: vk.Image, width: u32, height: u32) void {
    const region = vk.BufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = vk.ImageSubresourceLayers{
            .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = vk.Extent3D{
            .width = @intCast(width),
            .height = @intCast(height),
            .depth = 1,
        },
    };
    vulkan.vkd.cmdCopyBufferToImage(command_buffer, buffer, image, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
}

pub const Font = struct {
    // TODO: Implement font loading with FreeType and Harfbuzz
    placeholder: u32,
};

pub const FontCache = struct {
    // TODO: Implement font cache
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) !FontCache {
        return FontCache{ .allocator = allocator };
    }
    pub fn deinit(self: *FontCache) void {}
    pub fn getOrLoad(self: *FontCache, key: []const u8) !*Font {
        return &Font{ .placeholder = 0 };
    }
};

pub const Shader = struct {
    // TODO: Implement shader module loading
    module: vk.ShaderModule,
    pub fn deinit(self: *Shader, vkd: *vk.DeviceWrapper, device: vk.Device) void {
        vkd.destroyShaderModule(device, self.module, null);
    }
};

pub const ShaderCache = struct {
    allocator: std.mem.Allocator,
    vulkan: *VulkanSwapchain,
    shaders: std.ArrayList(Shader),
    key_to_index: std.StringHashMap(usize),
    pub fn init(allocator: std.mem.Allocator, vulkan: *VulkanSwapchain) !ShaderCache {
        return ShaderCache{
            .allocator = allocator,
            .vulkan = vulkan,
            .shaders = try std.ArrayList(Shader).initCapacity(allocator, 16),
            .key_to_index = try std.StringHashMap(usize).initCapacity(allocator, 16),
        };
    }
    pub fn deinit(self: *ShaderCache) void {
        for (self.shaders.items) |shader| {
            shader.deinit(&self.vulkan.vkd, self.vulkan.device);
        }
        self.shaders.deinit();
        self.key_to_index.deinit();
    }
    pub fn getOrLoad(self: *ShaderCache, key: []const u8) !*Shader {
        if (self.key_to_index.get(key)) |index| {
            return &self.shaders.items[index.*];
        }
        // Load SPIR-V file
        const shader_data = try std.fs.cwd().readFile(key);
        const shader_info = vk.ShaderModuleCreateInfo{
            .codeSize = shader_data.len,
            .pCode = @ptrCast([*:]u32)(shader_data.ptr),
        };
        const module = try self.vulkan.vkd.createShaderModule(self.vulkan.device, &shader_info, null);
        const index = self.shaders.append(Shader{ .module = module });
        try self.key_to_index.put(key, index);
        return &self.shaders.items[index];
    }
};