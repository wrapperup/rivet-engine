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
DDGIUpdatePush pc;

// DDGIVolume/DDGIVolume_copyProbeEdges.glc
// Deviation: one group per probe sized to the visibility probe. Each thread copies its visibility texel and, if it
// falls inside the smaller irradiance probe, its irradiance texel (the reference packs 2x2-probe blocks into 8x4 groups).
[numthreads(DDGI_VISIBILITY_PROBE_SIDE_LENGTH + 2, DDGI_VISIBILITY_PROBE_SIDE_LENGTH + 2, 1)]
[shader("compute")]
void compute_main(uint3 group_id: SV_GroupID, uint3 thread_id: SV_GroupThreadID) {
  DDGIVolume ddgi_volume = pc.volume[0];
  int probe_index = int(group_id.x);
  if (probe_index >= ddgi_num_probes(ddgi_volume)) {
    return;
  }

  int2 probe_tile = ddgi_probe_tile(ddgi_volume, ddgi_probe_index_to_grid_coord(ddgi_volume, probe_index));

  // Compute the oct frag coord with (0,0) as the top left of the border
  int2 oct_frag_coord = int2(thread_id.xy);

  if (all(oct_frag_coord < DDGI_IRRADIANCE_PROBE_SIDE_LENGTH + 2)) {
    copy_probe_edge(pc.irradiance, probe_tile * (DDGI_IRRADIANCE_PROBE_SIDE_LENGTH + 2), oct_frag_coord, DDGI_IRRADIANCE_PROBE_SIDE_LENGTH);
  }
  copy_probe_edge(pc.visibility, probe_tile * (DDGI_VISIBILITY_PROBE_SIDE_LENGTH + 2), oct_frag_coord, DDGI_VISIBILITY_PROBE_SIDE_LENGTH);
}

void copy_probe_edge(RWImage2D image, int2 probe_corner, int2 oct_frag_coord, int probe_side_length) {
  Vec2 oct_coord = Vec2(oct_frag_coord);

  // Deviation: skip interior texels.
  if (all(oct_coord > 0) && all(oct_coord < probe_side_length + 1)) {
    return;
  }

  int2 texel_coord = probe_corner + oct_frag_coord;

  int2 probe_side_with_border_length = int2(probe_side_length + 1);

  // Rescale all border texels to have the correct
  // offset along their side.
  int2 read_offset = int2(-2 * oct_coord) + probe_side_with_border_length;

  // Set only the corner texels to sample from the opposite corner.
  // Note that only the corner texels will have offsets with
  // equal absolute value.
  if (abs(read_offset.x) == abs(read_offset.y)) {
    read_offset = sign(read_offset) * probe_side_length;
  }

  // Set border (not corner) texels to have the correct offset
  // from their side into the valid texels (i.e., 1 or -1). Note that
  // the body if this IF statement differs from the one above.
  if (abs(read_offset.x) == probe_side_with_border_length.x) {
    read_offset.x = sign(read_offset.x);
  }

  if (abs(read_offset.y) == probe_side_with_border_length.y) {
    read_offset.y = sign(read_offset.y);
  }

  image.store(texel_coord, image.load(texel_coord + read_offset));
}
