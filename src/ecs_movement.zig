const std = @import("std");

pub const Position = struct { x: f32, y: f32, z: f32 };
pub const Velocity = struct { x: f32, y: f32, z: f32 };
pub const MeshRenderer = struct {
    mesh_id: u32,
    visible: bool = true,
};

pub const entity_count: usize = 10_000;

pub const Registry = struct {
    positions: [entity_count]Position = undefined,
    velocities: [entity_count]Velocity = undefined,
    mesh_renderers: [entity_count]MeshRenderer = undefined,
    count: usize = 0,

    pub fn init() Registry {
        return .{};
    }

    pub fn create(self: *Registry) usize {
        const entity = self.count;
        self.count += 1;
        return entity;
    }

    pub fn add(self: *Registry, entity: usize, component: anytype) void {
        switch (@TypeOf(component)) {
            Position => self.positions[entity] = component,
            Velocity => self.velocities[entity] = component,
            MeshRenderer => self.mesh_renderers[entity] = component,
            else => @compileError("unsupported ECS component"),
        }
    }
};

/// Spawns entity_count entities, each with Position, Velocity and
/// MeshRenderer. MeshRenderer isn't touched by updateMovement() below —
/// it's read by the render system (see vulkan_swapchain.zig from the
/// previous step), not the movement system. Velocities get a small
/// pseudo-random spread so there's visible motion to iterate over.
pub fn spawnEntities(reg: *Registry) void {
    var prng = std.Random.DefaultPrng.init(0); // std.rand on older Zig versions
    const random = prng.random();

    var i: usize = 0;
    while (i < entity_count) : (i += 1) {
        const entity = reg.create();
        reg.add(entity, Position{ .x = 0, .y = 0, .z = 0 });
        reg.add(entity, Velocity{
            .x = random.float(f32) * 2.0 - 1.0,
            .y = random.float(f32) * 2.0 - 1.0,
            .z = 0,
        });
        reg.add(entity, MeshRenderer{ .mesh_id = @intCast(i % 16) });
    }
}

/// The movement system — this is the "2. Update ECS systems" slot in
/// the engine's tick order. reg.view(.{Position, Velocity}, .{}) is a
/// type resolved entirely at comptime against those two component
/// types, so entityIterator()/get()/getConst() below carry no runtime
/// type dispatch, only the underlying sparse-set lookups.
pub fn updateMovement(reg: *Registry, delta_time: f32) void {
    for (0..reg.count) |entity| {
        const vel = reg.velocities[entity];
        reg.positions[entity].x += vel.x * delta_time;
        reg.positions[entity].y += vel.y * delta_time;
        reg.positions[entity].z += vel.z * delta_time;
    }
}

test "spawn and move 10,000 entities" {
    var reg = Registry.init();

    spawnEntities(&reg);

    try std.testing.expectEqual(entity_count, reg.count);

    updateMovement(&reg, 1.0 / 60.0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    _ = allocator;
    var reg = Registry.init();

    spawnEntities(&reg);

    var timer = try std.time.Timer.start();
    var frame: usize = 0;
    while (frame < 60) : (frame += 1) {
        const dt_ns = timer.lap();
        const delta_time: f32 = @as(f32, @floatFromInt(dt_ns)) / std.time.ns_per_s;
        updateMovement(&reg, delta_time);
    }

    std.log.info("moved {d} entities for {d} frames", .{ entity_count, frame });
}
