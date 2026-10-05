//
// This is a generated file, do not modify. See src/meta.odin
//

package game

// Entity System
Entity_Kind :: enum {
    Ball,
    DDGIVolume,
    Player,
    PointLight,
    ReflectionProbe,
    SoundSource,
    StaticMesh,
    Terrain,
}

register_entity_subtypes :: proc() {
    when #defined(ball_destroy) {
        register_entity_subtype(Ball, ball_destroy)
    } else {
        register_entity_subtype(Ball)
    }
    when #defined(ddgi_volume_destroy) {
        register_entity_subtype(DDGIVolume, ddgi_volume_destroy)
    } else {
        register_entity_subtype(DDGIVolume)
    }
    when #defined(player_destroy) {
        register_entity_subtype(Player, player_destroy)
    } else {
        register_entity_subtype(Player)
    }
    when #defined(point_light_destroy) {
        register_entity_subtype(PointLight, point_light_destroy)
    } else {
        register_entity_subtype(PointLight)
    }
    when #defined(reflection_probe_destroy) {
        register_entity_subtype(ReflectionProbe, reflection_probe_destroy)
    } else {
        register_entity_subtype(ReflectionProbe)
    }
    when #defined(sound_source_destroy) {
        register_entity_subtype(SoundSource, sound_source_destroy)
    } else {
        register_entity_subtype(SoundSource)
    }
    when #defined(static_mesh_destroy) {
        register_entity_subtype(StaticMesh, static_mesh_destroy)
    } else {
        register_entity_subtype(StaticMesh)
    }
    when #defined(terrain_destroy) {
        register_entity_subtype(Terrain, terrain_destroy)
    } else {
        register_entity_subtype(Terrain)
    }
}

entity_type_to_kind :: proc($T: typeid) -> Entity_Kind {
    return .Base when T == Entity else
           .Ball when T == Ball else
           .DDGIVolume when T == DDGIVolume else
           .Player when T == Player else
           .PointLight when T == PointLight else
           .ReflectionProbe when T == ReflectionProbe else
           .SoundSource when T == SoundSource else
           .StaticMesh when T == StaticMesh else
           .Terrain when T == Terrain else
           #panic("Unregistered entity type")
}


// GPUGlobalData
#assert(offset_of(GPUGlobalData, view_to_clip) == 0)
#assert(offset_of(GPUGlobalData, world_to_view) == (offset_of(GPUGlobalData, view_to_clip) + size_of(type_of(GPUGlobalData{}.view_to_clip)) + 3) / 4 * 4)
#assert(offset_of(GPUGlobalData, clip_to_world) == (offset_of(GPUGlobalData, world_to_view) + size_of(type_of(GPUGlobalData{}.world_to_view)) + 3) / 4 * 4)

// GPURenderInstance
#assert(offset_of(GPURenderInstance, model_to_world) == 0)
GeneratedAssetsType :: struct {
    audio: struct {
        ambient: struct {
            a_outdoors_birds_wav: string,
        },
        footsteps: struct {
            a_footsteps_tile_aup3: string,
            a_scuff1_wav: string,
            a_scuff2_wav: string,
            a_scuff3_wav: string,
            a_scuffs_aup3: string,
            a_step1_wav: string,
            a_step10_wav: string,
            a_step11_wav: string,
            a_step12_wav: string,
            a_step13_wav: string,
            a_step14_wav: string,
            a_step15_wav: string,
            a_step16_wav: string,
            a_step17_wav: string,
            a_step18_wav: string,
            a_step19_wav: string,
            a_step2_wav: string,
            a_step20_wav: string,
            a_step3_wav: string,
            a_step4_wav: string,
            a_step5_wav: string,
            a_step6_wav: string,
            a_step7_wav: string,
            a_step8_wav: string,
            a_step9_wav: string,
        },
    },
    fonts: struct {
        f_dm_sans_variable_ttf: string,
        f_fa_regular_400_ttf: string,
        f_momo_trust_display_regular_ttf: string,
        f_nunito_variable_ttf: string,
        f_roboto_regular_ttf: string,
        f_segoeui_ttf: string,
        gen_msdf_fonts_bat: string,
        msdf: struct {
            f_dm_sans_regular_mtsdf_json: string,
            f_dm_sans_regular_mtsdf_ktx2: string,
            f_dm_sans_regular_mtsdf_png: string,
            f_nunito_regular_mtsdf_json: string,
            f_nunito_regular_mtsdf_ktx2: string,
            f_nunito_regular_mtsdf_png: string,
            f_roboto_regular_mtsdf_json: string,
            f_roboto_regular_mtsdf_ktx2: string,
            f_roboto_regular_mtsdf_png: string,
        },
    },
    gen: struct {
        t_dfg_ktx2: string,
        t_test_cubemap_ld_ktx2: string,
        heightfields: struct {
            _7f9b375c_7d21_4473_bd08_b108def193ab_hfld: string,
            e3ccc7a4_77f9_4213_8d1d_6e357a72a21d_hfld: string,
        },
    },
    materials: struct {
        materialball2_mat: string,
        test_mat: string,
    },
    meshes: struct {
        skel: struct {
            skeltest2_blend: string,
            skeltest2_glb: string,
            sk_cube_glb: string,
            sk_cubeskel_glb: string,
            sk_materialball_glb: string,
            sk_materialball_oldy_glb: string,
            sk_skeltest2_glb: string,
        },
        static: struct {
            demo_ball_blend: string,
            demo_ball_blend1: string,
            demo_ball_glb: string,
            door_blend: string,
            door_blend1: string,
            door_glb: string,
            map_test_blend: string,
            map_test_blend1: string,
            material_ball_blend: string,
            material_ball_blend1: string,
            material_ball_glb: string,
            scene_map_test_blend: string,
            scene_map_test_blend1: string,
            scene_map_test_glb: string,
            scene_reflection_probes_glb: string,
            sm_basicmesh_glb: string,
            sm_bunny_glb: string,
            sm_bunny_max_glb: string,
            sm_bunny_old_glb: string,
            sm_cube_glb: string,
            sm_figure_glb: string,
            sm_irradiance_volume_test_glb: string,
            sm_map_blend: string,
            sm_map_blend1: string,
            sm_map_glb: string,
            sm_map_door_glb: string,
            sm_map_test_glb: string,
            sm_materialball2_glb: string,
            sm_monkey_glb: string,
            sm_skeltest_glb: string,
            sm_skybox_blend: string,
            sm_skybox_glb: string,
            sm_smooth_ball_spin_glb: string,
            sm_sphere_glb: string,
            sm_spherespin_glb: string,
            scene_map_test: struct {
                Cube_glb: string,
                Cube_001_glb: string,
                Cube_003_glb: string,
                Cube_003_9fe195dc_glb: string,
                Cube_004_glb: string,
                Cube_004_8e821e99_glb: string,
                Cube_004_8e821e99_fefb6152_glb: string,
                Cube_004_8e821e99_fefb6152_1ee52fd3_glb: string,
                Cube_004_8e821e99_fefb6152_467d0982_glb: string,
                Cube_004_8e821e99_fefb6152_5dbba8fa_glb: string,
                Cube_004_8e821e99_fefb6152_9890cf15_glb: string,
                Cube_004_e3efccf8_glb: string,
                Cube_005_glb: string,
                Cube_005_eff2ffbe_glb: string,
                Cube_006_glb: string,
                Cylinder_glb: string,
                Cylinder_4cce1abe_glb: string,
                rock_cliff_glb: string,
                rock_cliff_82a1e1e2_glb: string,
                rock_cliff_a44b3804_glb: string,
                rock_cliff_a65b96bf_glb: string,
                rock_cliff_ec02ab9f_glb: string,
                rock_cliff_f34bdbe6_glb: string,
            },
        },
    },
    textures: struct {
        t_test_basecolor_ktx2: string,
        t_test_basecolor2_ktx2: string,
        t_test_normalmap_ktx2: string,
        t_test_normalmap2_ktx2: string,
        t_test_rma_ktx2: string,
        environment: struct {
            t_ennis_ktx2: string,
            t_ennis_raw_ktx2: string,
            t_ennis_raw2_ktx2: string,
            t_ennis_small_ktx2: string,
            t_rosendal_ktx2: string,
            t_test_cubemap_ktx2: string,
            t_white_furnace_ktx2: string,
        },
        materialball2: struct {
            t_basecolor_ktx2: string,
            t_normalmap_ktx2: string,
            t_rma_ktx2: string,
        },
        tonemapping: struct {
            t_tony_mc_mapface_ktx2: string,
            t_tony_mc_mapface_unrolled_exr: string,
        },
    },
}

assets :: GeneratedAssetsType {
    audio = {
        ambient = {
            a_outdoors_birds_wav = "audio\\ambient\\a_outdoors_birds.wav",
        },
        footsteps = {
            a_footsteps_tile_aup3 = "audio\\footsteps\\a_footsteps_tile.aup3",
            a_scuff1_wav = "audio\\footsteps\\a_scuff1.wav",
            a_scuff2_wav = "audio\\footsteps\\a_scuff2.wav",
            a_scuff3_wav = "audio\\footsteps\\a_scuff3.wav",
            a_scuffs_aup3 = "audio\\footsteps\\a_scuffs.aup3",
            a_step1_wav = "audio\\footsteps\\a_step1.wav",
            a_step10_wav = "audio\\footsteps\\a_step10.wav",
            a_step11_wav = "audio\\footsteps\\a_step11.wav",
            a_step12_wav = "audio\\footsteps\\a_step12.wav",
            a_step13_wav = "audio\\footsteps\\a_step13.wav",
            a_step14_wav = "audio\\footsteps\\a_step14.wav",
            a_step15_wav = "audio\\footsteps\\a_step15.wav",
            a_step16_wav = "audio\\footsteps\\a_step16.wav",
            a_step17_wav = "audio\\footsteps\\a_step17.wav",
            a_step18_wav = "audio\\footsteps\\a_step18.wav",
            a_step19_wav = "audio\\footsteps\\a_step19.wav",
            a_step2_wav = "audio\\footsteps\\a_step2.wav",
            a_step20_wav = "audio\\footsteps\\a_step20.wav",
            a_step3_wav = "audio\\footsteps\\a_step3.wav",
            a_step4_wav = "audio\\footsteps\\a_step4.wav",
            a_step5_wav = "audio\\footsteps\\a_step5.wav",
            a_step6_wav = "audio\\footsteps\\a_step6.wav",
            a_step7_wav = "audio\\footsteps\\a_step7.wav",
            a_step8_wav = "audio\\footsteps\\a_step8.wav",
            a_step9_wav = "audio\\footsteps\\a_step9.wav",
        },
    },
    fonts = {
        f_dm_sans_variable_ttf = "fonts\\f_dm_sans_variable.ttf",
        f_fa_regular_400_ttf = "fonts\\f_fa_regular_400.ttf",
        f_momo_trust_display_regular_ttf = "fonts\\f_momo_trust_display_regular.ttf",
        f_nunito_variable_ttf = "fonts\\f_nunito_variable.ttf",
        f_roboto_regular_ttf = "fonts\\f_roboto_regular.ttf",
        f_segoeui_ttf = "fonts\\f_segoeui.ttf",
        gen_msdf_fonts_bat = "fonts\\gen_msdf_fonts.bat",
        msdf = {
            f_dm_sans_regular_mtsdf_json = "fonts\\msdf\\f_dm_sans_regular_mtsdf.json",
            f_dm_sans_regular_mtsdf_ktx2 = "fonts\\msdf\\f_dm_sans_regular_mtsdf.ktx2",
            f_dm_sans_regular_mtsdf_png = "fonts\\msdf\\f_dm_sans_regular_mtsdf.png",
            f_nunito_regular_mtsdf_json = "fonts\\msdf\\f_nunito_regular_mtsdf.json",
            f_nunito_regular_mtsdf_ktx2 = "fonts\\msdf\\f_nunito_regular_mtsdf.ktx2",
            f_nunito_regular_mtsdf_png = "fonts\\msdf\\f_nunito_regular_mtsdf.png",
            f_roboto_regular_mtsdf_json = "fonts\\msdf\\f_roboto_regular_mtsdf.json",
            f_roboto_regular_mtsdf_ktx2 = "fonts\\msdf\\f_roboto_regular_mtsdf.ktx2",
            f_roboto_regular_mtsdf_png = "fonts\\msdf\\f_roboto_regular_mtsdf.png",
        },
    },
    gen = {
        t_dfg_ktx2 = "gen\\t_dfg.ktx2",
        t_test_cubemap_ld_ktx2 = "gen\\t_test_cubemap_ld.ktx2",
        heightfields = {
            _7f9b375c_7d21_4473_bd08_b108def193ab_hfld = "gen\\heightfields\\7f9b375c-7d21-4473-bd08-b108def193ab.hfld",
            e3ccc7a4_77f9_4213_8d1d_6e357a72a21d_hfld = "gen\\heightfields\\e3ccc7a4-77f9-4213-8d1d-6e357a72a21d.hfld",
        },
    },
    materials = {
        materialball2_mat = "materials\\materialball2.mat",
        test_mat = "materials\\test.mat",
    },
    meshes = {
        skel = {
            skeltest2_blend = "meshes\\skel\\skeltest2.blend",
            skeltest2_glb = "meshes\\skel\\skeltest2.glb",
            sk_cube_glb = "meshes\\skel\\sk_cube.glb",
            sk_cubeskel_glb = "meshes\\skel\\sk_cubeskel.glb",
            sk_materialball_glb = "meshes\\skel\\sk_materialball.glb",
            sk_materialball_oldy_glb = "meshes\\skel\\sk_materialball_oldy.glb",
            sk_skeltest2_glb = "meshes\\skel\\sk_skeltest2.glb",
        },
        static = {
            demo_ball_blend = "meshes\\static\\demo_ball.blend",
            demo_ball_blend1 = "meshes\\static\\demo_ball.blend1",
            demo_ball_glb = "meshes\\static\\demo_ball.glb",
            door_blend = "meshes\\static\\door.blend",
            door_blend1 = "meshes\\static\\door.blend1",
            door_glb = "meshes\\static\\door.glb",
            map_test_blend = "meshes\\static\\map_test.blend",
            map_test_blend1 = "meshes\\static\\map_test.blend1",
            material_ball_blend = "meshes\\static\\material_ball.blend",
            material_ball_blend1 = "meshes\\static\\material_ball.blend1",
            material_ball_glb = "meshes\\static\\material_ball.glb",
            scene_map_test_blend = "meshes\\static\\scene_map_test.blend",
            scene_map_test_blend1 = "meshes\\static\\scene_map_test.blend1",
            scene_map_test_glb = "meshes\\static\\scene_map_test.glb",
            scene_reflection_probes_glb = "meshes\\static\\scene_reflection_probes.glb",
            sm_basicmesh_glb = "meshes\\static\\sm_basicmesh.glb",
            sm_bunny_glb = "meshes\\static\\sm_bunny.glb",
            sm_bunny_max_glb = "meshes\\static\\sm_bunny_max.glb",
            sm_bunny_old_glb = "meshes\\static\\sm_bunny_old.glb",
            sm_cube_glb = "meshes\\static\\sm_cube.glb",
            sm_figure_glb = "meshes\\static\\sm_figure.glb",
            sm_irradiance_volume_test_glb = "meshes\\static\\sm_irradiance_volume_test.glb",
            sm_map_blend = "meshes\\static\\sm_map.blend",
            sm_map_blend1 = "meshes\\static\\sm_map.blend1",
            sm_map_glb = "meshes\\static\\sm_map.glb",
            sm_map_door_glb = "meshes\\static\\sm_map_door.glb",
            sm_map_test_glb = "meshes\\static\\sm_map_test.glb",
            sm_materialball2_glb = "meshes\\static\\sm_materialball2.glb",
            sm_monkey_glb = "meshes\\static\\sm_monkey.glb",
            sm_skeltest_glb = "meshes\\static\\sm_skeltest.glb",
            sm_skybox_blend = "meshes\\static\\sm_skybox.blend",
            sm_skybox_glb = "meshes\\static\\sm_skybox.glb",
            sm_smooth_ball_spin_glb = "meshes\\static\\sm_smooth_ball_spin.glb",
            sm_sphere_glb = "meshes\\static\\sm_sphere.glb",
            sm_spherespin_glb = "meshes\\static\\sm_spherespin.glb",
            scene_map_test = {
                Cube_glb = "meshes\\static\\scene_map_test\\Cube.glb",
                Cube_001_glb = "meshes\\static\\scene_map_test\\Cube_001.glb",
                Cube_003_glb = "meshes\\static\\scene_map_test\\Cube_003.glb",
                Cube_003_9fe195dc_glb = "meshes\\static\\scene_map_test\\Cube_003_9fe195dc.glb",
                Cube_004_glb = "meshes\\static\\scene_map_test\\Cube_004.glb",
                Cube_004_8e821e99_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99.glb",
                Cube_004_8e821e99_fefb6152_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99_fefb6152.glb",
                Cube_004_8e821e99_fefb6152_1ee52fd3_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99_fefb6152_1ee52fd3.glb",
                Cube_004_8e821e99_fefb6152_467d0982_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99_fefb6152_467d0982.glb",
                Cube_004_8e821e99_fefb6152_5dbba8fa_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99_fefb6152_5dbba8fa.glb",
                Cube_004_8e821e99_fefb6152_9890cf15_glb = "meshes\\static\\scene_map_test\\Cube_004_8e821e99_fefb6152_9890cf15.glb",
                Cube_004_e3efccf8_glb = "meshes\\static\\scene_map_test\\Cube_004_e3efccf8.glb",
                Cube_005_glb = "meshes\\static\\scene_map_test\\Cube_005.glb",
                Cube_005_eff2ffbe_glb = "meshes\\static\\scene_map_test\\Cube_005_eff2ffbe.glb",
                Cube_006_glb = "meshes\\static\\scene_map_test\\Cube_006.glb",
                Cylinder_glb = "meshes\\static\\scene_map_test\\Cylinder.glb",
                Cylinder_4cce1abe_glb = "meshes\\static\\scene_map_test\\Cylinder_4cce1abe.glb",
                rock_cliff_glb = "meshes\\static\\scene_map_test\\rock_cliff.glb",
                rock_cliff_82a1e1e2_glb = "meshes\\static\\scene_map_test\\rock_cliff_82a1e1e2.glb",
                rock_cliff_a44b3804_glb = "meshes\\static\\scene_map_test\\rock_cliff_a44b3804.glb",
                rock_cliff_a65b96bf_glb = "meshes\\static\\scene_map_test\\rock_cliff_a65b96bf.glb",
                rock_cliff_ec02ab9f_glb = "meshes\\static\\scene_map_test\\rock_cliff_ec02ab9f.glb",
                rock_cliff_f34bdbe6_glb = "meshes\\static\\scene_map_test\\rock_cliff_f34bdbe6.glb",
            },
        },
    },
    textures = {
        t_test_basecolor_ktx2 = "textures\\t_test_basecolor.ktx2",
        t_test_basecolor2_ktx2 = "textures\\t_test_basecolor2.ktx2",
        t_test_normalmap_ktx2 = "textures\\t_test_normalmap.ktx2",
        t_test_normalmap2_ktx2 = "textures\\t_test_normalmap2.ktx2",
        t_test_rma_ktx2 = "textures\\t_test_rma.ktx2",
        environment = {
            t_ennis_ktx2 = "textures\\environment\\t_ennis.ktx2",
            t_ennis_raw_ktx2 = "textures\\environment\\t_ennis_raw.ktx2",
            t_ennis_raw2_ktx2 = "textures\\environment\\t_ennis_raw2.ktx2",
            t_ennis_small_ktx2 = "textures\\environment\\t_ennis_small.ktx2",
            t_rosendal_ktx2 = "textures\\environment\\t_rosendal.ktx2",
            t_test_cubemap_ktx2 = "textures\\environment\\t_test_cubemap.ktx2",
            t_white_furnace_ktx2 = "textures\\environment\\t_white_furnace.ktx2",
        },
        materialball2 = {
            t_basecolor_ktx2 = "textures\\materialball2\\t_basecolor.ktx2",
            t_normalmap_ktx2 = "textures\\materialball2\\t_normalmap.ktx2",
            t_rma_ktx2 = "textures\\materialball2\\t_rma.ktx2",
        },
        tonemapping = {
            t_tony_mc_mapface_ktx2 = "textures\\tonemapping\\t_tony_mc_mapface.ktx2",
            t_tony_mc_mapface_unrolled_exr = "textures\\tonemapping\\t_tony_mc_mapface_unrolled.exr",
        },
    },
}
