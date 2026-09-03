//
// This is a generated file, do not modify. See src/meta.odin
//

package game

// Assets
Asset_Name :: enum {
    f_fa_regular_400,
    f_roboto_regular,
    f_segoeui,
    t_dfg,
    t_test_cubemap_ld,
    t_test_basecolor,
    t_test_basecolor2,
    t_test_normalmap,
    t_test_normalmap2,
    t_test_rma,
    a_outdoors_birds,
    a_scuff1,
    a_scuff2,
    a_scuff3,
    a_step1,
    a_step10,
    a_step11,
    a_step12,
    a_step13,
    a_step14,
    a_step15,
    a_step16,
    a_step17,
    a_step18,
    a_step19,
    a_step2,
    a_step20,
    a_step3,
    a_step4,
    a_step5,
    a_step6,
    a_step7,
    a_step8,
    a_step9,
    skeltest2,
    sk_cube,
    sk_cubeskel,
    sk_materialball,
    sk_materialball_oldy,
    sk_skeltest2,
    demo_ball,
    door,
    material_ball,
    scene_map_test,
    scene_reflection_probes,
    sm_basicmesh,
    sm_bunny,
    sm_bunny_max,
    sm_bunny_old,
    sm_cube,
    sm_figure,
    sm_irradiance_volume_test,
    sm_map,
    sm_map_door,
    sm_map_test,
    sm_materialball2,
    sm_monkey,
    sm_skeltest,
    sm_skybox,
    sm_smooth_ball_spin,
    sm_sphere,
    sm_spherespin,
    t_ennis,
    t_ennis_raw,
    t_ennis_raw2,
    t_ennis_small,
    t_rosendal,
    t_test_cubemap,
    t_white_furnace,
    t_basecolor,
    t_normalmap,
    t_rma,
    t_tony_mc_mapface,
    Cube,
    Cube_001,
    Cube_003,
    Cube_003_9fe195dc,
    Cube_004,
    Cube_004_8e821e99,
    Cube_004_8e821e99_fefb6152,
    Cube_004_8e821e99_fefb6152_1ee52fd3,
    Cube_004_8e821e99_fefb6152_467d0982,
    Cube_004_8e821e99_fefb6152_5dbba8fa,
    Cube_004_8e821e99_fefb6152_9890cf15,
    Cube_004_e3efccf8,
    Cube_005,
    Cube_005_eff2ffbe,
    Cube_006,
    Cylinder,
    Cylinder_4cce1abe,
    rock_cliff,
    rock_cliff_82a1e1e2,
    rock_cliff_a44b3804,
    rock_cliff_a65b96bf,
    rock_cliff_ec02ab9f,
    rock_cliff_f34bdbe6,
}

load_generated_assets :: proc() -> bool {
    game.asset_system.assets[.f_fa_regular_400] = load_asset("assets/fonts/f_fa_regular_400.ttf") or_return
    game.asset_system.assets[.f_roboto_regular] = load_asset("assets/fonts/f_roboto_regular.ttf") or_return
    game.asset_system.assets[.f_segoeui] = load_asset("assets/fonts/f_segoeui.ttf") or_return
    game.asset_system.assets[.t_dfg] = load_asset("assets/gen/t_dfg.ktx2") or_return
    game.asset_system.assets[.t_test_cubemap_ld] = load_asset("assets/gen/t_test_cubemap_ld.ktx2") or_return
    game.asset_system.assets[.t_test_basecolor] = load_asset("assets/textures/t_test_basecolor.ktx2") or_return
    game.asset_system.assets[.t_test_basecolor2] = load_asset("assets/textures/t_test_basecolor2.ktx2") or_return
    game.asset_system.assets[.t_test_normalmap] = load_asset("assets/textures/t_test_normalmap.ktx2") or_return
    game.asset_system.assets[.t_test_normalmap2] = load_asset("assets/textures/t_test_normalmap2.ktx2") or_return
    game.asset_system.assets[.t_test_rma] = load_asset("assets/textures/t_test_rma.ktx2") or_return
    game.asset_system.assets[.a_outdoors_birds] = load_asset("assets/audio/ambient/a_outdoors_birds.wav") or_return
    game.asset_system.assets[.a_scuff1] = load_asset("assets/audio/footsteps/a_scuff1.wav") or_return
    game.asset_system.assets[.a_scuff2] = load_asset("assets/audio/footsteps/a_scuff2.wav") or_return
    game.asset_system.assets[.a_scuff3] = load_asset("assets/audio/footsteps/a_scuff3.wav") or_return
    game.asset_system.assets[.a_step1] = load_asset("assets/audio/footsteps/a_step1.wav") or_return
    game.asset_system.assets[.a_step10] = load_asset("assets/audio/footsteps/a_step10.wav") or_return
    game.asset_system.assets[.a_step11] = load_asset("assets/audio/footsteps/a_step11.wav") or_return
    game.asset_system.assets[.a_step12] = load_asset("assets/audio/footsteps/a_step12.wav") or_return
    game.asset_system.assets[.a_step13] = load_asset("assets/audio/footsteps/a_step13.wav") or_return
    game.asset_system.assets[.a_step14] = load_asset("assets/audio/footsteps/a_step14.wav") or_return
    game.asset_system.assets[.a_step15] = load_asset("assets/audio/footsteps/a_step15.wav") or_return
    game.asset_system.assets[.a_step16] = load_asset("assets/audio/footsteps/a_step16.wav") or_return
    game.asset_system.assets[.a_step17] = load_asset("assets/audio/footsteps/a_step17.wav") or_return
    game.asset_system.assets[.a_step18] = load_asset("assets/audio/footsteps/a_step18.wav") or_return
    game.asset_system.assets[.a_step19] = load_asset("assets/audio/footsteps/a_step19.wav") or_return
    game.asset_system.assets[.a_step2] = load_asset("assets/audio/footsteps/a_step2.wav") or_return
    game.asset_system.assets[.a_step20] = load_asset("assets/audio/footsteps/a_step20.wav") or_return
    game.asset_system.assets[.a_step3] = load_asset("assets/audio/footsteps/a_step3.wav") or_return
    game.asset_system.assets[.a_step4] = load_asset("assets/audio/footsteps/a_step4.wav") or_return
    game.asset_system.assets[.a_step5] = load_asset("assets/audio/footsteps/a_step5.wav") or_return
    game.asset_system.assets[.a_step6] = load_asset("assets/audio/footsteps/a_step6.wav") or_return
    game.asset_system.assets[.a_step7] = load_asset("assets/audio/footsteps/a_step7.wav") or_return
    game.asset_system.assets[.a_step8] = load_asset("assets/audio/footsteps/a_step8.wav") or_return
    game.asset_system.assets[.a_step9] = load_asset("assets/audio/footsteps/a_step9.wav") or_return
    game.asset_system.assets[.skeltest2] = load_asset("assets/meshes/skel/skeltest2.glb") or_return
    game.asset_system.assets[.sk_cube] = load_asset("assets/meshes/skel/sk_cube.glb") or_return
    game.asset_system.assets[.sk_cubeskel] = load_asset("assets/meshes/skel/sk_cubeskel.glb") or_return
    game.asset_system.assets[.sk_materialball] = load_asset("assets/meshes/skel/sk_materialball.glb") or_return
    game.asset_system.assets[.sk_materialball_oldy] = load_asset("assets/meshes/skel/sk_materialball_oldy.glb") or_return
    game.asset_system.assets[.sk_skeltest2] = load_asset("assets/meshes/skel/sk_skeltest2.glb") or_return
    game.asset_system.assets[.demo_ball] = load_asset("assets/meshes/static/demo_ball.glb") or_return
    game.asset_system.assets[.door] = load_asset("assets/meshes/static/door.glb") or_return
    game.asset_system.assets[.material_ball] = load_asset("assets/meshes/static/material_ball.glb") or_return
    game.asset_system.assets[.scene_map_test] = load_asset("assets/meshes/static/scene_map_test.glb") or_return
    game.asset_system.assets[.scene_reflection_probes] = load_asset("assets/meshes/static/scene_reflection_probes.glb") or_return
    game.asset_system.assets[.sm_basicmesh] = load_asset("assets/meshes/static/sm_basicmesh.glb") or_return
    game.asset_system.assets[.sm_bunny] = load_asset("assets/meshes/static/sm_bunny.glb") or_return
    game.asset_system.assets[.sm_bunny_max] = load_asset("assets/meshes/static/sm_bunny_max.glb") or_return
    game.asset_system.assets[.sm_bunny_old] = load_asset("assets/meshes/static/sm_bunny_old.glb") or_return
    game.asset_system.assets[.sm_cube] = load_asset("assets/meshes/static/sm_cube.glb") or_return
    game.asset_system.assets[.sm_figure] = load_asset("assets/meshes/static/sm_figure.glb") or_return
    game.asset_system.assets[.sm_irradiance_volume_test] = load_asset("assets/meshes/static/sm_irradiance_volume_test.glb") or_return
    game.asset_system.assets[.sm_map] = load_asset("assets/meshes/static/sm_map.glb") or_return
    game.asset_system.assets[.sm_map_door] = load_asset("assets/meshes/static/sm_map_door.glb") or_return
    game.asset_system.assets[.sm_map_test] = load_asset("assets/meshes/static/sm_map_test.glb") or_return
    game.asset_system.assets[.sm_materialball2] = load_asset("assets/meshes/static/sm_materialball2.glb") or_return
    game.asset_system.assets[.sm_monkey] = load_asset("assets/meshes/static/sm_monkey.glb") or_return
    game.asset_system.assets[.sm_skeltest] = load_asset("assets/meshes/static/sm_skeltest.glb") or_return
    game.asset_system.assets[.sm_skybox] = load_asset("assets/meshes/static/sm_skybox.glb") or_return
    game.asset_system.assets[.sm_smooth_ball_spin] = load_asset("assets/meshes/static/sm_smooth_ball_spin.glb") or_return
    game.asset_system.assets[.sm_sphere] = load_asset("assets/meshes/static/sm_sphere.glb") or_return
    game.asset_system.assets[.sm_spherespin] = load_asset("assets/meshes/static/sm_spherespin.glb") or_return
    game.asset_system.assets[.t_ennis] = load_asset("assets/textures/environment/t_ennis.ktx2") or_return
    game.asset_system.assets[.t_ennis_raw] = load_asset("assets/textures/environment/t_ennis_raw.ktx2") or_return
    game.asset_system.assets[.t_ennis_raw2] = load_asset("assets/textures/environment/t_ennis_raw2.ktx2") or_return
    game.asset_system.assets[.t_ennis_small] = load_asset("assets/textures/environment/t_ennis_small.ktx2") or_return
    game.asset_system.assets[.t_rosendal] = load_asset("assets/textures/environment/t_rosendal.ktx2") or_return
    game.asset_system.assets[.t_test_cubemap] = load_asset("assets/textures/environment/t_test_cubemap.ktx2") or_return
    game.asset_system.assets[.t_white_furnace] = load_asset("assets/textures/environment/t_white_furnace.ktx2") or_return
    game.asset_system.assets[.t_basecolor] = load_asset("assets/textures/materialball2/t_basecolor.ktx2") or_return
    game.asset_system.assets[.t_normalmap] = load_asset("assets/textures/materialball2/t_normalmap.ktx2") or_return
    game.asset_system.assets[.t_rma] = load_asset("assets/textures/materialball2/t_rma.ktx2") or_return
    game.asset_system.assets[.t_tony_mc_mapface] = load_asset("assets/textures/tonemapping/t_tony_mc_mapface.ktx2") or_return
    game.asset_system.assets[.Cube] = load_asset("assets/meshes/static/scene_map_test/Cube.glb") or_return
    game.asset_system.assets[.Cube_001] = load_asset("assets/meshes/static/scene_map_test/Cube_001.glb") or_return
    game.asset_system.assets[.Cube_003] = load_asset("assets/meshes/static/scene_map_test/Cube_003.glb") or_return
    game.asset_system.assets[.Cube_003_9fe195dc] = load_asset("assets/meshes/static/scene_map_test/Cube_003_9fe195dc.glb") or_return
    game.asset_system.assets[.Cube_004] = load_asset("assets/meshes/static/scene_map_test/Cube_004.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99_fefb6152] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99_fefb6152.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99_fefb6152_1ee52fd3] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99_fefb6152_1ee52fd3.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99_fefb6152_467d0982] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99_fefb6152_467d0982.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99_fefb6152_5dbba8fa] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99_fefb6152_5dbba8fa.glb") or_return
    game.asset_system.assets[.Cube_004_8e821e99_fefb6152_9890cf15] = load_asset("assets/meshes/static/scene_map_test/Cube_004_8e821e99_fefb6152_9890cf15.glb") or_return
    game.asset_system.assets[.Cube_004_e3efccf8] = load_asset("assets/meshes/static/scene_map_test/Cube_004_e3efccf8.glb") or_return
    game.asset_system.assets[.Cube_005] = load_asset("assets/meshes/static/scene_map_test/Cube_005.glb") or_return
    game.asset_system.assets[.Cube_005_eff2ffbe] = load_asset("assets/meshes/static/scene_map_test/Cube_005_eff2ffbe.glb") or_return
    game.asset_system.assets[.Cube_006] = load_asset("assets/meshes/static/scene_map_test/Cube_006.glb") or_return
    game.asset_system.assets[.Cylinder] = load_asset("assets/meshes/static/scene_map_test/Cylinder.glb") or_return
    game.asset_system.assets[.Cylinder_4cce1abe] = load_asset("assets/meshes/static/scene_map_test/Cylinder_4cce1abe.glb") or_return
    game.asset_system.assets[.rock_cliff] = load_asset("assets/meshes/static/scene_map_test/rock_cliff.glb") or_return
    game.asset_system.assets[.rock_cliff_82a1e1e2] = load_asset("assets/meshes/static/scene_map_test/rock_cliff_82a1e1e2.glb") or_return
    game.asset_system.assets[.rock_cliff_a44b3804] = load_asset("assets/meshes/static/scene_map_test/rock_cliff_a44b3804.glb") or_return
    game.asset_system.assets[.rock_cliff_a65b96bf] = load_asset("assets/meshes/static/scene_map_test/rock_cliff_a65b96bf.glb") or_return
    game.asset_system.assets[.rock_cliff_ec02ab9f] = load_asset("assets/meshes/static/scene_map_test/rock_cliff_ec02ab9f.glb") or_return
    game.asset_system.assets[.rock_cliff_f34bdbe6] = load_asset("assets/meshes/static/scene_map_test/rock_cliff_f34bdbe6.glb") or_return
    return true
}

// GPUGlobalData
#assert(offset_of(GPUGlobalData, view_to_clip) == 0)
#assert(offset_of(GPUGlobalData, world_to_view) == (offset_of(GPUGlobalData, view_to_clip) + size_of(type_of(GPUGlobalData{}.view_to_clip)) + 3) / 4 * 4)
#assert(offset_of(GPUGlobalData, clip_to_world) == (offset_of(GPUGlobalData, world_to_view) + size_of(type_of(GPUGlobalData{}.world_to_view)) + 3) / 4 * 4)
