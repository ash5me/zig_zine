# Implementation Plan for Zig Zine Engine

This document outlines an incremental development plan for building a functional ECS-based game/graphics engine using Zig, SDL3, Vulkan, and the entt library.

## Overview

The current codebase consists of minimal skeleton files with only import statements. This plan provides a phased approach to implement core engine systems, ensuring each phase delivers testable functionality.

## Phase 0: Foundation & Documentation
**Goal**: Establish clear architectural documentation and project structure

### Tasks:
- [ ] Define engine architecture in `ARCHITECTURE.md` (ECS-based with SDL3/Vulkan rendering)
- [ ] Document core systems: ECS, Rendering, Input, Resource Management, Game Logic
- [ ] Define module boundaries and interfaces
- [ ] No code changes - documentation only

### Deliverable:
- Updated `ARCHITECTURE.md` with complete architectural design

## Phase 1: Application Skeleton & Window Management
**Goal**: Create a runnable application that creates a window and enters a main loop

### Tasks:
- [ ] Implement basic application structure in `main.zig`:
  - Init/Cleanup functions
  - Main game loop with timing
  - Basic error handling
- [ ] Initialize SDL3 in `sdl_bindings.zig`:
  - Create SDL window
  - Set up OpenGL/Vulkan context (initial setup)
  - Basic event polling
- [ ] Update `build.zig` to link SDL3 properly

### Deliverable:
- Application that opens a window and can be closed cleanly
- Basic main loop running at target FPS

## Phase 2: Vulkan Integration
**Goal**: Set up Vulkan rendering context and present a clear frame

### Tasks:
- [ ] Expand `vulkan_swapchain.zig` to:
  - Initialize Vulkan instance
  - Select physical device and create logical device
  - Create swapchain
  - Set up basic render pass and framebuffers
  - Implement basic rendering loop (clear screen to color)
- [ ] Connect Vulkan initialization to SDL window

### Deliverable:
- Application that shows a colored window (cleared to specific color) using Vulkan
- Proper cleanup of Vulkan resources on exit

## Phase 3: ECS Foundation
**Goal**: Implement basic Entity Component System using entt

### Tasks:
- [ ] Create ECS module (could be in `ecs_movement.zig` or new file):
  - Initialize entt registry
  - Define basic component types (Transform, Velocity, etc.)
  - Create entity creation/destruction functions
  - Basic system framework
- [ ] Integrate ECS with main application loop

### Deliverable:
- Ability to create/query entities and components
- Basic ECS integration in main loop

## Phase 4: Basic Rendering System
**Goal**: Render simple geometry using ECS data

### Tasks:
- [ ] Create rendering components:
  - Mesh component (vertex data)
  - Material component (color/texture)
  - Transform component (position/rotation/scale)
- [ ] Implement rendering system that:
  - Processes entities with Mesh+Material+Transform
  - Sets up Vulkan pipeline
  - Issues draw calls

### Deliverable:
- Ability to render colored triangles/quads based on ECS data
- Basic transformation of rendered objects

## Phase 5: Input Handling
**Goal**: Process user input and convert to game actions

### Tasks:
- [ ] Expand `sdl_bindings.zig` to:
  - Comprehensive event handling (keyboard, mouse, gamepad)
  - Input state tracking
  - Action mapping system
- [ ] Create input components/systems in ECS:
  - InputReceiver component
  - Input processing system

### Deliverable:
- Ability to move entities via keyboard/mouse input
- Configurable input mappings

## Phase 6: Resource Management System
**Goal**: Load and manage textures, fonts, and other assets

### Tasks:
- [ ] Implement texture loading:
  - Use stb_image or similar (via zig-libpng for PNG)
  - Create texture assets in Vulkan
  - Texture sampling system
- [ ] Implement font loading:
  - Use freetype + harfbuzz for text rendering
  - Basic text rendering capability
- [ ] Create resource cache/system

### Deliverable:
- Ability to load and display textures
- Basic text rendering on screen
- Resource caching to prevent duplicate loading

## Phase 7: Physics/Basic Systems (Optional)
**Goal**: Add basic physics or gameplay systems

### Tasks:
- [ ] Expand `physics_solver.zig`:
  - Basic physics integration (position += velocity * dt)
  - Collision detection broad phase
  - Simple collision response
- [ ] Create physics system that processes ECS entities

### Deliverable:
- Entities with basic physics behavior (gravity, movement)
- Simple collision detection and response

## Phase 8: Polish & Integration
**Goal**: Refine and integrate all systems

### Tasks:
- [ ] Optimize rendering pipeline
- [ ] Improve timing and fixed time step
- [ ] Add basic scene management
- [ ] Implement basic game state (menu, playing, paused, etc.)

### Deliverable:
- Minimal viable game/demo showing core engine capabilities
- Clean shutdown and resource cleanup
- Configurable engine settings

## Implementation Notes

1. **Each phase should be completable and testable independently** - you should be able to run and verify the application after each phase
2. **Maintain clean separation of concerns** - each system (ECS, rendering, input, etc.) should have clear interfaces
3. **Error handling** - proper error checking and reporting at each stage
4. **Resource cleanup** - ensure all allocated resources are properly freed
5. **Configuration** - consider adding configuration files for window size, graphics settings, etc.

## Files to be Modified (in order)

1. `ARCHITECTURE.md` - Documentation (Phase 0)
2. `main.zig` - Application skeleton and main loop (Phase 1)
3. `sdl_bindings.zig` - SDL3 initialization and event handling (Phases 1, 5)
4. `vulkan_swapchain.zig` - Vulkan context and rendering (Phases 2, 4)
5. `ecs_movement.zig` or new ECS file - ECS implementation (Phases 3, 4, 5, 6, 7)
6. `physics_solver.zig` - Physics system (Phase 7, if implemented)
7. `build.zig` - Build configuration updates as needed
8. Possibly new files for rendering, input, resource systems

## Verification Checkpoints

After each phase, verify:
- Application compiles and runs without errors
- New functionality works as expected
- No regression in existing functionality
- Basic validation of the implemented features

## Dependencies Utilized

This plan leverages the existing dependencies in `zig-pkg/`:
- **entt**: Entity Component System
- **SDL3**: Window management and input handling
- **Vulkan**: Graphics rendering
- **libpng**: PNG image loading
- **freetype**: Font rendering
- **harfbuzz**: Text shaping
- **zlib**: Compression (used by freetype/libpng)
- **lsp_kit**: Language Server Protocol support

## Next Steps

1. Begin with Phase 0: Update `ARCHITECTURE.md` with the proposed engine architecture
2. Proceed through phases sequentially, verifying each step before moving to the next
3. Adjust the plan as needed based on discoveries during implementation