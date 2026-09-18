# zig_zine

`zig_zine` is a Zig 0.16 game-engine sandbox centered on an asteroid-field
workload: thousands of moving entities, fixed-timestep collision handling,
SDL frame diagnostics, and a Vulkan instanced-rendering path.

## Index

- [Engine overview](#engine-overview)
- [Runtime loop](#runtime-loop)
- [ECS and stress testing](#ecs-and-stress-testing)
- [Physics](#physics)
- [Vulkan rendering](#vulkan-rendering)
- [Dependencies](#dependencies)
- [Build and test](#build-and-test)
- [Validation layers](#validation-layers)
- [Current limitations](#current-limitations)

## Engine overview

The engine is split into small systems that can be replaced as the sandbox
grows:

- `src/main.zig`: engine lifecycle, allocator diagnostics, timing, and system loop.
- `src/ecs_movement.zig`: local movement registry and the 10,000-entity movement demo.
- `src/ecs_stress_test.zig`: `zig-ecs` setup with Position, Velocity, and Aabb components.
- `src/physics_solver.zig`: SIMD `Vec3` math, rigid bodies, AABB overlap tests, impulses, and fixed time.
- `src/vulkan_swapchain.zig`: Vulkan instance, device, swapchain, image views, and instanced draw recording.
- `src/sdl_bindings.zig`: small local SDL3 ABI surface used for timing and Vulkan interop.

The intended long-term scenario is an asteroid field containing at least 10,000
spinning, textured cubes, with physics, audio, ECS scheduling, and frame/memory
telemetry running together.

## Runtime loop

`main.zig` currently:

1. Creates a Zig 0.16 `DebugAllocator` and reports leaks.
2. Creates the engine and spawns 10,000 movement entities.
3. Adds a dynamic physics body.
4. Samples SDL performance counters for high-resolution frame timing.
5. Runs fixed-timestep physics followed by ECS movement updates.
6. Logs FPS and average frame time once per second.

The temporary frame cap is commented out. The loop currently runs while
`engine.running` is true; SDL quit-event handling is the future mechanism that
will set it to false. A window/event system is not yet initialized by `main`.

## ECS and stress testing

The dedicated stress module uses the pinned `prime31/zig-ecs` package, exposed
to the source as `ecs`:

- 10,000 entities are created inside a 100 x 100 x 100 world.
- Each entity receives distinct `Position`, `Velocity`, and `Aabb` components.
- Velocities are deterministic pseudo-random values in all three axes.
- `updatePositions()` iterates an ECS view and clamps AABBs to world boundaries.
- Velocity is reversed when an entity reaches a boundary.
- Tests run 600 fixed updates and verify every entity remains inside the box.

The stress tests are included in `zig build test`.

## Physics

`physics_solver.zig` provides:

- `@Vector(3, f32)` SIMD vector operations.
- Gravity integration for dynamic bodies.
- Static bodies represented by `mass = 0`.
- A fixed 60 Hz timestep with an accumulator and five-step frame clamp.
- O(n^2) AABB broad-phase collision checks.
- Least-penetration-axis impulse resolution and positional correction.

The broad phase is intentionally small-scale and ad hoc. A spatial grid or BVH
will be needed before hundreds or thousands of rigid bodies are simulated.

## Vulkan rendering

The renderer uses `vulkan-zig` dispatch tables and SDL3 surface integration.
`VulkanSwapchain.drawInstanced()` accepts ECS transform matrices and:

- Copies transforms into a persistently mapped instance buffer.
- Binds one mesh vertex buffer at binding 0.
- Binds one instance buffer at binding 1.
- Binds a `uint32` index buffer.
- Issues one `cmdDrawIndexed` call for all instances.

The graphics pipeline must declare binding 1 with instance input rate and expose
the four `vec4` columns of `Matrix4x4` as vertex attributes.

Enable the Vulkan build with:

```sh
zig build -Dvulkan=true
```

On Windows, the build uses `VULKAN_SDK\Lib` for `vulkan-1.lib`. An explicit
path can be supplied when needed:

```sh
zig build -Dvulkan=true -Dvulkan-lib-dir="C:\\VulkanSDK\\1.4.357.0\\Lib"
```

## Dependencies

Dependencies are pinned in `build.zig.zon`:

- `sdl`: SDL3 built as a dynamic library through the Zig build graph.
- `vulkan`: Zig 0.16-compatible `vulkan-zig` binding generation.
- `vulkan_headers`: Vulkan XML registry used to generate bindings.
- `entt`: `prime31/zig-ecs`, imported as `ecs`.

OpenAL linking is optional because the engine does not yet contain an audio
system:

```sh
zig build -Dvulkan=true -Dopenal=true -Dopenal-lib-dir="C:\\path\\to\\openal\\lib"
```

## Build and test

Requirements:

- Zig `0.16.0`.
- SDL3 build dependencies resolved through `build.zig.zon`.
- Vulkan SDK and `vulkan-1.lib` for the Vulkan-enabled Windows build.

Commands:

```sh
zig build
zig build test
zig build run
```

`zig build run` starts the unbounded engine loop until the future SDL quit-event
path changes `engine.running` to false.

## Validation layers

Debug-only Vulkan validation layer and Debug Utils Messenger setup is documented
separately in [docs/vulkan-validation-layers.md](docs/vulkan-validation-layers.md).

## Current limitations

- No SDL window creation or event polling is wired into `main` yet.
- Audio collision effects and OpenAL device management are not implemented.
- The Vulkan swapchain is implemented, but a complete render pass, graphics
	pipeline, synchronization, and presentation loop are still pending.
- The instanced draw API expects buffers and mapped memory to be created by a
	higher-level renderer.
- The physics broad phase is O(n^2) and intended for the current sandbox scale.