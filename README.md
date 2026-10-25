# zig_zine

`zig_zine` is a Zig 0.16 game-engine sandbox. The working code covers a fixed-timestep rigid-body step, two ECS workloads with thousands of entities, CPU-side image decoding, and a Vulkan swapchain with an instanced draw path. The Vulkan path is not yet driven by the main loop.

The target is an asteroid field of at least 10,000 spinning, textured cubes, with physics, ECS scheduling, and frame telemetry running together. The planned engine structure is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Index

- [Current status](#current-status)
- [Project layout](#project-layout)
- [Runtime loop](#runtime-loop)
- [ECS and stress testing](#ecs-and-stress-testing)
- [Physics](#physics)
- [Image decoding](#image-decoding)
- [Vulkan rendering](#vulkan-rendering)
- [Dependencies](#dependencies)
- [Build and test](#build-and-test)
- [Validation layers](#validation-layers)
- [Known issues](#known-issues)

## Current status

- **Implemented and tested:** fixed timestep, rigid-body integration and collision response, both ECS demos, and PNG decoding to RGBA8 through `TextureCache`.
- **Implemented, not run by `main`:** the Vulkan swapchain (`VulkanSwapchain`) and instanced draw recording. These compile only with `-Dvulkan=true`.
- **Designed, not built:** Vulkan validation layers, GPU texture upload, shader and font loading, render pass and pipeline, frame synchronization, cameras, sprites, tilemaps, animation, networking, and audio.

## Project layout

- `src/main.zig`: entry point and `Engine`, the simulation core. `Engine` owns the ECS registry, physics world, fixed timestep, and asset caches. It contains no window or GPU code.
- `src/platform.zig`: `Platform`, which owns the window, event polling, and frame timing. `main` uses `pollQuit()`, `frameDelta()`, `endFrame()`, and the optional `max_frames` limit.
- `src/ecs_movement.zig`: hand-written component registry and the 10,000-entity movement demo.
- `src/ecs_stress_test.zig`: 10,000-entity boundary test built on `zig-ecs`.
- `src/physics_solver.zig`: `Vec3`, rigid bodies, AABB overlap, impulse resolution, and `FixedTimestep`.
- `src/resources.zig`: `TextureCache` (CPU decode through zstbi), plus `FontCache` and `ShaderCache` stubs.
- `src/vulkan_swapchain.zig`: Vulkan instance, device, swapchain, image views, and `drawInstanced`.
- `src/sdl_bindings.zig`: hand-written SDL3 declarations and a small `SDLContext`.
- `src/math/vec.zig`: shared `Vec3` helpers. Not yet used by physics.
- `src/math/axis.zig`: axis mask helpers. Not yet used anywhere.
- `src/cube_data.zig`, `src/vert.glsl`, `src/frag.glsl`: unit-cube mesh data and instanced-cube shaders. No build step compiles the shaders, and no code uploads the mesh yet.

## Runtime loop

`main.zig` currently:

1. Creates a `DebugAllocator` and reports leaks on exit.
2. Initializes `Platform`, then `Engine`. `Platform` is torn down last.
3. Spawns the demo scene: 10,000 movement entities and one falling physics body.
4. Decodes the built-in placeholder PNG as a smoke test of the image path.
5. Each frame, checks for a quit request and the optional frame limit, calls `engine.tick(platform.frameDelta())`, then `platform.endFrame()`.
6. Logs the frame count, entity count, and final height of body 0.

`Engine.tick` runs zero or more physics steps at the fixed 60 Hz rate, up to five per frame. It then moves ECS entities by the variable frame delta. The two clocks are a known issue, listed below.

## ECS and stress testing

The project has two ECS implementations and has not chosen one yet.

- `ecs_movement.Registry` is hand-written. It stores components in fixed arrays of 10,000 entries, which is why `Engine` heap-allocates it (about 320 KB). Entities get `Position`, `Velocity`, and `MeshRenderer`. Movement is a plain loop over the arrays.
- `ecs_stress_test.zig` uses `prime31/zig-ecs`, imported as `ecs`. It spawns 10,000 entities with `Position`, `Velocity`, and `Aabb` in a 100 × 100 × 100 world. It iterates a view, reverses velocity at world boundaries, and runs 600 updates to check that every entity stays inside.

Both demos use seeded pseudo-random generators, so runs are repeatable. The stress test runs as its own artifact under `zig build test`.

## Physics

`physics_solver.zig` provides:

- `@Vector(3, f32)` math. Its `Vec3` duplicates the helpers in `math/vec.zig`.
- Gravity integration for dynamic bodies. Bodies with `mass = 0` are static.
- `FixedTimestep`, a 60 Hz accumulator that returns how many steps to run this frame, capped at five.
- An O(n²) AABB broad phase.
- Impulse resolution on the axis of least penetration, using the lower of the two restitution values, plus percentage-based positional correction (20%, with 0.01 slop).

The broad phase is only suitable for small body counts. A spatial grid or BVH is needed before hundreds of bodies. There is no axis locking, rotation, or friction yet.

## Image decoding

`resources.zig` decodes images with `zig-gamedev/zstbi`, a Zig wrapper over stb_image. It replaced libpng.

`TextureCache` decodes a file (`getOrLoadFile`) or embedded bytes (`getOrLoadMemory`) into 4-channel RGBA. The cache owns the results and caches them by key. Only one cache should exist at a time, because zstbi's allocator is process-wide. Decoding stops at system memory; GPU upload comes later. See [docs/resources.md](docs/resources.md).

## Vulkan rendering

Build with `zig build -Dvulkan=true`. This links SDL3 and the Vulkan loader and compiles `vulkan_swapchain.zig`. The default build links neither.

`VulkanSwapchain.init` creates an instance with the extensions SDL requires, a surface, a physical device with graphics and present queue families, a logical device, a command pool, and a swapchain. It prefers B8G8R8A8 sRGB and mailbox present mode, falling back to FIFO. It creates one image view per swapchain image. `acquire_next_image`, `present`, and `recreate_swapchain` are implemented.

`drawInstanced` copies a slice of transforms into a persistently mapped buffer and records one indexed instanced draw. The graphics pipeline must declare:

- vertex binding 0 for mesh positions,
- vertex binding 1 with per-instance input rate for the instance matrices,
- four `vec4` attributes, one per matrix column.

`Matrix4x4` is `[4][4]f32`. Confirm the column order before writing a matrix builder: GLSL reads `mat4` by column.

Still missing: render pass, graphics pipeline, framebuffers, frame synchronization, per-frame command recording, and shader compilation. Validation layers are planned in [docs/vulkan-validation-layers.md](docs/vulkan-validation-layers.md).

## Dependencies

Pinned in `build.zig.zon`:

- `sdl`: SDL3 (version 3.2.24 per the package string), built through the Zig build graph.
- `vulkan`: `Snektron/vulkan-zig`, `zig-0.16-compat` branch.
- `vulkan_headers`: Khronos Vulkan-Headers, `vulkan-sdk-1.3.296`.
- `entt`: `prime31/zig-ecs`, imported as `ecs`.
- `zstbi`: `zig-gamedev/zstbi`, for image decoding.

Each pin should have a one-line comment explaining why it is pinned to that commit. Those comments are not in place yet (see ARCHITECTURE §8).

## Build and test

Requirements: Zig 0.16.0. For `-Dvulkan=true` on Windows, the Vulkan SDK is also needed for `vulkan-1.lib`.

```sh
zig build                          # engine build, headless
zig build test                     # engine tests and ECS stress tests
zig build run                      # run the demo loop
zig build -Dvulkan=true            # add SDL3 and Vulkan, compile the swapchain
zig build -Dopenal=true            # link OpenAL (no audio code yet)
zig build -Doptimize=ReleaseFast   # optimized build
```

Options:

- `-Dvulkan=<bool>`: compile the optional SDL3 and Vulkan path.
- `-Dopenal=<bool>`: link OpenAL. Nothing calls it yet.
- `-Dvulkan-lib-dir=<path>`: Windows directory containing `vulkan-1.lib`. Defaults to `%VULKAN_SDK%\Lib`.
- `-Dopenal-lib-dir=<path>`: Windows directory containing `OpenAL32.lib`.
- `-Doptimize=<mode>`: the standard Zig option. Debug is the default.

`zig build test` covers the engine module (including physics and resources) and the ECS stress test. It does not cover `vulkan_swapchain.zig` or `sdl_bindings.zig`.

`zig build run` runs until the platform reports a quit request, or until `Platform.max_frames` is reached if that limit is set.

Windows example with an explicit Vulkan library path:

```sh
zig build -Dvulkan=true -Dvulkan-lib-dir="C:\\VulkanSDK\\1.4.357.0\\Lib"
```

Windows example with OpenAL:

```sh
zig build -Dvulkan=true -Dopenal=true -Dopenal-lib-dir="C:\\path\\to\\openal\\lib"
```

## Validation layers

Vulkan validation and the debug messenger are planned but not yet implemented. The design is in [docs/vulkan-validation-layers.md](docs/vulkan-validation-layers.md).

## Known issues

Likely compile blockers in the Vulkan path. These have not been checked against a build with the pinned SDL3 and vulkan-zig versions:

- `vulkan_swapchain.zig`: `getInstanceProcAddress` applies `.?` to `PFN_vkGetInstanceProcAddr`, which is not optional.
- `vulkan_swapchain.zig`: `createInstance` uses the managed `std.ArrayList` API (`initCapacity(allocator, …)`, `deinit()`). The rest of the codebase uses the unmanaged API.
- `vulkan_swapchain.zig`: `acquire_next_image` compares against `.error_out_of_date_khr`. Check that name against vulkan-zig's result mapping.
- `sdl_bindings.zig`: `SDL_Init` and `SDL_PollEvent` are declared as returning `i32`. Check against SDL3's headers, which may use `bool`.

Behavior and design issues:

- **Timestep backlog.** `FixedTimestep.consume` caps steps at five per frame but keeps the excess time, so slow frames are repaid in later frames. The comment in `physics_solver.zig` says excess steps are dropped. Choose one behavior and make the code and comment agree.
- **Two clocks.** Physics runs on the fixed step, while ECS movement runs on the variable frame delta. This conflicts with the determinism plan in ARCHITECTURE §6.3.
- **Registry capacity.** `ecs_movement.Registry.create` has no bounds check. Creating more than 10,000 entities, including calling `spawnDemoScene` twice, writes past the arrays. This panics in Debug builds and is undefined behavior in release builds.
- **Swapchain out-of-date handling.** Because `present` uses `try`, an out-of-date result is returned as an error and never reaches `recreate_swapchain`. Verify the behavior against vulkan-zig before changing it.
- **Swapchain teardown.** `VulkanSwapchain.deinit` does not call `deviceWaitIdle` before destroying resources. `recreate_swapchain` recreates the command pool unnecessarily and is not safe if it fails partway through.
- **Instance capacity.** `drawInstanced` checks the transform count against the constant `max_instance_count`, not against the capacity of the mapped buffer.
- **SDL3 event size.** `SDL_Event` is declared as 56 bytes. SDL3's event union may be larger, so check `SDL_events.h`.
- **macOS link.** `build.zig` links the OpenAL framework on macOS even without `-Dopenal=true`.
- **Naming.** `acquire_next_image` and `recreate_swapchain` are snake_case. ARCHITECTURE §7 specifies camelCase for functions.
- **Unused code.** `cube_data.zig`, `math/axis.zig`, and the `main` function in `ecs_movement.zig` are not referenced. That `main` never compiles, because `main.zig` is the root.
- **Stale comment.** `ecs_movement.zig` refers to "the previous step" and describes a `reg.view` call that does not exist.
