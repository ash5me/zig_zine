# ARCHITECTURE.md — Engine Design & Implementation Plan

## Overview
Zig Zine is a modular game/graphics engine built with Zig, utilizing an Entity Component System (ECS) architecture with SDL3 for window management and input handling, and Vulkan for graphics rendering.

## Core Architectural Decisions

### 1. Entity Component System (ECS)
- **Why ECS**: Provides excellent performance, data locality, and flexibility for game development
- **Library**: Using [entt](https://github.com/skypjack/entt) as the ECS backbone
- **Design Philosophy**: 
  - Entities are simple IDs
  - Components are pure data structures
  - Systems contain game logic and process entities with specific component combinations

### 2. Rendering Architecture
- **API**: Vulkan for modern, cross-platform graphics
- **Abstraction Level**: Thin wrapper around Vulkan with explicit resource management
- **Render Loop**: Fixed time step for game logic, variable render rate
- **Key Features Planned**:
  - Swapchain management
  - Command buffer recording
  - Descriptor set layouts
  - Pipeline caching
  - Basic material system

### 3. Window & Input Handling
- **Library**: SDL3 for cross-platform window creation and input
- **Responsibilities**:
  - Window creation and management
  - Event polling (keyboard, mouse, gamepad, window events)
  - Context creation for Vulkan
  - Basic audio placeholder (future extension)

### 4. Resource Management
- **Approach**: Cache-based system with handles
- **Asset Types**:
  - Textures (PNG via libpng)
  - Fonts (FreeType + Harfbuzz)
  - Meshes (future: OBJ/glTF)
  - Shaders (SPIR-V)
- **Design**: Reference-counted handles with automatic cleanup

### 5. Engine Core Loop
```
Initialize Systems
├── Create Window (SDL3)
├── Initialize Vulkan
├── Setup ECS Registry
├── Load Core Resources
└── Enter Main Loop

Main Loop:
├── Calculate Delta Time
├── Process Input Events
├── Update Game Systems (fixed time step)
├── Render Frame (variable rate)
└── Present

Shutdown:
├── Wait for GPU Idle
├── Free All Resources
├── Destroy Vulkan Context
├── Destroy Window
└── Exit
```

## Overview
Zig Zine is a modular game/graphics engine built with Zig, utilizing an Entity Component System (ECS) architecture with SDL3 for window management and input handling, and Vulkan for graphics rendering.

## Core Architectural Decisions

### 1. Entity Component System (ECS)
- **Why ECS**: Provides excellent performance, data locality, and flexibility for game development
- **Library**: Using [entt](https://github.com/skypjack/entt) as the ECS backbone
- **Design Philosophy**: 
  - Entities are simple IDs
  - Components are pure data structures
  - Systems contain game logic and process entities with specific component combinations

### 2. Rendering Architecture
- **API**: Vulkan for modern, cross-platform graphics
- **Abstraction Level**: Thin wrapper around Vulkan with explicit resource management
- **Render Loop**: Fixed time step for game logic, variable render rate
- **Key Features Planned**:
  - Swapchain management
  - Command buffer recording
  - Descriptor set layouts
  - Pipeline caching
  - Basic material system

### 3. Window & Input Handling
- **Library**: SDL3 for cross-platform window creation and input
- **Responsibilities**:
  - Window creation and management
  - Event polling (keyboard, mouse, gamepad, window events)
  - Context creation for Vulkan
  - Basic audio placeholder (future extension)

### 4. Resource Management
- **Approach**: Cache-based system with handles
- **Asset Types**:
  - Textures (PNG via libpng)
  - Fonts (FreeType + Harfbuzz)
  - Meshes (future: OBJ/glTF)
  - Shaders (SPIR-V)
- **Design**: Reference-counted handles with automatic cleanup

### 5. Engine Core Loop
```
Initialize Systems
├── Create Window (SDL3)
├── Initialize Vulkan
├── Setup ECS Registry
├── Load Core Resources
└── Enter Main Loop

Main Loop:
├── Calculate Delta Time
├── Process Input Events
├── Update Game Systems (fixed time step)
├── Render Frame (variable rate)
└── Present

Shutdown:
├── Wait for GPU Idle
├── Free All Resources
├── Destroy Vulkan Context
├── Destroy Window
└── Exit
```

## Module Structure

### Core Modules
1. **Application** (`main.zig`)
   - Entry point
   - High-level engine state
   - Main loop coordination

2. **Windowing** (`sdl_bindings.zig`)
   - SDL3 wrapper
   - Window creation/event handling
   - Vulkan surface creation

3. **Graphics** (`vulkan_swapchain.zig` + new files)
   - Vulkan instance/device management
   - Swapchain and render pass
   - Command buffer handling
   - Basic rendering pipeline

4. **ECS** (`ecs_movement.zig` + new files)
   - entt registry wrapper
   - Component definitions
   - System framework

5. **Resources** (planned)
   - Texture loading/cache
   - Font loading/text rendering
   - Mesh loading (future)

6. **Physics** (`physics_solver.zig`)
   - Basic physics integration
   - Collision detection/response

### Data Flow
```
Input (SDL) → Input System → ECS (Movement/Components)
                             ↓
                     Game Logic Systems
                             ↓
                     Transform Updates
                             ↓
                     Rendering System → Vulkan GPU
                             ↓
                        Swapchain Present
```

## Extensibility Points

### Plugin Systems
- Render backends (Vulkan fallback to OpenGL planned)
- Audio systems (future)
- Networking (future)
- Scripting (future Lua/Wasm integration)

### Configuration
- Runtime configurable graphics settings
- Key binding remapping
- Graphics quality presets

## Implementation Guidelines

### Coding Standards
- Use Zig's built-in error handling (`error{}` types)
- Prefer explicit resource management over RAII where beneficial for performance
- Keep systems loosely coupled through well-defined interfaces
- Use allocators explicitly for memory control

### Performance Considerations
- Cache-friendly ECS iteration
- Minimize CPU-GPU synchronization
- Batch Vulkan operations where possible
- Object pooling for frequent allocations

## Dependencies Summary

| Dependency | Purpose | Version |
|------------|---------|---------|
| entt | ECS Framework | Latest |
| SDL3 | Window/Input | Latest |
| Vulkan | Graphics API | Latest |
| libpng | PNG Loading | Via zig-pkg |
| FreeType | Font Rendering | Via zig-pkg |
| Harfbuzz | Text Shaping | Via zig-pkg |
| zlib | Compression | Transitive |
| lsp_kit | LSP Support | Development |

## Future Enhancements
- [ ] Advanced rendering (PBR, shadows, post-processing)
- [ ] Physics engine integration (Box2D/bullet)
- [ ] Audio subsystem (OpenAL/miniaudio)
- [ ] Networking replication
- [ ] Editor tools
- [ ] Asset pipeline
- [ ] Scene graph/hierarchy system

---
*Document Version: 0.1.0*
*Last Updated: 2026-09-20*