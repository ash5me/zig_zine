# ARCHITECTURE.md — Engine Design & Implementation Plan

**Status:** Planning document. No implementation code exists for the ideas below yet — this
file is the source of truth for *why* things will be built the way they will be, so it should
be read before any module is written or changed. When a design decision here turns out to be
wrong, update this file in the same change that fixes the code — this document must never
drift from what the codebase actually does.

**Working project name:** `zig_zine` (unchanged; rename is a non-architectural decision for later).

**Audience for this document:** a human collaborator *and* an AI coding assistant picking up
work in a fresh session with no memory of this conversation. Every section should be
self-contained enough that "implement module X" can be handed to an AI agent along with just
that module's spec and produce code consistent with the rest of the engine.

---

## 1. Purpose & Design Philosophy

### 1.1 North star

A single engine, sharing one core (ECS, transform model, physics, fixed-timestep loop), that
comfortably serves three distinct camera/gameplay archetypes — **top-down**, **side-plane**,
and **diorama (HD-2D)** — without forking into "the 2D engine" and "the 3D engine" internally.
2D vs. 3D is never a global mode switch; it is a property of individual cameras and individual
entities. A single game may legitimately mix sprite entities and mesh entities in the same
scene (this is, in fact, exactly what the diorama archetype requires).

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

1. **Modularity over convenience defaults.** Every subsystem beyond the absolute core
   (math, ECS, fixed-timestep loop, transform) is opt-in. A game dev who only wants top-down
   tile gameplay should not pay compile time, binary size, or conceptual overhead for
   hitbox/hurtbox systems or diorama compositing they never enabled.
2. **API-level multiplayer, not framework-level.** The engine does not ship "the" networking
   solution. It ships a small, stable **NetBackend interface** plus a few reference
   implementations (lockstep, rollback, server-authoritative) that a game dev can use as-is,
   swap out, or ignore entirely and write their own against the same interface. The engine's
   job is to make the *core simulation deterministic-capable* (see §6), not to dictate a
   networking architecture.
3. **Determinism is a property games opt into, not a permanent constraint on the core.**
   The physics/ECS tick is written so that it *can* be made deterministic (fixed-point-friendly
   math paths, no hidden iteration-order-dependent state, no wall-clock reads inside the sim
   step) but a single-player game that doesn't care pays no extra complexity tax for this.
4. **One Transform, one physics core, three cameras.** See §4 and §5.5 — this is the load-bearing
   decision that keeps the three archetypes from becoming three engines.
5. **Stub-backend pattern everywhere a real dependency (GPU, audio device, network socket)
   would block testing or compilation.** Established already for SDL/Vulkan/OpenAL; extend the
   same pattern to networking and tilemap/asset I/O.
6. **Boring, explicit Zig.** Comptime and vtables are used only at genuine extension points
   (see §7). Everywhere else: plain functions, plain structs, explicit allocators.

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

Rule: a layer may depend only on layers below it. `render/` never imports `tilemap/`.
`tilemap/` never imports `hitbox/`. This is enforced by convention and code review, not by
the compiler — worth a lint/CI check once the module count grows.

---

## 3. Directory Layout

```
src/
  math/              Vec2, Vec3, Vec4, Quat, Mat4 — shared, dimension-agnostic
  core/              Engine struct, fixed-timestep accumulator, tick order, Transform
  ecs/               Registry wrapper, component conventions, standard components
  physics/           Rigid bodies, AABB broad-phase, impulse resolution, axis-locking
  render/
    gpu/             Vulkan instance/device/swapchain — the shared GPU core (exists today)
    sprite/          Sprite batching, billboarding, Y-sort
    mesh/            Mesh loading, instanced mesh draw (exists today, extend)
    camera/          TopDownCamera, SidePlaneCamera, DioramaCamera
    diorama/         Depth-compositing sprites into a 3D scene (Octopath-style)
  tilemap/           Tile grid, tile collision, chunked loading
  animation/         Spritesheet playback, state-driven animation
  hitbox/            Hitbox/hurtbox definitions, animation-linked active-frame queries
  audio/              OpenAL backend + stub
  net/
    core/            NetBackend interface, input-command abstraction, snapshot format
    lockstep/        Reference implementation: deterministic lockstep (good for co-op, DST-like)
    rollback/         Reference implementation: rollback netcode (good for fighting games)
    server_auth/      Reference implementation: server-authoritative (good for Sideswipe-like)
  assets/            Texture/mesh/audio-clip loading and caching
docs/
  ARCHITECTURE.md    This file
  <subsystem>.md      One short "why" doc per subsystem, as already started for Vulkan validation
```

---

## 4. Core Data Model

### 4.1 Transform (unified, not archetype-specific)

Every entity that exists in space uses the **same** Transform shape:
`position: Vec3`, `rotation: Quat`, `scale: Vec3`. A 2D top-down entity simply leaves
Z and non-Z rotation at their defaults. This is what lets physics, rendering, and any future
scene-graph/parenting code be written exactly once and used by all three archetypes.

To keep 2D game code ergonomic despite the 3D-shaped storage, provide small convenience
constructors — e.g. a function that takes `(x, y, rotation_degrees, scale: Vec2)` and returns
a full `Transform` — so top-down/side-plane game code never has to construct a quaternion by
hand. These are thin helpers, not a parallel data type.

### 4.2 Coordinate system

- **Y-up, right-handed**, consistent across all three archetypes.
- Sprite/top-down rendering performs the "Y increases downward on screen" flip internally,
  at the point where world space maps to screen space. This keeps the shared math
  archetype-agnostic while still matching what 2D developers expect to see.

### 4.3 Depth-sort key (distinct from Z)

Top-down rendering order is **not** simply "sort by Z". A jumping character's visual height
offset must not change its draw-order relative to nearby tiles. So:

- `Transform.position` — actual simulated position (used by physics, used for gameplay logic).
- A separate, computed **sort key** — typically derived from the entity's world-space
  "anchor" (feet position), *not* including any jump/height visual offset — is what the
  sprite renderer actually sorts by.
- Height offset (jump arc, thrown-object arc) is applied **only** as a rendering-time
  translation, after the sort key is computed, never fed back into the sort key itself.

This separation is the single trickiest part of top-down 2.5D rendering and is called out
explicitly so it's designed on purpose rather than discovered as a bug later.

### 4.4 Axis-locking physics model

The physics core (already built) operates on full `Vec3` positions/velocities/AABBs — this
doesn't change. What's added is a per-body **axis lock** concept:

- Top-down archetype: bodies typically lock nothing in the *transform* sense (height still
  simulates for jump arcs), but collision resolution for top-down gameplay generally treats
  X/Y as the "gameplay plane" and Z (height) as visual-only, not collidable, unless the game
  explicitly opts into height-based collision (e.g., jumping over a pit).
- Side-plane archetype: locks depth (whichever axis is perpendicular to the visible plane) so
  a Rivals-of-Aether-style character can't drift off the fighting plane, while X/Y (or X/Z,
  depending on plane orientation) simulate fully in 3D.
- Diorama archetype: no locking — full 3D simulation, sprites are billboarded visual
  representations of fully-3D-simulated entities.

The exact lock is a small per-body configuration (which axis, if any, is constrained), not a
different solver. One solver, configurable per body — this is a generalization of the
Z-locking idea from the original 2D-vs-3D plan, now applied per-archetype instead of globally.

---

## 5. Module Specifications

Each module below is written so it can be handed, on its own, to a coding session as a
self-contained spec. "Public surface" describes responsibilities and shape, not literal code.

### 5.1 `math/`
- **Responsibility:** Vec2, Vec3, Vec4 (via `@Vector`), Quat, Mat4, and the operations all
  other modules need (add/sub/scale/dot/cross/normalize/lerp/slerp, view/projection matrix
  construction for both orthographic and perspective cameras).
- **Depends on:** nothing (leaf module).
- **Notes:** This consolidates the Vec3 math currently duplicated in `physics_solver.zig` and
  elsewhere. Should be written once other modules' actual needs are known, not speculatively.

### 5.2 `core/`
- **Responsibility:** `Engine` struct (owns every subsystem instance), `FixedTimestep`
  accumulator (exists), `Transform` definition (§4.1), tick-order orchestration.
- **Public surface:** `Engine.init/deinit/tick/run`; `Transform` type + 2D convenience
  constructors; `FixedTimestep.consume`.
- **Depends on:** `math/`.

### 5.3 `ecs/`
- **Responsibility:** thin wrapper/convention layer over the chosen ECS approach (currently
  either the hand-rolled registry or `zig-ecs`, per what's already in the repo — this module
  formalizes which one is canonical going forward and documents standard components:
  `Transform`, `Velocity`, `Sprite`, `MeshHandle`, `Collider`, etc.)
- **Depends on:** `math/`, `core/`.

### 5.4 `physics/`
- **Responsibility:** `RigidBody`, `Aabb`, impulse resolution (exists) + per-body axis-lock
  config (§4.4).
- **Public surface:** `PhysicsWorld.step`, `RigidBody` with an added `axis_lock: AxisLock`
  field (enum: `.none`, `.lock_depth`, `.lock_height`, or similar — exact shape TBD at
  implementation time).
- **Depends on:** `math/`, `ecs/`.

### 5.5 `render/gpu/`
- **Responsibility:** the existing Vulkan instance/device/swapchain/instanced-draw core.
  Unchanged in purpose; extended only as needed by sprite/mesh/diorama renderers above it.
- **Depends on:** `math/`.

### 5.6 `render/camera/`
- **Responsibility:** three camera archetypes, each producing a view-projection matrix and
  declaring what kind of depth-sort/physics-locking convention it implies (as a hint, not an
  enforced rule — see §4.4).
  - `TopDownCamera`: orthographic, optional tilt, produces sort-key convention per §4.3.
  - `SidePlaneCamera`: fixed-angle (orthographic or narrow perspective), declares the locked
    axis.
  - `DioramaCamera`: perspective, exposes depth-of-field parameters for the Octopath look.
- **Depends on:** `math/`.

### 5.7 `render/sprite/`
- **Responsibility:** billboarded/quad rendering, texture-batched draw calls, Y-sort ordering
  using the sort-key convention from §4.3. This is the primary rendering path for the
  top-down archetype and half of the diorama archetype.
- **Depends on:** `render/gpu/`, `render/camera/`, `assets/`.

### 5.8 `render/mesh/`
- **Responsibility:** the existing instanced mesh rendering (`vulkan_swapchain.zig`'s
  `drawInstanced`), extended with material/lighting support as needed by side-plane and
  diorama archetypes.
- **Depends on:** `render/gpu/`, `render/camera/`, `assets/`.

### 5.9 `render/diorama/`
- **Responsibility:** the Octopath-specific compositing layer — depth-tests sprite billboards
  (from `render/sprite/`) against 3D mesh geometry (from `render/mesh/`) in a single shared
  depth buffer, plus whatever lighting/shadow/depth-of-field treatment defines the "HD-2D"
  look. This module is the concrete answer to "keep diorama as the Octopath Traveler
  implementation" — it is not a generic third rendering mode, it's specifically this look.
- **Depends on:** `render/sprite/`, `render/mesh/`, `render/camera/` (specifically
  `DioramaCamera`).

### 5.10 `tilemap/`
- **Responsibility:** tile grid representation, tile-based collision, chunked loading/unloading
  for larger worlds. Feeds `physics/` (tile colliders) and `render/sprite/` (tile draw as a
  specialized, highly-batched sprite case).
- **Depends on:** `math/`, `physics/`, `render/sprite/`, `assets/`.

### 5.11 `animation/`
- **Responsibility:** spritesheet frame playback, state-driven animation (idle/walk/attack/etc.),
  drives which frame `render/sprite/` draws for a given entity each tick.
- **Depends on:** `ecs/`, `assets/`.
- **Notes:** needed by every archetype except pure side-plane physics objects (e.g., the
  Sideswipe ball), but especially central to top-down and fighting-game character rendering.

### 5.12 `hitbox/`
- **Responsibility:** hitbox/hurtbox definitions **linked to animation frames**, not to the
  physics solver's AABB overlap — frame-accurate active/startup/recovery windows for fighting
  gameplay. Queries physics-style overlap tests but runs as its own system, outside the
  physics tick, so fighting-game-specific timing rules don't leak into general physics.
- **Depends on:** `animation/`, `physics/` (for the overlap-test primitives only, not the
  solver itself).

### 5.13 `audio/`
- **Responsibility:** OpenAL backend + stub (not yet started). Positional audio (stereo pan by
  world X, or full 3D attenuation for diorama/side-plane) as a natural early win.
- **Depends on:** `math/`, `ecs/`.

### 5.14 `net/core/`
- **Responsibility:** the **NetBackend interface** — the actual API-level contract described
  in §6. Defines: how input commands are represented and serialized, how/when a backend is
  asked to advance simulation, and the snapshot format used for rollback/resync. This is the
  most important module in the networking stack precisely because it's the *only* one a game
  dev is required to care about if they bring their own networking.
- **Depends on:** `core/`, `ecs/` (needs to serialize component state generically).

### 5.15 `net/lockstep/`, `net/rollback/`, `net/server_auth/`
- **Responsibility:** three reference implementations of `NetBackend`, each suited to a
  different archetype from the reference list:
  - `lockstep/` — deterministic lockstep, good fit for Don't Starve Together-style co-op.
  - `rollback/` — rollback netcode, good fit for Rivals of Aether 2-style fighting games.
  - `server_auth/` — server-authoritative with client prediction, good fit for Rocket League
    Sideswipe-style physics-heavy competitive play.
- **Depends on:** `net/core/`.
- **Notes:** these are *reference* implementations, shipped as convenience, not as the only
  option. A game dev is free to implement `NetBackend` themselves and ignore all three.

### 5.16 `assets/`
- **Responsibility:** texture/mesh/audio-clip loading and caching, referenced by handle (not
  by repeatedly loading from disk). Needed early (by the time sprites exist) rather than late.
- **Depends on:** nothing beyond `std` and whatever file formats are chosen.

---

## 6. Multiplayer / Networking Design

### 6.1 Philosophy

The engine does **not** ship a mandatory networking layer. It ships:

1. A small, stable **`NetBackend` interface** (in `net/core/`) that any networking approach
   can implement.
2. A **deterministic-capable simulation core** — the fixed-timestep tick, physics step, and
   ECS updates are written so that, *if a game dev chooses to*, the same input sequence
   produces the same simulation result every time, on every machine. This is a property the
   core makes *possible*, not one it forces on every game.
3. Three **reference implementations** of `NetBackend` (lockstep, rollback, server-authoritative)
   covering the three multiplayer shapes implied by the reference games, so most devs never
   need to write their own — but nothing prevents them from doing so.

### 6.2 The `NetBackend` contract (conceptual shape, not final API)

At minimum, this interface needs to express:

- **Input commands as data**, not direct state mutation — e.g. "player pressed jump" is a
  serializable value fed into the simulation, never a direct call into physics/ECS from input
  code. This is what makes lockstep and rollback possible at all: the sim only ever consumes
  commands, and commands are what get sent over the network or replayed.
- **A snapshot/restore operation** on simulation state — needed by rollback (restore an older
  snapshot, replay newer inputs) and by server-authoritative resync (client receives
  authoritative snapshot, reconciles).
- **A "tick advance" entry point** distinct from the local single-player loop, so a net backend
  can drive the simulation at its own cadence (e.g., rollback re-simulating several ticks in
  one real frame).

### 6.3 Determinism checklist (applies only to games that opt in)

Documented here so it's a conscious, revisitable checklist rather than folklore:

- Avoid iteration order dependent on hash-map/pointer ordering in any code path that affects
  simulation results (physics body iteration, ECS view iteration) — must be stable/deterministic
  ordering (e.g., by entity ID) wherever simulation-affecting.
- No wall-clock reads inside the fixed-timestep tick — `delta_time` for the sim step always
  comes from the fixed accumulator, never from `SDL_GetPerformanceCounter` directly inside
  `PhysicsWorld.step` or similar.
- Floating-point determinism across platforms is a known hard problem — flag it here as a risk
  to revisit specifically at the point rollback (`net/rollback/`) is implemented, rather than
  solving it speculatively now. Options to evaluate then: fixed-point math for the
  simulation-critical path, or accepting platform-matched builds only (common in shipped
  fighting games).
- RNG must be seeded and advanced deterministically (already the established convention in
  this codebase's tests — extend it to gameplay RNG, not just test RNG).

---

## 7. Coding Conventions

- **Naming:** PascalCase types, camelCase functions/methods, snake_case fields and file names.
- **Errors:** per-subsystem error sets; error unions for recoverable failures; `unreachable`
  reserved for genuine invariant violations, never for "expected but unhandled" cases.
- **Allocators:** always passed explicitly. Arena allocators preferred for per-frame or
  per-level transient work (asset loading, temporary collision-pair lists, per-tick command
  buffers in `net/`).
- **Testing:** every pure function/module gets unit tests; deterministic seeded RNG in any
  test touching randomness (established convention, keep it).
- **Comptime:** used only for genuinely generic, zero-runtime-cost code (shared vector types,
  component registration) — not reached for by default.
- **vtables (fn-pointer structs):** used only at genuine backend-swap boundaries — GPU backend,
  audio backend, and now `NetBackend`. Everywhere else, plain functions and comptime generics.
- **Docs:** `///` doc comments on all public API. One short `<subsystem>.md` per module
  explaining *why*, continuing the pattern started with `docs/vulkan-validation-layers.md`.
- **Layering discipline (§2):** a module may only import modules at or below its own layer.
  Violations should be caught in review; worth a CI lint once the module count grows past
  what a human can eyeball.

---

## 8. Build System & Feature Flags

Extend the existing flag pattern (`-Dvulkan`, `-Dopenal`) rather than replacing it:

- `-Dvulkan=<bool>` — existing.
- `-Dopenal=<bool>` — existing.
- `-Dnetcode=<none|lockstep|rollback|server_auth>` — selects which reference `net/*`
  implementation, if any, gets compiled in. Default `none` — a single-player game pays zero
  cost for networking code it doesn't use.
- `-Ddiorama=<bool>` — gates `render/diorama/`, since it depends on both sprite and mesh
  renderers and is the heaviest single rendering module; a top-down-only or side-plane-only
  game shouldn't need to compile it.
- Dependencies stay pinned by commit hash in `build.zig.zon`, each with a one-line comment on
  *why* pinned to that commit (established convention, keep it).

---

## 9. Step-by-Step Implementation Roadmap

Ordered to validate the riskiest shared-core assumption — "one Transform/physics/ECS core
really can serve all three archetypes" — as early and cheaply as possible, before investing in
archetype-specific polish.

1. **Foundations.** `math/` module (consolidate Vec3 math). Unified `Transform` in `core/`,
   with 2D convenience constructors. Axis-lock field added to `RigidBody`. This
   ARCHITECTURE.md kept up to date as the source of truth.
2. **Window + input.** Real SDL3 window creation and event polling — currently missing
   entirely; nothing past this point is visually testable without it.
3. **Top-down sprite renderer + Y-sort.** `render/camera/` (`TopDownCamera` only, for now),
   `render/sprite/` with the depth-sort-key convention from §4.3. Goal: colored quads on
   screen, correctly sorted, before textures are involved.
4. **`assets/` (textures only, for now)** + real sprite textures replacing colored quads.
5. **`tilemap/`.** Tile grid, tile collision, chunked loading.
6. **`animation/`.** Spritesheet playback wired to sprite rendering.
7. **Top-down demo playable.** A tiny Stardew/Zelda-ish scene, proving the full top-down stack
   end to end — this is the first real "is the architecture right" checkpoint.
8. **Side-plane camera + axis-locked physics demo.** `render/camera/`'s `SidePlaneCamera`,
   proving the Rivals/Sideswipe archetype on the *same* Transform/physics/ECS core used in
   steps 3–7 — no forked code path. Second major architecture checkpoint.
9. **`hitbox/`.** Layered on step 8, animation-driven fighting-game hit detection.
10. **`net/core/` (the `NetBackend` interface itself)**, designed against both the top-down
    demo (step 7, for lockstep-style co-op) and the side-plane demo (step 8, for rollback-style
    fighting-game netplay) so the interface is validated against two genuinely different needs
    before being called stable.
11. **One reference net backend end to end** — recommend starting with `net/lockstep/` against
    the top-down demo, since lockstep is the conceptually simplest to get right first and
    Don't Starve Together-style co-op is the most directly analogous reference.
12. **`render/mesh/` extended + `render/diorama/`.** The Octopath-style compositor, deliberately
    late since it depends on both sprite and mesh paths being solid. Third architecture
    checkpoint (mixing sprite and mesh entities in one depth-tested scene).
13. **`net/rollback/` and `net/server_auth/`**, if/when the corresponding archetype (fighting
    game, physics-competitive) becomes the active focus — not blocking earlier work.
14. **`audio/`.** OpenAL, positional audio by world position, collision-triggered sounds.
15. **Polish/tooling.** Hot asset reload, profiling/telemetry, possibly a lightweight inspector.

---

## 10. Open Questions Log

Keep this section current — resolved questions move to the relevant section above with a note
of the decision made; new questions get added here rather than decided silently mid-implementation.

- **Floating-point determinism strategy for rollback** (§6.3) — deferred on purpose to step 13;
  needs a real decision (fixed-point vs. platform-matched builds) before `net/rollback/` ships.
- **Exact `AxisLock` shape** (§4.4, §5.4) — sketched conceptually, needs a concrete enum/struct
  design once side-plane physics (step 8) is actually being implemented and real constraints
  are known.
- **Canonical ECS approach** (§5.3) — repo currently has both a hand-rolled registry
  (`ecs_movement.zig`) and `zig-ecs` (`ecs_stress_test.zig`) in use; needs to converge on one
  as the standard before `tilemap/`, `animation/`, and `hitbox/` are built on top of it.
