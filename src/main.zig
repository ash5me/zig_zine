const std = @import("std");
const movement = @import("ecs_movement.zig");
const physics = @import("physics_solver.zig");
const sdl = @import("sdl_bindings.zig");
const build_options = @import("build_options");
const vulkan = if (build_options.enable_vulkan) @import("vulkan_swapchain.zig") else struct {};

// TODO: Restore a bounded demo frame count after SDL window/event handling is wired in.
// const max_demo_frames: u32 = 120;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    running: bool,
    entities: movement.Registry,
    physics_world: physics.PhysicsWorld,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        std.log.info("engine: initializing", .{});

        return Engine{
            .allocator = allocator,
            .running = true,
            .entities = movement.Registry.init(),
            .physics_world = physics.PhysicsWorld.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        std.log.info("engine: shutting down", .{});
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

    var last_time = sdl.SDL_GetPerformanceCounter();
    const frequency = @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency()));
    var timestep = physics.FixedTimestep{};
    var frame_count: u32 = 0;
    var fps_timer: f64 = 0.0;
    var total_frames: u32 = 0;

    // Keep the engine alive until the future SDL quit-event path sets running to false.
    while (engine.running) : (total_frames += 1) {
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

        // Audio collision effects and the Vulkan render pass will run here.
    }

    if (build_options.enable_vulkan) {
        _ = vulkan.VulkanSwapchain;
    }

    std.log.info("engine: ran {d} frames with {d} entities", .{ total_frames, engine.entities.count });
}

test "engine initializes and reports running" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expect(engine.running);
}
