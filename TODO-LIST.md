# Things to do

## Usability
- [x] Window resizing / minimizing
- [x] Full screen toggle

## Shaders
- [x] Bindless solution
- [x] Generate shared types

## Entity System
- [x] Deleting untyped/raw entity and it's subtype via reflection (for ed/debug)

## General
- [ ] Fixed ticks for everything
- [ ] Asset system
- - [ ] Move away from asset enum
- - [ ] File-based

## Scene management
- [x] Switch to Odin-native gltf2 library? (to make custom ext's cleaner)
- [ ] Load entire scene from gltf
- - [ ] Static Meshes
- - [ ] Punctual lights
- - [ ] Irradiance Volumes
- - [ ] Map and load assets
- - [ ] Hot reload

## Graphics
- [x] Make shadow map follow camera
- [x] Shadow Cascades
- [x] DDGI
- - [x] Realtime Viz
- - [ ] Offline Baking
- [ ] Render Pass Abstraction
- [ ] Render Graph

## Blender/gltf scenes
- [ ] Entities
- [ ] Hotreload assets / scenes

## Cleanup
- [ ] Destroy old swapchains
- [x] Cleanup renderer
- - [x] Window should just be handled by the renderer? messy...
- - [x] Combine init functions (it's fragmented to like 100 functions bruh)
- - [x] Bindless system should be part of core GFX
