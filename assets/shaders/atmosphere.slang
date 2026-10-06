import atmosphere_common;
import common;
import bindless;
import types;

[vk_push_constant]
AtmosphereDrawPush pc;
struct SkyVertex {
  Vec4 pos : SV_Position;
  Vec2 uv : TEXCOORD0;
};

[shader("vertex")]
SkyVertex vertex_main(u32 id : SV_VertexID) {
  SkyVertex v;
  v.uv = Vec2((id << 1) & 2, id & 2);
  v.pos = Vec4(v.uv * 2 - 1, 1, 1);
  return v;
}
[shader("fragment")]
Vec4 fragment_main(SkyVertex v) : SV_Target0 {
  Vec3 dir = atmosphere_view_ray(pc.global, v.uv);
  Vec3 L = atmosphere_sky(pc.global, dir) * pc.global.sky_color;
  Vec3 origin = Vec3(0, ATM_GROUND + pc.global.atmosphere.camera_height, 0);
  f32 cos_angle = dot(dir, pc.global.sun_direction);
  f32 disk_edge = cos(pc.global.atmosphere.sun_radius / 2.f);
  f32 aa = max(fwidth(cos_angle), 1e-7);
  f32 disk = smoothstep(disk_edge - aa, disk_edge + aa, cos_angle);
  if (atmosphere_ground_distance(origin, dir) < 0 && disk > 0) {
    f32 solid_angle = 2 * ATM_PI * (1 - disk_edge);
    L += disk * pc.global.sun_color *
         atmosphere_sun_transmittance(pc.global.atmosphere, origin, dir) /
         max(solid_angle, 1e-6);
  }
  return Vec4(L, 1);
}
