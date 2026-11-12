# Status

Every public function, type, option and extension of cgltf 1.15 (commit
`85cd623`, vendored unchanged in `reference/cgltf/` for the tests and the
benchmark only), and its state:

- **not started**;
- **ported**: translated;
- **oracle-tested**: tests run the original and the port on the same
  inputs and compare every field, string byte, index and float bit;
- **benchmarked**: timed against the original by `zig build bench`;
- **reviewed**: a reviewer that did not write the port has tried to break
  it.

## Work state

Written to resume from: the next agent reads this section and `git log`.

- Step 1 (pin): done. `reference/cgltf/` is upstream's tree at `85cd623`,
  byte for byte. The Khronos sample models are a lazy dependency at
  `8f49239`.
- Step 2 (inventory): this file.
- Step 3 (port): every function is written and the unit tests pass
  (`zig test src/cgltf.zig`). `build.zig` builds the original from
  `reference/shim/cgltf.c` and translates `cgltf.h` for the differential
  tests. Not yet written: `test/differential.zig` and the tests under it,
  `bench/bench.zig`.
- Steps 4 to 7: not started.

Next steps, in order: differential tests over every sample model;
edge cases; fuzzing; benchmark; docs; step-4 report; then the performance
pass, the skeptic and the fixes on branch `review/perf-and-skeptic`.

## Parsing

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_parse` (glTF and GLB from memory) | `parse` | | ported |
| `cgltf_parse_file` | `parseFile` | | ported |
| `cgltf_options.json_token_count` | `Options.json_token_count` | | ported |
| `cgltf_options.memory` (alloc and free callbacks) | an `std.mem.Allocator` | | ported |
| `cgltf_options.file` (read and release callbacks) | `Options.file_reader` | | ported |
| `cgltf_options.type` (auto, gltf, glb) | `Options.file_type` | | ported |
| `cgltf_free` | `Gltf.deinit` | | ported |
| jsmn (strict, parent links) | `jsmn.zig` | | ported |
| C's `atoi`, `atoll`, `atof` as cgltf reads numbers | `number.zig` | | ported |
| glTF 1.0 detection (`cgltf_result_legacy_gltf`) | `error.LegacyGltf` | | ported |
| extras as JSON offsets and text | `Extras` | | ported |
| unknown extensions as name and JSON | `Extension` | | ported |
| `extensionsUsed`, `extensionsRequired` | `extensions_used`, `extensions_required` | | ported |
| reference fixup (`cgltf_fixup_pointers`) | indices checked against their arrays | | ported |

## Loading and checking

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_load_buffers` (files, data URIs, GLB chunk) | `loadBuffers` | | ported |
| `cgltf_load_buffer_base64` | `loadBufferBase64` | | ported |
| `cgltf_decode_string` | `decodeString` | | ported |
| `cgltf_decode_uri` | `decodeUri` | | ported |
| `cgltf_validate` | `validate` | | ported |
| `cgltf_copy_extras_json` (deprecated) | `copyExtrasJson` | | ported |

## Accessors, views and nodes

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_accessor_read_float` | `readFloat` | | ported |
| `cgltf_accessor_read_uint` | `readUint` | | ported |
| `cgltf_accessor_read_index` | `readIndex` | | ported |
| `cgltf_accessor_unpack_floats` | `unpackFloats` | | ported |
| `cgltf_accessor_unpack_indices` | `unpackIndices` | | ported |
| sparse accessors (in the five above) | as upstream | | ported |
| `cgltf_buffer_view_data` | `bufferViewData` | | ported |
| `cgltf_find_accessor` | `findAccessor` | | ported |
| `cgltf_num_components`, `cgltf_component_size`, `cgltf_calc_size` | `numComponents`, `componentSize`, `calcSize` | | ported |
| `cgltf_node_transform_local`, `cgltf_node_transform_world` | `transformLocal`, `transformWorld` | | ported |
| `cgltf_mesh_index` and the other 15 `_index` functions | references are already indices | | ported |

## Extensions

Each is read into the fields cgltf reads it into.

| extension | state |
| --- | --- |
| `KHR_draco_mesh_compression` | ported |
| `KHR_lights_punctual` | ported |
| `KHR_materials_anisotropy` | ported |
| `KHR_materials_clearcoat` | ported |
| `KHR_materials_diffuse_transmission` | ported |
| `KHR_materials_dispersion` | ported |
| `KHR_materials_emissive_strength` | ported |
| `KHR_materials_ior` | ported |
| `KHR_materials_iridescence` | ported |
| `KHR_materials_pbrSpecularGlossiness` | ported |
| `KHR_materials_sheen` | ported |
| `KHR_materials_specular` | ported |
| `KHR_materials_transmission` | ported |
| `KHR_materials_unlit` | ported |
| `KHR_materials_variants` | ported |
| `KHR_materials_volume` | ported |
| `KHR_meshopt_compression`, `EXT_meshopt_compression` | ported |
| `KHR_texture_basisu` | ported |
| `KHR_texture_transform` | ported |
| `EXT_mesh_gpu_instancing` | ported |
| `EXT_texture_webp` | ported |

## Left out

Awaiting the author's approval:

- `cgltf_write.h`, the glTF writer: Loomwork only reads glTF.
