// DDGI, derived from:
//
// Majercik, Guertin, Nowrouzezahrai, McGuire. "Dynamic Diffuse Global Illumination with Ray-Traced
// Irradiance Fields". https://jcgt.org/published/0008/02/01/
// Majercik, Marrs, Spjut, McGuire. "Scaling Probe-Based Real-Time Dynamic Global Illumination for
// Production". https://jcgt.org/published/0010/02/01/
//
// Original source code: (https://jcgt.org/published/0010/02/01/supplement.zip)

import bindless;
import common;
import types;
import ddgi_common;

[vk_push_constant]
DDGIProbePush pc;

struct V2F {
  Vec4 pos_cs : SV_Position;
  Vec3 sample_direction;
  float edge_proximity_scale_factor;
  nointerpolation int3 probe_grid_coord : PROBE;
};

// DDGIVolume_probeVisualization.vrt
[shader("vertex")]
V2F vertex_main(uint vid: SV_VertexID, uint iid: SV_InstanceID) {
  let ddgi_volume = pc.volume[0];
  Vec3 vertex = pc.vertex_buffer[vid].position;
  Vec3 camera_ws_position = pc.global.camera_pos;
  let world_to_clip = mul(pc.global.view_to_clip, pc.global.world_to_view);

  V2F o;
  Vec3 probe_loc = ddgi_probe_location(ddgi_volume, iid);
  o.pos_cs = mul(world_to_clip, Vec4((normalize(vertex) * pc.probe_radius) + probe_loc, 1.0));
  o.sample_direction = normalize(vertex);
  o.edge_proximity_scale_factor = abs(dot(o.sample_direction, normalize(probe_loc - camera_ws_position)));
  o.probe_grid_coord = ddgi_probe_index_to_grid_coord(ddgi_volume, iid);
  return o;
}

static const Vec3 OFF_COLOR           = Vec3(0, 0, 0);           // Black (Off)
static const Vec3 ASLEEP_COLOR        = Vec3(0.06f, 0.02f, 0);   // Brown (Sleeping)
static const Vec3 JUST_WOKE_COLOR     = Vec3(1, 0, 1);           // Magenta (Newly Awake)
static const Vec3 AWAKE_COLOR         = Vec3(1, 1, 0.1);         // Yellow (Awake)
static const Vec3 JUST_VIGILANT_COLOR = Vec3(1, 0, 0);           // Red (Newly Vigilant)
static const Vec3 VIGILANT_COLOR      = Vec3(0, 1, 0);           // Green (Vigilant)
static const Vec3 UNINITIALIZED_COLOR = Vec3(0,1,1);             // Cyan (Uninitialized)

// DDGIVolume/DDGIVolume_probeVisualization.pix
[shader("fragment")]
Vec4 fragment_main(V2F i) : SV_Target {
  let ddgi_volume = pc.volume[0];
  Vec2 tex_coord;
  Vec3 color;

  {
    tex_coord = ddgi_probe_texture_coord_from_direction(normalize(i.sample_direction), i.probe_grid_coord, true, ddgi_volume);
    color = max(ddgi_volume.irradiance.sample_level(ddgi_volume.sampler, tex_coord, 0).rgb, Vec3(0));

    // Decode
    color = pow(color, Vec3(DDGI_IRRADIANCE_GAMMA));

    // Needed to match surface intensity
    // Deviation: not needed, since sampling doesn't apply the 0.5 * pi factor either.
  }

  // Color the edge of the probe based on the state
  if (i.edge_proximity_scale_factor < 0.55f) {
    // Apply per-probe position offset
    int state = int(ddgi_read_probe_offset(ddgi_volume, ddgi_probe_tile(ddgi_volume, i.probe_grid_coord)).w);

    if      (state == STATE_OFF)            {  color = OFF_COLOR;          }
    else if (state == STATE_ASLEEP)         {  color = ASLEEP_COLOR;       }
    else if (state == STATE_JUST_WOKE)      {  color = JUST_WOKE_COLOR;    }
    else if (state == STATE_AWAKE)          {  color = AWAKE_COLOR;        }
    else if (state == STATE_JUST_VIGILANT)  {  color = JUST_VIGILANT_COLOR;}
    else if (state == STATE_VIGILANT)       {  color = VIGILANT_COLOR;     }
    else if (state == STATE_UNINITIALIZED)  {  color = UNINITIALIZED_COLOR;}
  }

  return Vec4(color, 1.0); // linear; tonemapped by post-processing
}
