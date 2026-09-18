const std = @import("std");
const ecs = @import("ecs");

pub const entity_count: usize = 10_000;
pub const world_size: f32 = 100.0;

pub const Position = struct {
    values: [3]f32,
};
pub const Velocity = struct {
    values: [3]f32,
};
pub const Aabb = struct {
    half_extents: [3]f32,
};

pub const WorldBounds = struct {
    min: [3]f32 = .{ 0, 0, 0 },
    max: [3]f32 = .{ world_size, world_size, world_size },
};

pub fn spawnEntities(registry: *ecs.Registry) void {
    var prng = std.Random.DefaultPrng.init(0xA57E_2026);
    const random = prng.random();

    for (0..entity_count) |_| {
        const entity = registry.create();
        registry.add(entity, Position{ .values = .{
            random.float(f32) * world_size,
            random.float(f32) * world_size,
            random.float(f32) * world_size,
        } });
        registry.add(entity, Velocity{ .values = .{
            random.float(f32) * 2.0 - 1.0,
            random.float(f32) * 2.0 - 1.0,
            random.float(f32) * 2.0 - 1.0,
        } });
        registry.add(entity, Aabb{ .half_extents = .{ 0.25, 0.25, 0.25 } });
    }
}

pub fn updatePositions(registry: *ecs.Registry, delta_time: f32, bounds: WorldBounds) void {
    var view = registry.view(.{ Position, Velocity, Aabb }, .{});
    var iterator = view.entityIterator();

    while (iterator.next()) |entity| {
        const position = view.get(Position, entity);
        const velocity = view.get(Velocity, entity);
        const aabb = view.getConst(Aabb, entity);

        inline for (0..3) |axis| {
            position.values[axis] += velocity.values[axis] * delta_time;

            const min_position = bounds.min[axis] + aabb.half_extents[axis];
            const max_position = bounds.max[axis] - aabb.half_extents[axis];

            if (position.values[axis] < min_position) {
                position.values[axis] = min_position;
                if (velocity.values[axis] < 0) velocity.values[axis] = -velocity.values[axis];
            } else if (position.values[axis] > max_position) {
                position.values[axis] = max_position;
                if (velocity.values[axis] > 0) velocity.values[axis] = -velocity.values[axis];
            }
        }
    }
}

test "10,000 ECS entities stay inside 100 cubed bounds" {
    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    spawnEntities(&registry);
    try std.testing.expectEqual(entity_count, registry.view(.{Position}, .{}).len());

    const bounds = WorldBounds{};
    for (0..600) |_| updatePositions(&registry, 1.0 / 60.0, bounds);

    var view = registry.view(.{ Position, Velocity, Aabb }, .{});
    var iterator = view.entityIterator();
    var count: usize = 0;
    while (iterator.next()) |entity| {
        const position = view.getConst(Position, entity);
        const aabb = view.getConst(Aabb, entity);
        inline for (0..3) |axis| {
            try std.testing.expect(position.values[axis] >= bounds.min[axis] + aabb.half_extents[axis]);
            try std.testing.expect(position.values[axis] <= bounds.max[axis] - aabb.half_extents[axis]);
        }
        count += 1;
    }
    try std.testing.expectEqual(entity_count, count);
}

test "boundary collision reverses velocity" {
    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const entity = registry.create();
    registry.add(entity, Position{ .values = .{ 0.5, 50, 50 } });
    registry.add(entity, Velocity{ .values = .{ -2, 0, 0 } });
    registry.add(entity, Aabb{ .half_extents = .{ 0.5, 0.5, 0.5 } });

    updatePositions(&registry, 1.0, WorldBounds{});

    const velocity = registry.getConst(Velocity, entity);
    const position = registry.getConst(Position, entity);
    try std.testing.expectEqual(@as(f32, 2), velocity.values[0]);
    try std.testing.expectEqual(@as(f32, 0.5), position.values[0]);
}
