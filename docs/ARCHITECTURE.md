# ARCHITECTURE.md — Engine Design & Implementation Plan

**Status:** Living plan, partly implemented. This file is the source of truth for *why* the engine is built the way it is. Each section states what exists in the code today. Anything not marked as existing is planned. When a decision here turns out to be wrong, update this file in the same change that fixes the code, so the document never drifts from the codebase. Last reconciled with the codebase on 2026-10-25.

**Working project name:** `zig_zine` (unchanged; rename is a non-architectural decision for later).

**Audience for this document:** a human collaborator *and* an AI coding assistant picking up work in a fresh session with no memory of prior discussion. Every section should be self-contained enough that "implement module X" can be handed to an AI agent along with just that module's spec and produce code consistent with the rest of the engine.

**Current state at a glance.** The headless simulation core exists: fixed timestep, physics with AABB collisions, two ECS demos, and CPU-side PNG decoding. A Vulkan swapchain with instanced draw recording exists behind `-Dvulkan=true`, but `main.zig` does not drive it yet. Nothing from the top-down, side-plane, diorama, networking, tilemap, animation, or audio plans has been started.

---

## 1. Purpose & Design Philosophy

### 1.1 North star

A single engine, sharing one core (ECS, transform model, physics, fixed-timestep loop), that comfortably serves three distinct camera/gameplay archetypes — **top-down**, **side-plane**, and **diorama (HD-2D)** — without forking into "the 2D engine" and "the 3D engine" internally. 2D vs. 3D is never a global mode switch; it is a property of individual cameras and individual entities. A single game may legitimately mix sprite entities and mesh entities in the same scene (this is, in fact, exactly what the diorama archetype requires).

### 1.2 Reference games (why these archetypes, not others)

| Game | Archetype | Why it's in this list |
|---|---|---|
| Stardew Valley | Top-down | Tile-based world, Y-sorted sprites, jump/height as visual offset only |
| Pokémon (2D-era) | Top-down | Same as above, grid-locked movement |
| Zelda-likes (2D) | Top-down | Same, plus room/screen transitions |
| Cult of the Lamb | Top-down | Same, plus base-building on a grid |
| Don't Starve Together | Top-down | Same, plus **online co-op** — drives determinism requirements |
| Octopath Traveler | Diorama (HD-2D) | Real 3D environment + lighting, 2D billboarded sprite characters depth-tested against 3D geometry |
| Rivals of Aether 2 | Side-plane | Real 3D character rigs, camera locks gameplay to a plane — **fighting game, needs rollback netcode** |
| Rocket League Sideswipe | Side-plane | Real 3D ball/vehicle physics, camera locks gameplay to a plane — **online multiplayer** |

### 1.3 Core principles

1. **Modularity over convenience defaults.** Every subsystem beyond the absolute core (math, ECS, fixed-timestep loop, transform) is opt-in. A game dev who only wants top-down tile gameplay should not pay compile time, binary size, or conceptual overhead for hitbox/hurtbox systems or diorama compositing they never enabled.
2. **API-level multiplayer, not framework-level.** The engine does not ship "the" networking solution. It ships a small, stable **NetBackend interface** plus a few reference implementations (lockstep, rollback, server-authoritative) that a game dev can use as-is, swap out, or ignore entirely and write their own against the same interface. The engine's job is to make the *core simulation deterministic-capable* (see §6), not to dictate a networking architecture.
3. **Determinism is a property games opt into, not a permanent constraint on the core.** The physics/ECS tick is written so that it *can* be made deterministic (fixed-point-friendly math paths, no hidden iteration-order-dependent state, no wall-clock reads inside the sim step), but a single-player game that doesn't care pays no extra complexity tax for this.
4. **One Transform, one physics core, three cameras.** See §4 and §5.6. This is the load-bearing decision that keeps the three archetypes from becoming three engines. *Status: the shared Transform does not exist yet; see §4.1.*
5. **Build-flag isolation for real dependencies.** Anything that would block testing or compilation without its platform libraries (SDL3, Vulkan, OpenAL) is excluded from the default build by a `-D` flag, so the simulation core builds and tests headlessly. *Status: this is in place for SDL3, Vulkan, and OpenAL. There are no formal stub backends yet; the only stubs are `FontCache` and `ShaderCache` in `resources.zig`, which return "not implemented" errors. Extend the pattern to networking and asset I/O as those are built.*
6. **Boring, explicit Zig.** Comptime and vtables are used only at genuine extension points (see §7). Everywhere else: plain functions, plain structs, explicit allocators.

---

## 2. Layered Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Game code (the dev's actual game)                            │
├─────────────────────────────────────────────────────────────┤
│  Archetype-support modules (opt-in, pick what you need)       │
│    tilemap/      animation/      hitbox/      diorama/        │
├─────────────────────────────────────────────────────────────┤
│  Subsystems (opt-in via build flags, stub backend by default) │
│    render/   physics/   audio/   net/                         │
├─────────────────────────────────────────────────────────────┤
│  ECS (component storage, views, systems as plain functions)   │
├─────────────────────────────────────────────────────────────┤
│  Core (fixed-timestep loop, Transform, math, engine lifecycle)│
└─────────────────────────────────────────────────────────────┘
```

Rule: a layer may depend only on layers below it. `render/` never imports `tilemap/`. `tilemap/` never imports `hitbox/`. This is enforced by convention and code review, not by the compiler — worth a lint/CI check once the module count grows.

*Status: the layering is followed informally. `main.zig` currently imports the ECS, physics, resources, and platform modules directly. There is no `core/` or `render/` directory yet.*

---

## 3. Directory Layout

The target layout is below. The `TODAY:` notes give the files that exist now. The current working rule is that existing flat files move into these directories when their module is next changed, not in a separate move.

```
src/
  math/              Vec2, Vec3, Vec4, Quat, Mat4 — shared, dimension-agnostic
                     TODAY: math/vec.zig (Vec3 only), math/axis.zig (unused)
  core/              Engine struct, fixed-timestep accumulator, tick order, Transform
                     TODAY: Engine in main.zig, FixedTimestep in physics_solver.zig,
                     Platform in platform.zig. No Transform type.
  ecs/               Registry wrapper, component conventions, standard components
                     TODAY: not created. Two registries exist as flat files (see §5.3).
  physics/           Rigid bodies, AABB broad-phase, impulse resolution, axis-locking
                     TODAY: physics_solver.zig (flat). No axis locking.
  render/
    gpu/             Vulkan instance/device/swapchain — the shared GPU core
                     TODAY: vulkan_swapchain.zig (flat), not yet driven by main
    sprite/          Sprite batching, billboarding, Y-sort — not started
    mesh/            Mesh loading, instanced mesh draw
                     TODAY: drawInstanced in vulkan_swapchain.zig; no pipeline yet
    camera/          TopDownCamera, SidePlaneCamera, DioramaCamera — not started
    diorama/         Depth-compositing sprites into a 3D scene — not started
  tilemap/           Tile grid, tile collision, chunked loading — not started
  animation/         Spritesheet playback, state-driven animation — not started
  hitbox/            Hitbox/hurtbox definitions, animation-linked active-frame queries — not started
  audio/             OpenAL backend + stub — not started; -Dopenal links the library only
  net/
    core/            NetBackend interface, input-command abstraction, snapshot format — not started
    lockstep/        Reference implementation: deterministic lockstep — not started
    rollback/        Reference implementation: rollback netcode — not started
    server_auth/     Reference implementation: server-authoritative — not started
  assets/            Texture/mesh/audio-clip loading and caching
                     TODAY: resources.zig (TextureCache, font and shader stubs)
docs/
  ARCHITECTURE.md                 This file
  vulkan-validation-layers.md     Planned Debug validation setup
  resources.md                    CPU-side asset caches
  <subsystem>.md                  One short "why" doc per subsystem
```

---

## 4. Core Data Model

### 4.1 Transform (unified, not archetype-specific)

*Status: not implemented. Entities currently store position in separate types: `ecs_movement.Position` (x/y/z fields), `ecs_stress_test.Position` (a `[3]f32` array), and `RigidBody.position` (a `Vec3`). Rotation and scale do not exist anywhere yet.*

Every entity that exists in space uses the **same** Transform shape: `position: Vec3`, `rotation: Quat`, `scale: Vec3`. A 2D top-down entity simply leaves Z and non-Z rotation at their defaults. This is what lets physics, rendering, and any future scene-graph/parenting code be written exactly once and used by all three archetypes.

To keep 2D game code ergonomic despite the 3D-shaped storage, provide small convenience constructors — e.g. a function that takes `(x, y, rotation_degrees, scale: Vec2)` and returns a full `Transform` — so top-down/side-plane game code never has to construct a quaternion by hand. These are thin helpers, not a parallel data type.

### 4.2 Coordinate system

*Status: not yet relevant to code. The current shaders apply the instance matrix directly and do no Y flip.*

- **Y-up, right-handed**, consistent across all three archetypes.
- Sprite/top-down rendering performs the "Y increases downward on screen" flip internally, at the point where world space maps to screen space. This keeps the shared math archetype-agnostic while still matching what 2D developers expect to see.

### 4.3 Depth-sort key (distinct from Z)

*Status: not implemented.*

Top-down rendering order is **not** simply "sort by Z". A jumping character's visual height offset must not change its draw-order relative to nearby tiles. So:

- `Transform.position` — actual simulated position (used by physics, used for gameplay logic).
- A separate, computed **sort key** — typically derived from the entity's world-space "anchor" (feet position), *not* including any jump/height visual offset — is what the sprite renderer actually sorts by.
- Height offset (jump arc, thrown-object arc) is applied **only** as a rendering-time translation, after the sort key is computed, never fed back into the sort key itself.

This separation is the single trickiest part of top-down 2.5D rendering and is called out explicitly so it's designed on purpose rather than discovered as a bug later.

### 4.4 Axis-locking physics model

*Status: not implemented in the solver. `RigidBody` has no axis lock field. `math/axis.zig` contains an `AxisMask` struct of three bools with `toVec3` and `invertedVec3` helpers. That is a different shape from the enum sketched below, and it is unused. The choice is recorded in §10.*

The physics core (already built) operates on full `Vec3` positions/velocities/AABBs — this doesn't change. What's added is a per-body **axis lock** concept:

- Top-down archetype: bodies typically lock nothing in the *transform* sense (height still simulates for jump arcs), but collision resolution for top-down gameplay generally treats X/Y as the "gameplay plane" and Z (height) as visual-only, not collidable, unless the game explicitly opts into height-based collision (e.g., jumping over a pit).
- Side-plane archetype: locks depth (whichever axis is perpendicular to the visible plane) so a Rivals-of-Aether-style character can't drift off the fighting plane, while X/Y (or X/Z, depending on plane orientation) simulate fully in 3D.
- Diorama archetype: no locking — full 3D simulation, sprites are billboarded visual representations of fully-3D-simulated entities.

The exact lock is a small per-body configuration (which axis, if any, is constrained), not a different solver. One solver, configurable per body — this is a generalization of the Z-locking idea from the original 2D-vs-3D plan, now applied per-archetype instead of globally.

---

## 5. Module Specifications

Each module below is written so it can be handed, on its own, to a coding session as a self-contained spec. "Public surface" describes responsibilities and shape, not literal code. The **Status** line for each module says what exists today.

### 5.1 `math/`

- **Status:** Partial. `math/vec.zig` defines `Vec3` (`@Vector(3, f32)`) with `add`, `sub`, `scale`, `dot`, `zero`, and `gravity`. `physics_solver.zig` still contains its own copy of these. `math/axis.zig` exists, but nothing imports it and it has no tests.
- **Responsibility:** Vec2, Vec3, Vec4 (via `@Vector`), Quat, Mat4, and the operations all other modules need (add/sub/scale/dot/cross/normalize/lerp/slerp, view/projection matrix construction for both orthographic and perspective cameras).
- **Depends on:** nothing (leaf module).
- **Notes:** Consolidating the duplicate Vec3 code in `physics_solver.zig` is the first remaining task in roadmap step 1. Add the other operations when a caller needs them, not speculatively.

### 5.2 `core/`

- **Status:** Not started as a module. The `Engine` struct lives in `main.zig`, `FixedTimestep` lives in `physics_solver.zig`, and `Platform` (windowing, event polling, frame timing, frame limit) lives in `platform.zig`. There is no `Transform` type. The tick loop is the body of `main`, not an `Engine.run` method.
- **Responsibility:** `Engine` struct (owns every subsystem instance), `FixedTimestep` accumulator, `Transform` definition (§4.1), tick-order orchestration.
- **Public surface (target):** `Engine.init/deinit/tick/run`; `Transform` type with 2D convenience constructors; `FixedTimestep.consume`. Current: `Engine.init/deinit/tick/spawnDemoScene`; `FixedTimestep.consume`.
- **Depends on:** `math/`.

### 5.3 `ecs/`

- **Status:** Two registries exist, and neither is canonical. `ecs_movement.Registry` is hand-written with fixed-size arrays. `ecs_stress_test.zig` uses `zig-ecs` (`prime31/zig-ecs`). Their component types differ (see §10).
- **Responsibility:** thin wrapper/convention layer over the chosen ECS approach. This module formalizes which ECS is canonical going forward and documents standard components: `Transform`, `Velocity`, `Sprite`, `MeshHandle`, `Collider`, etc.
- **Depends on:** `math/`, `core/`.

### 5.4 `physics/`

- **Status:** Partial. `physics_solver.zig` has `RigidBody`, `Aabb`, `FixedTimestep`, `PhysicsWorld.step`, and impulse resolution with positional correction. Missing: the axis lock (§4.4), a broad phase better than O(n²), rotation, and friction.
- **Responsibility:** `RigidBody`, `Aabb`, impulse resolution, plus per-body axis-lock config (§4.4).
- **Public surface (target):** `PhysicsWorld.step`, `RigidBody` with an added `axis_lock: AxisLock` field (exact shape TBD — see §10).
- **Depends on:** `math/`, `ecs/`.

### 5.5 `render/gpu/`

- **Status:** Partial. `vulkan_swapchain.zig` creates the instance, SDL surface, physical device (graphics and present queue families), logical device, command pool, queues, swapchain (prefers B8G8R8A8 sRGB and mailbox present mode, falls back to FIFO), and image views. It implements `acquire_next_image`, `present`, and `recreate_swapchain`. It is not called from `main.zig`. Not yet implemented: validation layers (see `docs/vulkan-validation-layers.md`), render pass, graphics pipeline, framebuffers, frame synchronization, per-frame command recording.
- **Responsibility:** the Vulkan instance/device/swapchain/instanced-draw core. Unchanged in purpose; extended only as needed by sprite/mesh/diorama renderers above it.
- **Depends on:** `math/`.

### 5.6 `render/camera/`

- **Status:** Not started.
- **Responsibility:** three camera archetypes, each producing a view-projection matrix and declaring what kind of depth-sort/physics-locking convention it implies (as a hint, not an enforced rule — see §4.4).
  - `TopDownCamera`: orthographic, optional tilt, produces sort-key convention per §4.3.
  - `SidePlaneCamera`: fixed-angle (orthographic or narrow perspective), declares the locked axis.
  - `DioramaCamera`: perspective, exposes depth-of-field parameters for the Octopath look.
- **Depends on:** `math/`.

### 5.7 `render/sprite/`

- **Status:** Not started.
- **Responsibility:** billboarded/quad rendering, texture-batched draw calls, Y-sort ordering using the sort-key convention from §4.3. This is the primary rendering path for the top-down archetype and half of the diorama archetype.
- **Depends on:** `render/gpu/`, `render/camera/`, `assets/`.

### 5.8 `render/mesh/`

- **Status:** Partial. `drawInstanced` in `vulkan_swapchain.zig` records one indexed instanced draw from a mapped instance buffer. `src/cube_data.zig` holds a unit cube (vertices ±1, 36 indices), and `src/vert.glsl` and `src/frag.glsl` contain instanced-cube shaders. None of these is compiled or uploaded yet. No material or lighting support.
- **Responsibility:** instanced mesh rendering, extended with material/lighting support as needed by side-plane and diorama archetypes.
- **Depends on:** `render/gpu/`, `render/camera/`, `assets/`.

### 5.9 `render/diorama/`

- **Status:** Not started.
- **Responsibility:** the Octopath-specific compositing layer — depth-tests sprite billboards (from `render/sprite/`) against 3D mesh geometry (from `render/mesh/`) in a single shared depth buffer, plus whatever lighting/shadow/depth-of-field treatment defines the "HD-2D" look. This module is the concrete answer to "keep diorama as the Octopath Traveler implementation" — it is not a generic third rendering mode, it's specifically this look.
- **Depends on:** `render/sprite/`, `render/mesh/`, `render/camera/` (specifically `DioramaCamera`).

### 5.10 `tilemap/`

- **Status:** Not started.
- **Responsibility:** tile grid representation, tile-based collision, chunked loading/unloading for larger worlds. Feeds `physics/` (tile colliders) and `render/sprite/` (tile draw as a specialized, highly-batched sprite case).
- **Depends on:** `math/`, `physics/`, `render/sprite/`, `assets/`.

### 5.11 `animation/`

- **Status:** Not started.
- **Responsibility:** spritesheet frame playback, state-driven animation (idle/walk/attack/etc.), drives which frame `render/sprite/` draws for a given entity each tick.
- **Depends on:** `ecs/`, `assets/`.
- **Notes:** needed by every archetype except pure side-plane physics objects (e.g., the Sideswipe ball), but especially central to top-down and fighting-game character rendering.

### 5.12 `hitbox/`

- **Status:** Not started.
- **Responsibility:** hitbox/hurtbox definitions **linked to animation frames**, not to the physics solver's AABB overlap — frame-accurate active/startup/recovery windows for fighting gameplay. Queries physics-style overlap tests but runs as its own system, outside the physics tick, so fighting-game-specific timing rules don't leak into general physics.
- **Depends on:** `animation/`, `physics/` (for the overlap-test primitives only, not the solver itself).

### 5.13 `audio/`

- **Status:** Not started. `-Dopenal=true` links the OpenAL library and nothing else.
- **Responsibility:** OpenAL backend + stub. Positional audio (stereo pan by world X, or full 3D attenuation for diorama/side-plane) as a natural early win.
- **Depends on:** `math/`, `ecs/`.

### 5.14 `net/core/`

- **Status:** Not started.
- **Responsibility:** the **NetBackend interface** — the API-level contract described in §6. Defines how input commands are represented and serialized, how and when a backend is asked to advance simulation, and the snapshot format used for rollback/resync. This is the most important module in the networking stack precisely because it's the *only* one a game dev is required to care about if they bring their own networking.
- **Depends on:** `core/`, `ecs/` (needs to serialize component state generically).

### 5.15 `net/lockstep/`, `net/rollback/`, `net/server_auth/`

- **Status:** Not started.
- **Responsibility:** three reference implementations of `NetBackend`, each suited to a different archetype from the reference list:
  - `lockstep/` — deterministic lockstep, good fit for Don't Starve Together-style co-op.
  - `rollback/` — rollback netcode, good fit for Rivals of Aether 2-style fighting games.
  - `server_auth/` — server-authoritative with client prediction, good fit for Rocket League Sideswipe-style physics-heavy competitive play.
- **Depends on:** `net/core/`.
- **Notes:** these are *reference* implementations, shipped as convenience, not as the only option. A game dev is free to implement `NetBackend` themselves and ignore all three.

### 5.16 `assets/`

- **Status:** Partial. `resources.zig` contains `TextureCache`, which decodes files or embedded bytes through zstbi into RGBA8 and caches them by key. It returns `*Texture` pointers that the cache owns. `FontCache` and `ShaderCache` are stubs that return "not implemented" errors. Not yet implemented: GPU upload, handle-based references, and an asset root for file paths.
- **Responsibility:** texture/mesh/audio-clip loading and caching, referenced by handle (not by repeatedly loading from disk). Needed early (by the time sprites exist) rather than late.
- **Depends on:** nothing beyond `std` and the chosen file-format libraries (currently zstbi).
- **Notes:** the current design returns pointers, which are stable only because each texture is heap-allocated and owned by the cache. The plan calls for handles. This should be decided before GPU upload begins (§10). See `docs/resources.md`.

---

## 6. Multiplayer / Networking Design

*Status: not started. Nothing in this section is implemented yet.*

### 6.1 Philosophy

The engine does **not** ship a mandatory networking layer. It ships:

1. A small, stable **`NetBackend` interface** (in `net/core/`) that any networking approach can implement.
2. A **deterministic-capable simulation core** — the fixed-timestep tick, physics step, and ECS updates are written so that, *if a game dev chooses to*, the same input sequence produces the same simulation result every time, on every machine. This is a property the core makes *possible*, not one it forces on every game.
3. Three **reference implementations** of `NetBackend` (lockstep, rollback, server-authoritative) covering the three multiplayer shapes implied by the reference games, so most devs never need to write their own — but nothing prevents them from doing so.

### 6.2 The `NetBackend` contract (conceptual shape, not final API)

At minimum, this interface needs to express:

- **Input commands as data**, not direct state mutation — e.g. "player pressed jump" is a serializable value fed into the simulation, never a direct call into physics/ECS from input code. This is what makes lockstep and rollback possible at all: the sim only ever consumes commands, and commands are what get sent over the network or replayed.
- **A snapshot/restore operation** on simulation state — needed by rollback (restore an older snapshot, replay newer inputs) and by server-authoritative resync (client receives authoritative snapshot, reconciles).
- **A "tick advance" entry point** distinct from the local single-player loop, so a net backend can drive the simulation at its own cadence (e.g., rollback re-simulating several ticks in one real frame).

### 6.3 Determinism checklist (applies only to games that opt in)

Documented here so it's a conscious, revisitable checklist rather than folklore:

- Avoid iteration order dependent on hash-map/pointer ordering in any code path that affects simulation results (physics body iteration, ECS view iteration) — must be stable/deterministic ordering (e.g., by entity ID) wherever simulation-affecting.
- No wall-clock reads inside the fixed-timestep tick — `delta_time` for the sim step always comes from the fixed accumulator, never from `SDL_GetPerformanceCounter` directly inside `PhysicsWorld.step` or similar.
- Floating-point determinism across platforms is a known hard problem — flag it here as a risk to revisit specifically at the point rollback (`net/rollback/`) is implemented, rather than solving it speculatively now. Options to evaluate then: fixed-point math for the simulation-critical path, or accepting platform-matched builds only (common in shipped fighting games).
- RNG must be seeded and advanced deterministically. Both ECS demos already seed their generators. Extend the same rule to gameplay RNG, not just test RNG.

**Current state against this checklist.** Physics and the ECS demos iterate in index or insertion order, which is stable. Both ECS demos use seeded RNG. `Engine.tick` breaks the wall-clock rule: it moves ECS entities by the frame delta from `Platform`, not by the fixed step (see §10). Floating-point determinism has not been addressed, as planned.

---

## 7. Coding Conventions

- **Naming:** PascalCase types, camelCase functions/methods, snake_case fields and file names.
- **Errors:** per-subsystem error sets; error unions for recoverable failures; `unreachable` reserved for genuine invariant violations, never for "expected but unhandled" cases.
- **Allocators:** always passed explicitly. Arena allocators preferred for per-frame or per-level transient work (asset loading, temporary collision-pair lists, per-tick command buffers in `net/`).
- **Collections:** use the unmanaged `std.ArrayList` (`.empty` to initialize, allocator passed to each call). This is the form `physics_solver.zig` and `resources.zig` use.
- **Testing:** every pure function/module gets unit tests; deterministic seeded RNG in any test touching randomness (established convention, keep it).
- **Comptime:** used only for genuinely generic, zero-runtime-cost code (shared vector types, component registration) — not reached for by default.
- **vtables (fn-pointer structs):** used only at genuine backend-swap boundaries — GPU backend, audio backend, and now `NetBackend`. Everywhere else, plain functions and comptime generics.
- **Docs:** `///` doc comments on all public API. One short `<subsystem>.md` per module explaining *why*. Existing: `docs/vulkan-validation-layers.md`, `docs/resources.md`. Others are not yet written.
- **Layering discipline (§2):** a module may only import modules at or below its own layer. Violations should be caught in review; worth a CI lint once the module count grows past what a human can eyeball.

**Current deviations from these rules:**

- `vulkan_swapchain.zig` uses snake_case method names (`acquire_next_image`, `recreate_swapchain`) and the managed `std.ArrayList` API. Both should be fixed to match the rules above. The fixes are not yet made.
- `ecs_movement.zig` contains an unused `main` function, which should be removed (see README known issues).

---

## 8. Build System & Feature Flags

The flag pattern in `build.zig` is established. Extend it rather than replacing it.

- `-Dvulkan=<bool>` — **Exists.** Compiles the optional SDL3 and Vulkan path (`vulkan_swapchain.zig`, `sdl_bindings.zig`, and the `vulkan` and `sdl` dependencies). Sets `build_options.enable_vulkan`.
- `-Dopenal=<bool>` — **Exists.** Links OpenAL. No audio code yet.
- `-Dvulkan-lib-dir=<path>`, `-Dopenal-lib-dir=<path>` — **Exist** (Windows; Vulkan falls back to `%VULKAN_SDK%\Lib`).
- `-Doptimize=<mode>` — **Exists** as the standard Zig option, and is the switch for debug-only behavior such as validation. The validation design previously proposed a custom `-Dmode`. That is replaced by `-Doptimize`, which `build.zig` already passes to the executable and test artifacts.
- `build_options.enable_validation` — **Planned.** Defined as `optimize == .Debug`. See `docs/vulkan-validation-layers.md`.
- `-Dnetcode=<none|lockstep|rollback|server_auth>` — **Planned.** Selects which reference `net/*` implementation, if any, gets compiled in. Default `none` — a single-player game pays zero cost for networking code it doesn't use.
- `-Ddiorama=<bool>` — **Planned.** Gates `render/diorama/`, since it depends on both sprite and mesh renderers and is the heaviest single rendering module; a top-down-only or side-plane-only game shouldn't need to compile it.
- Dependencies pinned by commit hash in `build.zig.zon` — **Exists.** Each pin should have a one-line comment on *why* it is pinned to that commit. **Not yet done.** The current `build.zig.zon` has no such comments.

---

## 9. Step-by-Step Implementation Roadmap

Ordered to validate the riskiest shared-core assumption — "one Transform/physics/ECS core really can serve all three archetypes" — as early and cheaply as possible, before investing in archetype-specific polish.

Status key: **[Done]** means implemented and in use. **[Partial]** means some of the step exists. **[Not started]** means no code yet.

1. **[Partial] Foundations.** `math/vec.zig` exists, but physics still uses its own copy. The unified `Transform` in `core/` with 2D constructors has not been written. The axis-lock field is not on `RigidBody`. This document is kept up to date.
2. **[Partial] Window + input.** `Platform` (used by `main`) and `SDLContext` (in `sdl_bindings.zig`, with quit-event polling) exist. Keyboard, mouse, and other input are not implemented.
3. **[Not started] Top-down sprite renderer + Y-sort.** `render/camera/` (`TopDownCamera` only), `render/sprite/`, and the depth-sort-key convention from §4.3.
4. **[Partial] `assets/` (textures only, for now) + real sprite textures.** CPU-side PNG decoding exists (`TextureCache`). GPU upload does not.
5. **[Not started] `tilemap/`.** Tile grid, tile collision, chunked loading.
6. **[Not started] `animation/`.** Spritesheet playback wired to sprite rendering.
7. **[Not started] Top-down demo playable.** The first real "is the architecture right" checkpoint.
8. **[Not started] Side-plane camera + axis-locked physics demo.** The second architecture checkpoint, on the same Transform/physics/ECS core as steps 3–7.
9. **[Not started] `hitbox/`.** Layered on step 8, animation-driven fighting-game hit detection.
10. **[Not started] `net/core/` (the `NetBackend` interface itself).** Designed against both the top-down demo (step 7) and the side-plane demo (step 8), so the interface is validated against two different needs before being called stable.
11. **[Not started] One reference net backend end to end.** Start with `net/lockstep/` against the top-down demo, since lockstep is conceptually the simplest to get right first and Don't Starve Together-style co-op is the most directly analogous reference.
12. **[Partial] `render/mesh/` extended + `render/diorama/`.** Instanced draw recording exists (`drawInstanced`), but it is not yet wired into a frame, and `render/diorama/` is not started. Stays deliberately late in the plan because it depends on both sprite and mesh paths being solid. Third architecture checkpoint (mixing sprite and mesh entities in one depth-tested scene). See §10 for the ordering question.
13. **[Not started] `net/rollback/` and `net/server_auth/`**, if/when the corresponding archetype becomes the active focus.
14. **[Not started] `audio/`.** OpenAL, positional audio by world position, collision-triggered sounds.
15. **[Not started] Polish/tooling.** Hot asset reload, profiling/telemetry, possibly a lightweight inspector.

---

## 10. Open Questions Log

Keep this section current. Resolved questions move to the relevant section above with a note of the decision made; new questions get added here rather than decided silently mid-implementation.

- **Canonical vector type.** Three vector representations exist: `math/vec.zig`'s `Vec3`, the duplicate in `physics_solver.zig`, and `[3]f32` fields in `ecs_stress_test.zig`. Pick one before `Transform` is written. Proposed: `math/vec.zig`'s `Vec3`, since it is already the leaf module.
- **Canonical ECS and component types** (§5.3). Two registries define `Position`, `Velocity`, and `Aabb` differently. `Aabb` is min/max in physics and half-extents in the stress test. Choose one ECS and one set of component types before `tilemap/`, `animation/`, and `hitbox/` depend on them.
- **Simulation clock for ECS movement** (§6.3). `Engine.tick` moves entities by the frame delta, but the determinism checklist requires simulation state to advance on the fixed step. Decide whether entity movement is simulation (move it into the fixed step) or presentation (keep it on the frame delta and document that it is outside the deterministic core).
- **Timestep backlog policy** (§4 and §5.4). `FixedTimestep.consume` keeps excess time, so slow frames are repaid later. Its comment says excess steps are dropped. Pick one behavior and make the code and comment agree.
- **`AxisLock` shape** (§4.4, §5.4). `math/axis.zig` has a three-bool `AxisMask`. §4.4 sketches an enum with `.lock_depth` and `.lock_height`. The bool mask can express any combination, while the enum is simpler to read and reason about. Choose before side-plane work (step 8).
- **Asset reference style** (§5.16). Current code returns pointers. The plan calls for handles. Decide before GPU upload, since handles determine how the renderer refers to textures.
- **Where `Engine` lives** (§5.2). It is in `main.zig` today. Moving it to `core/` is cheap now and gets harder as more code depends on it.
- **Milestone order.** Instanced mesh drawing (roadmap step 12) is partly built, while the top-down steps 2–7 have no code. Decide whether that is intended. If the Vulkan path is the next focus, step 12 moves earlier, and the "deliberately late" note in §9 changes.
- **Floating-point determinism strategy for rollback** (§6.3). Deferred on purpose to step 13; needs a real decision (fixed-point vs. platform-matched builds) before `net/rollback/` ships.

**Resolved:** validation build flag. The custom `-Dmode` proposal is replaced by the standard `-Doptimize`. Recorded in §8 and in `docs/vulkan-validation-layers.md`.
