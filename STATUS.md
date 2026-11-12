# Status

## Step-4 report

Done: steps 1 to 4 of the port method, on `main`. cgltf 1.15 (`85cd623`) is vendored unchanged;
every public function, option, type and extension of `cgltf.h` is ported, oracle-tested and,
for the hot paths, benchmarked. README, LICENSE, NOTICE and `doc/` (TESTING, BENCHMARKS,
parity) are written.

Tests: `zig build test` runs 45, all passing in ReleaseSafe: 10 unit tests, 23 oracle tests
(all 339 sample models from file and from memory, 12 hand-made edge tests, 7 tests of the free
functions against cgltf and glibc, 2 file fuzzers of 3,000 and 4,000 cases), and 12 tests of
the port's refusals, failed allocations and a custom file reader. `-Dfuzz-seed` 1 to 4 pass.

Benchmark, cgltf's time / zig-cgltf's (above 1, the port is faster), one noisy run:
parse glTF 1.22, parse GLB 1.06, decode base64 0.79, validate 0.17, unpack floats 0.75,
read float 0.80, unpack indices 0.89, read index 1.14, world transforms 1.87.

Left out, awaiting the author's approval: `cgltf_write.h` (see below).

For the author:
- The interface changes: indices for pointers, `Gltf`, error sets, an allocator and a
  `FileReader`, `Camera` as a tagged union, `unpackIndices(T, ...)` (`doc/parity.md`).
- Zig's `std.heap.ArenaAllocator` panics with an integer overflow when asked for a size near
  `maxInt(usize)`, so a data URI's buffer, whose size the file gives, comes from the allocator
  itself. That may be worth reporting to the Zig project.
- NaN in transforms is compared as "any NaN", since its payload depends on operand order.
- `number` follows glibc; cgltf on another C library may read odd numbers differently.
- More than 2^31 - 1 JSON tokens is `InvalidJson`, with no test (it needs a 4 GiB file).
- The benchmark ran with a load average of 14 to 28; step 7 reruns it with three rounds.
- The oracle skips cgltf on any call the port refuses with `OutOfBounds`, so a wrong refusal
  would go unseen; step 7 tightens that.

Every item's state:

- **not started**;
- **ported**: translated;
- **oracle-tested**: tests run the original and the port on the same inputs and compare every
  field, string byte, index and float bit;
- **benchmarked**: timed against the original by `zig build bench`;
- **reviewed**: a reviewer that did not write the port has tried to break it.

## Work state

Written to resume from: the next agent reads this section and `git log`.

- Steps 1 to 4: done, on `main`.
- Step 5 (performance pass): under way on `review/perf-and-skeptic`. Baseline, `--rounds 3`
  at load average 26 to 33 (zig-cgltf ms / cgltf ms): decode base64 80.3 / 64.8, validate
  34.0 / 9.1, unpack floats 128.4 / 97.7, read float 264.3 / 213.6, unpack indices
  14.4 / 10.8. Kept, one commit each:
  - validate: `indexBound` takes the largest index with 64-byte vectors, four at a time, one
    function per index size: 34.0 to 4.4 ms (ratio 0.27 to 1.05). A `@bitCast` of a byte
    array to a vector compiled to scalar shifts and made it three times slower; loading
    through an `*align(1) const @Vector` pointer gives `vpmaxuw` on memory.
  - decode base64: 64 characters at a time with `@Vector` range checks and shuffles into 48
    bytes, then cgltf's loop for the rest or from a chunk with a character outside the
    alphabet: 80.3 to 1.2 ms (ratio 0.81 to 58). A unit test in `load.zig` covers the chunks
    and where a bad character is refused; the oracle's base64 fuzz texts are under 48
    characters, so only the sample models' data URIs reach the chunks there.
- Steps 6 and 7 (skeptic, fixes): not started.

Next steps, in order: on `review/perf-and-skeptic`, a fresh agent's performance pass (each
change kept only with a benchmark gain and the oracle tests unchanged); a fresh skeptic's
review; fixes with tests that fail before them; the oracle's `OutOfBounds` gap above; the
test suite and a three-round benchmark again; README, `doc/BENCHMARKS.md` and this file
updated with the new numbers.

## Tests

The tests the tables name, by short name:

| short name | test |
| --- | --- |
| samples | `every sample model parses, loads, validates and reads as the original` |
| samples-memory | `every sample model parses from memory with an exact token count as the original` |
| glb | `edges: the GLB container's checks give the original's results` |
| options | `edges: forced file types, short input and token counts give the original's results` |
| json | `edges: JSON the tokenizer and the parser refuse, and glTF 1.0` |
| numbers | `edges: numbers read as C reads them`, and the `numbers:` tests |
| strings | `edges: strings, escapes and extras of every kind` |
| extensions | `edges: every extension cgltf reads, with its defaults and values` |
| variants | `edges: material variant mappings with odd variants and materials` |
| accessors | `edges: accessors of every type, component type and layout read as the original's` |
| sparse | `edges: sparse accessors, with and without a base view, read as the original's` |
| validation | `edges: validation of views, meshes, nodes and animations gives the original's results` |
| buffers | `edges: buffers from data URIs, files and the BIN chunk load as the original's` |
| files | `edges: files beside the glTF load as the original's` |
| decoding | `decoding: escapes and percent signs decode as the original decodes them`, and its fuzz test |
| base64 | `base64: fuzz: random texts decode as the original decodes them` |
| sizes | `sizes: components, component sizes and element sizes match for every type` |
| fuzz | both `fuzz:` tests in `test/documents_fuzz_test.zig` |
| refusals | the `refusal:` tests in `test/refusals_test.zig` |
| allocation | `a failed allocation at any point of parsing and loading a model leaks nothing` |
| reader | `a file reader of the caller's reads the file and the buffers, and releases them` |

## Parsing

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_parse` (glTF and GLB from memory) | `parse` | samples-memory, glb, options, fuzz | benchmarked |
| `cgltf_parse_file` | `parseFile` | samples, files, reader | oracle-tested |
| `cgltf_options.json_token_count` | `Options.json_token_count` | samples-memory, options, fuzz, refusals | oracle-tested |
| `cgltf_options.memory` (alloc and free callbacks) | an `std.mem.Allocator` | samples, allocation | oracle-tested |
| `cgltf_options.file` (read and release callbacks) | `Options.file_reader` | samples, files, reader | oracle-tested |
| `cgltf_options.type` (auto, gltf, glb) | `Options.file_type` | options, glb, fuzz | oracle-tested |
| `cgltf_free` | `Gltf.deinit` | allocation, reader | oracle-tested |
| jsmn (strict, parent links) | `jsmn.zig` | json, fuzz | oracle-tested |
| C's `atoi`, `atoll`, `atof` as cgltf reads numbers | `number.zig` | numbers | oracle-tested |
| glTF 1.0 detection (`cgltf_result_legacy_gltf`) | `error.LegacyGltf` | json, glb | oracle-tested |
| extras as JSON offsets and text | `Extras` | strings, samples | oracle-tested |
| unknown extensions as name and JSON | `Extension` | extensions, json | oracle-tested |
| `extensionsUsed`, `extensionsRequired` | `extensions_used`, `extensions_required` | json, samples | oracle-tested |
| reference fixup (`cgltf_fixup_pointers`) | indices checked against their arrays | json, fuzz | oracle-tested |

## Loading and checking

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_load_buffers` (files, data URIs, GLB chunk) | `loadBuffers` | samples, buffers, files, fuzz | oracle-tested |
| `cgltf_load_buffer_base64` | `loadBufferBase64` | base64, buffers | benchmarked |
| `cgltf_decode_string` | `decodeString` | decoding, strings, refusals | oracle-tested |
| `cgltf_decode_uri` | `decodeUri` | decoding, files | oracle-tested |
| `cgltf_validate` | `validate` | validation, samples, fuzz, refusals | benchmarked |
| `cgltf_copy_extras_json` (deprecated) | `copyExtrasJson` | samples, strings, refusals | oracle-tested |

## Accessors, views and nodes

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_accessor_read_float` | `readFloat` | accessors, samples, refusals | benchmarked |
| `cgltf_accessor_read_uint` | `readUint` | accessors, samples, refusals | oracle-tested |
| `cgltf_accessor_read_index` | `readIndex` | accessors, samples, refusals | benchmarked |
| `cgltf_accessor_unpack_floats` | `unpackFloats` | accessors, sparse, samples, refusals | benchmarked |
| `cgltf_accessor_unpack_indices` | `unpackIndices` | accessors, samples, refusals | benchmarked |
| sparse accessors (in the five above) | as upstream | sparse, fuzz, refusals | oracle-tested |
| `cgltf_buffer_view_data` | `bufferViewData` | samples, fuzz, refusals | oracle-tested |
| `cgltf_find_accessor` | `findAccessor` | samples, fuzz | oracle-tested |
| `cgltf_num_components`, `cgltf_component_size`, `cgltf_calc_size` | `numComponents`, `componentSize`, `calcSize` | sizes | oracle-tested |
| `cgltf_node_transform_local`, `cgltf_node_transform_world` | `transformLocal`, `transformWorld` | samples, fuzz, refusals | benchmarked |
| `cgltf_mesh_index` and the other 15 `_index` functions | references are already indices | samples | oracle-tested |

## Extensions

Each is read into the fields cgltf reads it into.

| extension | tests | state |
| --- | --- | --- |
| `KHR_draco_mesh_compression` | extensions, samples, fuzz | oracle-tested |
| `KHR_lights_punctual` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_anisotropy` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_clearcoat` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_diffuse_transmission` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_dispersion` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_emissive_strength` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_ior` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_iridescence` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_pbrSpecularGlossiness` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_sheen` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_specular` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_transmission` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_unlit` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_variants` | extensions, samples, fuzz | oracle-tested |
| `KHR_materials_volume` | extensions, samples, fuzz | oracle-tested |
| `KHR_meshopt_compression`, `EXT_meshopt_compression` | extensions, samples, fuzz | oracle-tested |
| `KHR_texture_basisu` | extensions, samples, fuzz | oracle-tested |
| `KHR_texture_transform` | extensions, samples, fuzz | oracle-tested |
| `EXT_mesh_gpu_instancing` | extensions, samples, fuzz | oracle-tested |
| `EXT_texture_webp` | extensions, samples, fuzz | oracle-tested |

## Left out

Awaiting the author's approval:

- `cgltf_write.h`, the glTF writer, a separate header: Loomwork only reads glTF.

## Not in cgltf

- `error.ParentCycle`, `error.OutOfBounds` and the other refusals: `doc/parity.md`, tested by
  refusals.
- `unpackFloatsCount`, `unpackIndicesCount`: tested by samples.
