const std = @import("std");
const movement = @import("ecs_movement.zig");
const physics = @import("physics_solver.zig");
const resources = @import("resources.zig");
const platform_mod = @import("platform.zig");

/// The simulation core: ECS, physics and asset caches. Deliberately knows
/// nothing about windows or GPUs — those live behind `Platform`, so this
/// struct can be created and ticked in tests and on machines without a display.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    running: bool = true,
    /// Heap-allocated: Registry holds ~320 KB of component arrays, too much to
    /// keep copying by value through init()/return (default Windows stacks
    /// are 1 MB).
    entities: *movement.Registry,
    physics_world: physics.PhysicsWorld,
    timestep: physics.FixedTimestep = .{},
    texture_cache: resources.TextureCache,
    font_cache: resources.FontCache,
    shader_cache: resources.ShaderCache,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        std.log.info("engine: initializing", .{});

        const entities = try allocator.create(movement.Registry);
        entities.* = movement.Registry.init();

        return .{
            .allocator = allocator,
            .entities = entities,
            .physics_world = physics.PhysicsWorld.init(allocator),
            .texture_cache = resources.TextureCache.init(allocator),
            .font_cache = resources.FontCache.init(allocator),
            .shader_cache = resources.ShaderCache.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        std.log.info("engine: shutting down", .{});
        self.shader_cache.deinit();
        self.font_cache.deinit();
        self.texture_cache.deinit();
        self.physics_world.deinit();
        self.allocator.destroy(self.entities);
    }

    /// The demo scene from the original main(): 10,000 moving entities plus
    /// one falling physics body. Call at most once per Engine.
    pub fn spawnDemoScene(self: *Engine) !void {
        movement.spawnEntities(self.entities);
        _ = try self.physics_world.addBody(.{
            .position = .{ 0, 10, 0 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
        });
    }

    /// Advances the simulation by one rendered frame: fixed-timestep physics
    /// (0..N steps depending on how much time has accumulated), then ECS
    /// movement with the variable frame delta.
    pub fn tick(self: *Engine, delta_time: f32) void {
        const steps = self.timestep.consume(delta_time);
        for (0..steps) |_| self.physics_world.step(self.timestep.fixed_dt);
        movement.updateMovement(self.entities, delta_time);
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) std.debug.print("MEMORY LEAK DETECTED!\n", .{});
    }
    const allocator = debug_allocator.allocator();

    // Declared first so it is destroyed last (defers run in reverse order).
    var platform = try platform_mod.Platform.init(allocator);
    defer platform.deinit();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    try engine.spawnDemoScene();

    // Smoke-test the PNG path (zstbi) end to end on every run.
    const placeholder = try engine.texture_cache.getOrLoadMemory(
        "builtin:placeholder",
        &resources.placeholder_png,
    );
    std.log.info("engine: decoded placeholder texture {d}x{d} ({d} channels)", .{
        placeholder.width(),
        placeholder.height(),
        placeholder.image.num_components,
    });

    var frame: u64 = 0;
    while (engine.running) : (frame += 1) {
        if (platform.pollQuit()) break;
        if (platform_mod.Platform.max_frames) |limit| {
            if (frame >= limit) break;
        }

        engine.tick(platform.frameDelta());
        try platform.endFrame();
    }

    std.log.info("engine: ran {d} frames with {d} entities; body 0 ended at y = {d:.3}", .{
        frame,
        engine.entities.count,
        engine.physics_world.bodies.items[0].position[1],
    });
}

// `zig test` only runs test blocks in files it is told to resolve, so pull in
// the other modules' tests explicitly.
test {
    _ = movement;
    _ = physics;
    _ = resources;
}

test "engine initializes headlessly and reports running" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expect(engine.running);
    try std.testing.expectEqual(@as(usize, 0), engine.entities.count);
}

test "tick advances physics and ECS movement" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.spawnDemoScene();

    try std.testing.expectEqual(movement.entity_count, engine.entities.count);

    const start_y = engine.physics_world.bodies.items[0].position[1];
    for (0..60) |_| engine.tick(1.0 / 60.0);

    // One second of gravity: the body must have fallen.
    try std.testing.expect(engine.physics_world.bodies.items[0].position[1] < start_y);

    // Every entity started at the origin; some must have moved away.
    var moved = false;
    for (0..engine.entities.count) |i| {
        if (engine.entities.positions[i].x != 0) moved = true;
    }
    try std.testing.expect(moved);
}
