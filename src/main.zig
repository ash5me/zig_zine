const std = @import("std");
const movement = @import("ecs_movement.zig");
const physics = @import("physics_solver.zig");
const sdl = @import("sdl_bindings.zig");
const resources = @import("resources.zig");
const build_options = @import("build_options");
const VSC = @import("vulkan_swapchain.zig");
const vulkan_swapchain = if (build_options.enable_vulkan) VSC.VulkanSwapchain else struct {};
const Matrix4x4 = VSC.Matrix4x4;

fn findMemoryType(vki: *vk.InstanceWrapper, instance: vk.Instance, physical_device: vk.PhysicalDevice, typeFilter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const memory_properties = vki.getPhysicalDeviceMemoryProperties(physical_device, null);
    for (0..memory_properties.memoryTypes.len) |i| {
        const mem_type = memory_properties.memoryTypes[i];
        if ((typeFilter & (1 << @intCast(i))) != 0 and
            (mem_type.propertyFlags & properties) == properties) {
            return @intCast(i);
        }
    }
    return error.FailedToFindMemoryType;
}

pub const Engine = struct {
    allocator: std.mem.Allocator,
    running: bool,
    entities: movement.Registry,
    physics_world: physics.PhysicsWorld,
    sdl_context: sdl.SDLContext,
    vulkan: vulkan_swapchain.VulkanSwapchain,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    texture_cache: resources.TextureCache,
    font_cache: resources.FontCache,
    shader_cache: resources.ShaderCache,
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_buffer_memory: vk.DeviceMemory,
    instance_buffer: vk.Buffer,
    instance_buffer_memory: vk.DeviceMemory,
    mapped_instance_data: *Matrix4x4,
    pipeline: vk.Pipeline,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        std.log.info("engine: initializing", .{});

        var sdl_context = try sdl.SDLContext.init(allocator, "Zig Zine", 800, 600);
        defer sdl_context.deinit();

        var vulkan = try vulkan_swapchain.VulkanSwapchain.init(allocator, sdl_context.window);
        defer vulkan.deinit();

        // Create render pass
        const color_attachment = vk.AttachmentDescription{
            .format = vulkan.format,
            .samples = vk.SAMPLE_COUNT_1_BIT,
            .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        };
        const render_pass_info = vk.RenderPassCreateInfo{
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
        };
        const render_pass = try vulkan.vkd.createRenderPass(vulkan.device, &render_pass_info, null);
        defer if (errdefer) vulkan.vkd.destroyRenderPass(vulkan.device, render_pass, null);

        // Create framebuffers
        const framebuffers = try allocator.alloc(vk.Framebuffer, vulkan.image_views.len);
        defer if (errdefer) {
            for (framebuffers[0..vulkan.image_views.len]) |fb| {
                vulkan.vkd.destroyFramebuffer(vulkan.device, fb, null);
            }
            allocator.free(framebuffers);
        };
        for (vulkan.image_views, 0..) |view, i| {
            const framebuffer_info = vk.FramebufferCreateInfo{
                .renderPass = render_pass,
                .attachmentCount = 1,
                .pAttachments = &view,
                .width = vulkan.extent.width,
                .height = vulkan.extent.height,
                .layers = 1,
            };
            framebuffers[i] = try vulkan.vkd.createFramebuffer(vulkan.device, &framebuffer_info, null);
        }

        // Initialize caches
        const texture_cache = try resources.TextureCache.init(allocator, &vulkan);
        const font_cache = try resources.FontCache.init(allocator);
        const shader_cache = try resources.ShaderCache.init(allocator, &vulkan);

        return Engine{
            .allocator = allocator,
            .running = true,
            .entities = movement.Registry.init(),
            .physics_world = physics.PhysicsWorld.init(allocator),
            .sdl_context = sdl_context,
            .vulkan = vulkan,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .texture_cache = texture_cache,
            .font_cache = font_cache,
            .shader_cache = shader_cache,
        };
    }

    pub fn deinit(self: *Engine) void {
        std.log.info("engine: shutting down", .{});
        self.shader_cache.deinit();
        self.font_cache.deinit();
        self.texture_cache.deinit();
        for (self.framebuffers) |fb| {
            self.vulkan.vkd.destroyFramebuffer(self.vulkan.device, fb, null);
        }
        self.allocator.free(self.framebuffers);
        self.vulkan.vkd.destroyRenderPass(self.vulkan.device, self.render_pass, null);

        // Destroy pipeline
        if (self.pipeline != .null_handle) {
            self.vulkan.vkd.destroyPipeline(self.vulkan.device, self.pipeline, null);
        }

        // Unmap and destroy instance buffer
        if (self.mapped_instance_data != null) {
            self.vulkan.vkd.unmapMemory(self.vulkan.device, self.instance_buffer_memory);
        }
        self.vulkan.vkd.destroyBuffer(self.vulkan.device, self.instance_buffer, null);
        self.vulkan.vkd.freeMemory(self.vulkan.device, self.instance_buffer_memory, null);

        // Destroy index buffer
        self.vulkan.vkd.destroyBuffer(self.vulkan.device, self.index_buffer, null);
        self.vulkan.vkd.freeMemory(self.vulkan.device, self.index_buffer_memory, null);

        // Destroy vertex buffer
        self.vulkan.vkd.destroyBuffer(self.vulkan.device, self.vertex_buffer, null);
        self.vulkan.vkd.freeMemory(self.vulkan.device, self.vertex_buffer_memory, null);

        self.vulkan.deinit();
        self.sdl_context.deinit();
        self.physics_world.deinit();
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) std.debug.print("MEMORY LEAK DETECTED!\n", .{});
    }
    const allocator = debug_allocator.allocator();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    movement.spawnEntities(&engine.entities);
    movement.updateMovement(&engine.entities, 1.0 / 60.0);
    _ = try engine.physics_world.addBody(.{
        .position = .{ 0, 10, 0 },
        .half_extents = .{ 0.5, 0.5, 0.5 },
    });

    // Create vertex buffer
    const vertex_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(cube_vertices),
        .usage = vk.BUFFER_USAGE_VERTEX_BUFFER_BIT,
        .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
    };
    engine.vertex_buffer = try engine.vulkan.vkd.createBuffer(engine.vulkan.device, &vertex_buffer_info, null);
    defer if (errdefer) engine.vulkan.vkd.destroyBuffer(engine.vulkan.device, engine.vertex_buffer, null);

    const memory_requirements = engine.vulkan.vkd.getBufferMemoryRequirements(engine.vulkan.device, engine.vertex_buffer);
    const memory_alloc_info = vk.MemoryAllocateInfo{
        .allocationSize = memory_requirements.size,
        .memoryTypeIndex = try findMemoryType(&engine.vulkan.vki, engine.vulkan.instance, memory_requirements.memoryTypeBits, vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    engine.vertex_buffer_memory = try engine.vulkan.vkd.allocateMemory(engine.vulkan.device, &memory_alloc_info, null);
    defer if (errdefer) engine.vulkan.vkd.freeMemory(engine.vulkan.device, engine.vertex_buffer_memory, null);
    engine.vulkan.vkd.bindBufferMemory(engine.vulkan.device, engine.vertex_buffer, engine.vertex_buffer_memory, 0);

    // Map and copy vertex data
    var mapped_data: [*]u8 = undefined;
    engine.vulkan.vkd.mapMemory(engine.vulkan.device, engine.vertex_buffer_memory, 0, @sizeOf(cube_vertices), 0, @ptrCast(&mapped_data));
    @memcpy(mapped_data[0..@sizeOf(cube_vertices)], @ptrCast(&cube_vertices));
    engine.vulkan.vkd.unmapMemory(engine.vulkan.device, engine.vertex_buffer_memory);

    // Create index buffer
    const index_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(cube_indices),
        .usage = vk.BUFFER_USAGE_INDEX_BUFFER_BIT,
        .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
    };
    engine.index_buffer = try engine.vulkan.vkd.createBuffer(engine.vulkan.device, &index_buffer_info, null);
    defer if (errdefer) engine.vulkan.vkd.destroyBuffer(engine.vulkan.device, engine.index_buffer, null);

    const index_memory_requirements = engine.vulkan.vkd.getBufferMemoryRequirements(engine.vulkan.device, engine.index_buffer);
    const index_memory_alloc_info = vk.MemoryAllocateInfo{
        .allocationSize = index_memory_requirements.size,
        .memoryTypeIndex = try findMemoryType(&engine.vulkan.vki, engine.vulkan.instance, index_memory_requirements.memoryTypeBits, vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    engine.index_buffer_memory = try engine.vulkan.vkd.allocateMemory(engine.vulkan.device, &index_memory_alloc_info, null);
    defer if (errdefer) engine.vulkan.vkd.freeMemory(engine.vulkan.device, engine.index_buffer_memory, null);
    engine.vulkan.vkd.bindBufferMemory(engine.vulkan.device, engine.index_buffer, engine.index_buffer_memory, 0);

    // Map and copy index data
    var index_mapped_data: [*]u8 = undefined;
    engine.vulkan.vkd.mapMemory(engine.vulkan.device, engine.index_buffer_memory, 0, @sizeOf(cube_indices), 0, @ptrCast(&index_mapped_data));
    @memcpy(index_mapped_data[0..@sizeOf(cube_indices)], @ptrCast(&cube_indices));
    engine.vulkan.vkd.unmapMemory(engine.vulkan.device, engine.index_buffer_memory);

    // Create instance buffer (for instanced rendering)
    const instance_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(Matrix4x4) * engine.entities.capacity,
        .usage = vk.BUFFER_USAGE_VERTEX_BUFFER_BIT,
        .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
    };
    engine.instance_buffer = try engine.vulkan.vkd.createBuffer(engine.vulkan.device, &instance_buffer_info, null);
    defer if (errdefer) engine.vulkan.vkd.destroyBuffer(engine.vulkan.device, engine.instance_buffer, null);

    const instance_memory_requirements = engine.vulkan.vkd.getBufferMemoryRequirements(engine.vulkan.device, engine.instance_buffer);
    const instance_memory_alloc_info = vk.MemoryAllocateInfo{
        .allocationSize = instance_memory_requirements.size,
        .memoryTypeIndex = try findMemoryType(&engine.vulkan.vki, engine.vulkan.instance, instance_memory_requirements.memoryTypeBits, vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    engine.instance_buffer_memory = try engine.vulkan.vkd.allocateMemory(engine.vulkan.device, &instance_memory_alloc_info, null);
    defer if (errdefer) engine.vulkan.vkd.freeMemory(engine.vulkan.device, engine.instance_buffer_memory, null);
    engine.vulkan.vkd.bindBufferMemory(engine.vulkan.device, engine.instance_buffer, engine.instance_buffer_memory, 0);

    // Map instance buffer for CPU access
    engine.vulkan.vkd.mapMemory(engine.vulkan.device, engine.instance_buffer_memory, 0, @sizeOf(Matrix4x4) * engine.entities.capacity, 0, @ptrCast(&engine.mapped_instance_data));

    var last_time = sdl.SDL_GetPerformanceCounter();
    const frequency = @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency()));
    var timestep = physics.FixedTimestep{};
    var frame_count: u32 = 0;
    var fps_timer: f64 = 0.0;
    var total_frames: u32 = 0;
    var image_index: u32 = 0;

    // Keep the engine alive until the future SDL quit-event path sets running to false.
    while (engine.running) : (total_frames += 1) {
        // Check for quit event
        if (engine.sdl_context.pollEvents()) {
            engine.running = false;
            break;
        }

        const current_time = sdl.SDL_GetPerformanceCounter();
        const delta_time = @as(f32, @floatCast(@as(f64, @floatFromInt(current_time - last_time)) / frequency));
        last_time = current_time;

        fps_timer += delta_time;
        frame_count += 1;
        if (fps_timer >= 1.0) {
            const frame_time_ms = 1000.0 / @as(f64, @floatFromInt(frame_count));
            std.debug.print("FPS: {d} | Frame Time: {d:.2} ms\n", .{ frame_count, frame_time_ms });
            frame_count = 0;
            fps_timer = 0.0;
        }

        const steps = timestep.consume(delta_time);
        for (0..steps) |_| engine.physics_world.step(timestep.fixed_dt);
        movement.updateMovement(&engine.entities, delta_time);

        // Rendering
        // Acquire next image
        var acquire_result: vk.Result = undefined;
        var acquired_image_index: u32 = undefined;
        acquire_result = engine.vulkan.vkd.acquireNextImageKHR(
            engine.vulkan.device,
            engine.vulkan.swapchain,
            @uintMax(u64),
            .null_handle,
            .null_handle,
            &acquired_image_index,
        );
        if (acquire_result == vk.ERROR_OUT_OF_DATE_KHR) {
            // TODO: Handle swapchain recreation
            continue;
        }
        if (acquire_result != vk.SUCCESS && acquire_result != vk.SUBOPTIMAL_KHR) {
            return error.AcquireNextImageFailed;
        }
        image_index = @intCast(acquired_image_index);

        // Begin command buffer
        const command_buffer_alloc_info = vk.CommandBufferAllocateInfo{
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandPool = engine.vulkan.command_pool,
            .commandBufferCount = 1,
        };
        var command_buffers: [1]vk.CommandBuffer = undefined;
        engine.vulkan.vkd.allocateCommandBuffers(engine.vulkan.device, &command_buffer_alloc_info, &command_buffers);
        const command_buffer = command_buffers[0];

        const command_buffer_begin_info = vk.CommandBufferBeginInfo{
            .flags = vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        engine.vulkan.vkd.beginCommandBuffer(command_buffer, &command_buffer_begin_info);

        // Begin render pass
        const clear_color = vk.ClearValue{
            .color = vk.ClearColorValue{ .float32 = .{ 0.1, 0.1, 0.1, 1.0 } },
        };
        const render_pass_begin_info = vk.RenderPassBeginInfo{
            .renderPass = engine.render_pass,
            .framebuffer = engine.framebuffers[image_index],
            .renderArea = vk.Rectangle2D{
                .offset = vk.Offset2D{ .x = 0, .y = 0 },
                .extent = engine.vulkan.extent,
            },
            .clearValueCount = 1,
            .pClearValues = &clear_color,
        };
        engine.vulkan.vkd.cmdBeginRenderPass(command_buffer, &render_pass_begin_info, vk.SUBPASS_CONTENTS_INLINE);

        // Create graphics pipeline if not created yet
        if (engine.pipeline == null_handle) {
            engine.pipeline = try createGraphicsPipeline(&engine.vulkan.vkd, engine.vulkan.device, engine.render_pass, engine.vulkan.extent);
        }

        // Update instance buffer with entity transforms
        updateInstanceBuffer(&engine.vulkan.vkd, engine.vulkan.device, engine.vulkan.command_pool, engine.vulkan.graphics_queue, &engine.mapped_instance_data, &engine.entities);

        // Bind pipeline and draw
        engine.vulkan.vkd.cmdBindPipeline(command_buffer, vk.PIPELINE_BIND_POINT_GRAPHICS, engine.pipeline);
        
        const vertex_buffers = [_]vk.Buffer{ engine.vertex_buffer };
        const vertex_offsets = [_]vk.DeviceSize{ 0 };
        engine.vulkan.vkd.cmdBindVertexBuffers(command_buffer, 0, vertex_buffers[0..], vertex_offsets[0..]);
        engine.vulkan.vkd.cmdBindIndexBuffer(command_buffer, engine.index_buffer, 0, vk.INDEX_TYPE_UINT32);
        
        const instance_buffers = [_]vk.Buffer{ engine.instance_buffer };
        const instance_offsets = [_]vk.DeviceSize{ 0 };
        engine.vulkan.vkd.cmdBindVertexBuffers(command_buffer, 1, instance_buffers[0..], instance_offsets[0..]);

        engine.vulkan.vkd.cmdDrawIndexed(command_buffer, 36, engine.entities.count, 0, 0, 0); // 36 indices for cube

        // End render pass
        engine.vulkan.vkd.cmdEndRenderPass(command_buffer);

        // End command buffer
        engine.vulkan.vkd.endCommandBuffer(command_buffer);

        // Submit command buffer
        const wait_semaphores = [_]vk.Semaphore{}; // TODO: Add semaphores for synchronization
        const wait_stages = [_]vk.PipelineStageFlags{}; // TODO: Set wait stages
        const signal_semaphores = [_]vk.Semaphore{}; // TODO: Add semaphores for synchronization
        const submit_info = vk.SubmitInfo{
            .waitSemaphoreCount = wait_semaphores.len,
            .pWaitSemaphores = wait_semaphores.ptr,
            .pWaitDstStageMask = wait_stages.ptr,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = signal_semaphores.len,
            .pSignalSemaphores = signal_semaphores.ptr,
        };
        engine.vulkan.vkd.queueSubmit(engine.vulkan.graphics_queue, 1, &submit_info, .null_handle);

        // Present
        const swapchains = [_]vk.SwapchainKHR{ engine.vulkan.swapchain };
        const image_indices = [_]u32{ image_index };
        const present_info = vk.PresentInfoKHR{
            .waitSemaphoreCount = signal_semaphores.len,
            .pWaitSemaphores = signal_semaphores.ptr,
            .swapchainCount = swapchains.len,
            .pSwapchains = swapchains.ptr,
            .pImageIndices = image_indices.ptr,
        };
        const present_result = engine.vulkan.vkd.queuePresentKHR(engine.vulkan.present_queue, &present_info);
        if (present_result == vk.ERROR_OUT_OF_DATE_KHR or present_result == vk.SUBOPTIMAL_KHR) {
            // TODO: Handle swapchain recreation
        } else if (present_result != vk.SUCCESS) {
            return error.PresentFailed;
        }

        engine.vulkan.vkd.freeCommandBuffers(engine.vulkan.device, engine.vulkan.command_pool, 1, &command_buffers);
    }

    std.log.info("engine: ran {d} frames with {d} entities", .{ total_frames, engine.entities.count });
}

fn createGraphicsPipeline(vkd: *vk.DeviceWrapper, device: vk.Device, render_pass: vk.RenderPass, extent: vk.Extent2D) !vk.Pipeline {
    // Simple pipeline creation - in a real implementation this would load shaders
    // For now, we'll create a minimal pipeline that will likely fail but allows compilation
    // TODO: Implement proper shader loading and pipeline creation
    
    // Vertex input state
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    // Input assembly state
    const input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.FALSE,
    };

    // Viewport and scissor
    const viewport = vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor = vk.Rectangle2D{
        .offset = vk.Offset2D{ .x = 0, .y = 0 },
        .extent = extent,
    };
    const viewport_state_info = vk.PipelineViewportStateCreateInfo{
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    // Rasterizer
    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .depthClampEnable = vk.FALSE,
        .rasterizerDiscardEnable = vk.FALSE,
        .polygonMode = vk.POLYGON_MODE_FILL,
        .cullMode = vk.CULL_MODE_BACK_BIT,
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.FALSE,
        .lineWidth = 1.0,
    };

    // Multisample
    const multisample_info = vk.PipelineMultisampleStateCreateInfo{
        .sampleShadingEnable = vk.FALSE,
        .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
    };

    // Depth stencil
    const depth_stencil_info = vk.PipelineDepthStencilStateCreateInfo{
        .depthTestEnable = vk.TRUE,
        .depthWriteEnable = vk.TRUE,
        .depthCompareOp = vk.COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.FALSE,
        .stencilTestEnable = vk.FALSE,
    };

    // Color blend
    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blendEnable = vk.FALSE,
        .srcColorBlendFactor = vk.BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.BLEND_FACTOR_ZERO,
        .colorBlendOp = vk.BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.BLEND_OP_ADD,
        .colorWriteMask = vk.COLOR_COMPONENT_R_BIT | vk.COLOR_COMPONENT_G_BIT | vk.COLOR_COMPONENT_B_BIT | vk.COLOR_COMPONENT_A_BIT,
    };
    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .logicOpEnable = vk.FALSE,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    // Pipeline layout (empty for now)
    const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    const pipeline_layout = try vkd.createPipelineLayout(device, &pipeline_layout_info, null);
    defer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    // Graphics pipeline create info
    const graphics_pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stageCount = 0, // TODO: Add shader stages
        .pStages = null,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly_info,
        .pViewportState = &viewport_state_info,
        .pRasterizationState = &rasterizer_info,
        .pMultisampleState = &multisample_info,
        .pDepthStencilState = &depth_stencil_info,
        .pColorBlendState = &color_blend_info,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = .null_handle,
    };

    const pipeline = try vkd.createGraphicsPipeline(device, .null_handle, &graphics_pipeline_info, null);
    return pipeline;
}

fn updateInstanceBuffer(vkd: *vk.DeviceWrapper, device: vk.Device, command_pool: vk.CommandPool, graphics_queue: vk.Queue, mapped_instance_data: [*]Matrix4x4, entities: *movement.Registry) !void {
    // Update instance buffer with entity transforms
    // This is a simplified implementation - in reality we would:
    // 1. Get transforms from the ECS
    // 2. Update the mapped instance data
    // 3. Ensure proper synchronization
    
    // For now, we'll just zero out the data as a placeholder
    @memset(mapped_instance_data, 0, entities.capacity * @sizeOf(Matrix4x4));
}

test "engine initializes and reports running" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expect(engine.running);
}
