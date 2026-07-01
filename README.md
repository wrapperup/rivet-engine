# cool engine
<img width="1920" height="1080" alt="main_Y3MUECBmx6" src="https://github.com/user-attachments/assets/824cd11a-6dfe-4620-b618-3aa16cbf3194" />


Toy engine + Vulkan renderer I built for fun to learn Odin language (and some graphics techniques).

### Features
- Fully written by hand (Fuck off Claude). Wow so special.
- Sparse entity system (ECS-like)
- First person player controller based on Unreal character movement
- Skeletal meshes and animation
- Bindless System (see `shaders/tonemapping.slang` for a simple example!)
- - Bindless versions of `Texture*`, `SamplerState` and `SamplerComparisonState`, while keeping the usage the same.
- - Buffers use BDA
- Metaprogram to generate assets tables and shader glue code
- glTF loading of meshes and skeletal meshes
- Physics (with Physx 5.1)

### Renderer Features
- DDGI (requires hardware raytracing)
- Parallax-Corrected Cubemaps
- PBR + IBL + HDR based on [Filament](https://google.github.io/filament/Filament.md.html)
- Point lights
- Tonemapping (tony-mc-mapface)
- Very Crude Text Rendering
- CSM
- Compute skinning
- Tools for baking IBL (irradiance SH and specular cubemaps)

## How to build:
1. Clone repo
2. Run `setup.bat` once (this will download some large PhysX binaries and ensure submodules are up to date)
3. Run `build.bat` to generate `build/debug/main.exe`

### Screenshots
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/e65f6132-fe8c-404a-999d-b757c266a109" />

## Dependencies

 All the dependencies for this project are included as git submodules.
 
 - [odin-imgui](https://gitlab.com/L-4/odin-imgui)
 - [odin-libktx](https://github.com/DanielGavin/odin-libktx)
 - [odin-mikktspace](https://github.com/wrapperup/odin-mikktspace)
 - [odin-slang](https://github.com/DragosPopse/odin-slang)
 - [odin-vma](https://github.com/DanielGavin/odin-vma)
 - [physx-odin](https://github.com/tgolsson/physx-odin)
