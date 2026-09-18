const std = @import("std");

/// Zig's SIMD vector builtin — the closest thing the standard library
/// has to a "vector type". Elementwise +, -, *, and indexing with
/// v[0]/v[1]/v[2] all work natively on @Vector, no hand-rolled struct
/// math needed.
pub const Vec3 = @Vector(3, f32);

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return a + b;
}
pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return a - b;
}
pub fn scale(a: Vec3, s: f32) Vec3 {
    return a * @as(Vec3, @splat(s));
}
pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}
pub fn zero() Vec3 {
    return @splat(0);
}

pub const gravity: Vec3 = Vec3{ 0, -9.81, 0 };

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn fromCenterHalfExtents(center: Vec3, half_extents: Vec3) Aabb {
        return .{ .min = center - half_extents, .max = center + half_extents };
    }

    pub fn overlaps(a: Aabb, b: Aabb) bool {
        return a.min[0] <= b.max[0] and a.max[0] >= b.min[0] and
            a.min[1] <= b.max[1] and a.max[1] >= b.min[1] and
            a.min[2] <= b.max[2] and a.max[2] >= b.min[2];
    }
};

pub const RigidBody = struct {
    position: Vec3,
    velocity: Vec3 = zero(),
    half_extents: Vec3,
    mass: f32 = 1.0,
    restitution: f32 = 0.5,

    /// mass <= 0 means static / infinite mass — invMass 0 so impulses
    /// and position correction never move it.
    pub fn invMass(self: RigidBody) f32 {
        return if (self.mass > 0) 1.0 / self.mass else 0.0;
    }

    pub fn aabb(self: RigidBody) Aabb {
        return Aabb.fromCenterHalfExtents(self.position, self.half_extents);
    }
};

/// Feed a variable frame delta_time in; consume() returns how many
/// fixed 60 Hz steps to run this frame, carrying remainder forward in
/// accumulator. max_steps_per_frame clamps the "spiral of death" if a
/// frame stalls badly — steps are dropped, not queued up forever.
pub const FixedTimestep = struct {
    accumulator: f32 = 0,
    fixed_dt: f32 = 1.0 / 60.0,
    max_steps_per_frame: u32 = 5,

    pub fn consume(self: *FixedTimestep, delta_time: f32) u32 {
        self.accumulator += delta_time;
        var steps: u32 = 0;
        const epsilon: f32 = 0.000001;
        while (self.accumulator + epsilon >= self.fixed_dt and steps < self.max_steps_per_frame) {
            self.accumulator -= self.fixed_dt;
            steps += 1;
        }
        return steps;
    }
};

pub const PhysicsWorld = struct {
    allocator: std.mem.Allocator,
    bodies: std.ArrayList(RigidBody),

    pub fn init(allocator: std.mem.Allocator) PhysicsWorld {
        return .{ .allocator = allocator, .bodies = .empty };
    }

    pub fn deinit(self: *PhysicsWorld) void {
        self.bodies.deinit(self.allocator);
    }

    pub fn addBody(self: *PhysicsWorld, body: RigidBody) !usize {
        try self.bodies.append(self.allocator, body);
        return self.bodies.items.len - 1;
    }

    /// One fixed step: integrate velocity from force (linear momentum —
    /// v += (F/m)*dt, here just gravity on non-static bodies), then
    /// integrate position from velocity, then an O(n^2) AABB broad-phase
    /// feeding impulse resolution on every overlapping pair. Fine for a
    /// small ad-hoc body count; swap in a grid or BVH before this gets
    /// into the hundreds.
    pub fn step(self: *PhysicsWorld, dt: f32) void {
        for (self.bodies.items) |*body| {
            if (body.invMass() > 0) {
                body.velocity = add(body.velocity, scale(gravity, dt));
            }
            body.position = add(body.position, scale(body.velocity, dt));
        }

        var i: usize = 0;
        while (i < self.bodies.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < self.bodies.items.len) : (j += 1) {
                const a_box = self.bodies.items[i].aabb();
                const b_box = self.bodies.items[j].aabb();
                if (Aabb.overlaps(a_box, b_box)) {
                    resolveCollision(&self.bodies.items[i], &self.bodies.items[j], a_box, b_box);
                }
            }
        }
    }
};

/// Resolves one overlapping AABB pair: pick the axis of least
/// penetration as the contact normal (the "ad-hoc" approximation — a
/// real solver would compute a proper contact manifold), apply a
/// linear-momentum impulse along it, then push the bodies apart enough
/// to stop them sinking into each other over repeated frames.
fn resolveCollision(a: *RigidBody, b: *RigidBody, a_box: Aabb, b_box: Aabb) void {
    const inv_mass_a = a.invMass();
    const inv_mass_b = b.invMass();
    const inv_mass_sum = inv_mass_a + inv_mass_b;
    if (inv_mass_sum == 0) return; // both static, nothing to resolve

    const overlap_x = @min(a_box.max[0], b_box.max[0]) - @max(a_box.min[0], b_box.min[0]);
    const overlap_y = @min(a_box.max[1], b_box.max[1]) - @max(a_box.min[1], b_box.min[1]);
    const overlap_z = @min(a_box.max[2], b_box.max[2]) - @max(a_box.min[2], b_box.min[2]);

    // Normal points from B toward A on whichever axis is shallowest.
    var penetration = overlap_x;
    var normal: Vec3 = .{ if (a.position[0] < b.position[0]) -1 else 1, 0, 0 };

    if (overlap_y < penetration) {
        penetration = overlap_y;
        normal = .{ 0, if (a.position[1] < b.position[1]) -1 else 1, 0 };
    }
    if (overlap_z < penetration) {
        penetration = overlap_z;
        normal = .{ 0, 0, if (a.position[2] < b.position[2]) -1 else 1 };
    }

    const rel_vel = sub(a.velocity, b.velocity);
    const vel_along_normal = dot(rel_vel, normal);
    if (vel_along_normal > 0) return; // already separating, nothing to do

    const restitution = @min(a.restitution, b.restitution);
    const j = -(1.0 + restitution) * vel_along_normal / inv_mass_sum;
    const impulse = scale(normal, j);

    a.velocity = add(a.velocity, scale(impulse, inv_mass_a));
    b.velocity = sub(b.velocity, scale(impulse, inv_mass_b));

    // Percentage-based positional correction, not full Baumgarte
    // stabilization — enough to stop visible sinking, nothing fancier.
    const correction_percent: f32 = 0.2;
    const slop: f32 = 0.01;
    const correction_mag = @max(penetration - slop, 0.0) / inv_mass_sum * correction_percent;
    const correction = scale(normal, correction_mag);
    a.position = add(a.position, scale(correction, inv_mass_a));
    b.position = sub(b.position, scale(correction, inv_mass_b));
}

test "fixed timestep accumulates and clamps" {
    var ts = FixedTimestep{};
    const steps = ts.consume(3.0 / 60.0); // ~3 fixed steps worth
    try std.testing.expectEqual(@as(u32, 3), steps);
    try std.testing.expect(ts.accumulator < ts.fixed_dt);
}

test "falling body integrates under gravity" {
    var world = PhysicsWorld.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.addBody(.{ .position = .{ 0, 10, 0 }, .half_extents = .{ 0.5, 0.5, 0.5 } });
    world.step(1.0 / 60.0);

    try std.testing.expect(world.bodies.items[0].velocity[1] < 0);
    try std.testing.expect(world.bodies.items[0].position[1] < 10);
}

test "dynamic body bounces off a static floor" {
    var world = PhysicsWorld.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.addBody(.{ // static floor
        .position = .{ 0, -0.5, 0 },
        .half_extents = .{ 5, 0.5, 5 },
        .mass = 0,
    });
    const dynamic_idx = try world.addBody(.{
        .position = .{ 0, 0.4, 0 },
        .velocity = .{ 0, -1, 0 },
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .restitution = 0.5,
    });

    world.step(1.0 / 60.0);

    // Floor never moves.
    try std.testing.expectEqual(@as(f32, -0.5), world.bodies.items[0].position[1]);
    // Dynamic body's downward velocity should have been reversed by the impulse.
    try std.testing.expect(world.bodies.items[dynamic_idx].velocity[1] > 0);
}
