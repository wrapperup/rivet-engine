# rivet
<img width="3759" height="2131" alt="main_9dwZZzDbtY" src="https://github.com/user-attachments/assets/bfd39332-85e3-4063-bf08-e2367b914d41" />

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
- Physics (with Box3D, vendored in Odin)

### Renderer Features
- DDGI (requires hardware raytracing)
- Parallax-Corrected Cubemaps
- PBR + IBL + HDR based on [Filament](https://google.github.io/filament/Filament.md.html)
- Point lights
- Tonemapping (tony-mc-mapface)
- Cascaded Shadow Maps
- Compute skinning
- Opaque depth prepass (shared mesh vertex shader, followed by depth-equal shading)
- Sky Atmosphere (based on [Sébastien Hillaire's Sky Atmosphere Model](https://github.com/sebh/UnrealEngineSkyAtmosphere))

## How to build:
1. Clone repo
2. Run `git submodule update --init --recursive` to get submodules.
3. Run `build.bat` to generate `build/debug/main.exe`. Or `build.bat 1` to generate a release build in `build/release/main.exe`.

### Screenshots
<img width="3759" height="2131" alt="main_gff4WfdCmB" src="https://github.com/user-attachments/assets/513254a6-45c7-4669-98c9-57bebab58da9" />
<img width="3759" height="2131" alt="main_A3ZfymFy7W" src="https://github.com/user-attachments/assets/c17a5a22-da37-4777-a1a6-5ef35596a541" />
<img width="1920" height="1080" alt="main_4LlDygenEN" src="https://github.com/user-attachments/assets/6e251e31-96ba-4384-8467-207e6448366c" />

Some debug views for DDGI and cubemaps
<img width="3759" height="2131" alt="image" src="https://github.com/user-attachments/assets/46d50aff-d600-4e66-8626-954fb15a29e2" />
<img width="3759" height="2131" alt="image" src="https://github.com/user-attachments/assets/8cb08919-52d9-436c-a75b-c2dcaa798a7d" />


## Dependencies

 All the dependencies for this project are included as git submodules.
 
 - [odin-imgui](https://gitlab.com/L-4/odin-imgui)
 - [odin-libktx](https://github.com/DanielGavin/odin-libktx)
 - [odin-mikktspace](https://github.com/wrapperup/odin-mikktspace)
 - [odin-slang](https://github.com/DragosPopse/odin-slang)
 - [odin-vma](https://github.com/DanielGavin/odin-vma)
 - [glTF2](https://github.com/Pawel82S/glTF2)
 - [odin_livepatch](https://github.com/MatzeOGH/odin_livepatch)
