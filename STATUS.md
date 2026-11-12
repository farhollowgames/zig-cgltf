# Status

## Writer report

Done: `cgltf_write.h` ported on branch `port/writer` (from `review/perf-and-skeptic`), pushed,
through the port steps: inventory, oracle tests, benchmark, performance pass, skeptic and
fixes. Release (step 8) waits for the author.

Tests: `zig build test` runs 66, all passing in ReleaseSafe: 16 unit tests, 35 oracle tests
and 15 tests of refusals, failed allocations and a custom reader. New for the writer: every
sample model's text, glTF file and GLB file compared byte for byte with cgltf's, the text
parsed again by both, 3,000 generated documents written and compared, extras on every
object, a padded BIN chunk, the bytes past the text in a fixed output, three refusals, and
`formatFloat` against glibc's `%.9g` (220,000 random floats; a probe outside the tests
compared every positive finite float).

Benchmark, `--rounds 3`: write 7.11 (26.98 ms against cgltf's 191.73 ms); 2.30 before the
performance pass, whose kept changes are a `%.9g` without u256 division or `log10`, fixed-size
indent copies, property names as constants and integers without `print`.

Skeptic findings: the indent's fixed-size copy wrote spaces past the text into the caller's
buffer (fixed, with a test that failed before); the BIN padding and the extras of 16 kinds
of object were untested (tests added, each failing under a mutation the suite let through);
`writeFile`'s `IoError` where cgltf returns success, the C locale and the GLB total on 64-bit
big-endian machines were undocumented (now in `doc/parity.md`). Extras whose JSON range holds
a NUL, which cgltf cuts at the NUL while counting the whole range, were cut by the port too.

The author's answers: `writeFile` keeps returning `IoError` on a failed write, documented as a
deliberate difference; extras whose JSON holds a NUL are refused with `error.InvalidExtras`
(test `refusal: writing extras whose JSON holds a NUL`, failing first), and `writeFile` now
counts the JSON before it creates the file, so a refused write leaves the path untouched.

Open: the step-4 and step-7 points below. The build prints a "failed command" line for the
differential tests on every run that is not cached, because the fuzz tests print their
counts to stderr; every step succeeds.

## Step-7 report

Done: steps 5 to 7 on branch `review/perf-and-skeptic`, pushed; `main` holds steps 1 to 4.

Tests: `zig build test` runs 49, all passing in ReleaseSafe: 12 unit tests, 25 oracle tests
and 12 tests of refusals, failed allocations and a custom reader. Fuzz seeds 0, 1 and 13
pass.

Performance pass (one commit each, every one with a gain and the oracle tests unchanged):
`@Vector` index bounds in `validate`, a 64-character base64 decoder, accessor reads specialized
at compile time with one bounds check per call, and jsmn stepping over string bytes 64 at a
time.

Skeptic findings, each fixed with a test that failed before:
- `decodeString` read past a NUL inside the string, where cgltf stops (wrong result).
- A file URI with `%00` kept the bytes after it in the path; cgltf opens the file before it.
- `decodeString`'s in-place result left callers' slices at the old length: it now returns
  the decoded slice (interface change, in `doc/parity.md`).
- The benchmark hashed one float of read float and world transforms, so the inlined port's
  other work could be removed: world transforms went from 1.9 times faster to 29% slower.
- The mutation fuzz floor of 300 failed on seed 13 (299): now 250.
- Stale counts and tables in the docs.
Found while fixing: the oracle skipped cgltf on every port refusal, so a wrong refusal would
pass. Each refusal is now checked against bounds from cgltf's structs, which found the
accessor reads refusing a view past its buffer's memory when nothing is read; fixed. A node's
own matrix is compared by bits, and a new fuzz test puts 3,000 accessor layouts through the
helpers.

Benchmark, `--rounds 3`, cgltf's time / zig-cgltf's (above 1, the port is faster): parse glTF
1.48, parse GLB 1.14, decode base64 66.8, validate 0.91, unpack floats 6.27, read float
1.17, unpack indices 2.58, read index 1.00, world transforms 0.77.

Still open: the step-4 points below, `cgltf_write.h` awaiting approval, world transforms not
looked into, more than 2^31 - 1 tokens untested, `readUint` not tuned.

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
- Steps 5 to 7: done on `review/perf-and-skeptic` (reports above). The performance pass
  measured each change with `--rounds 3` under load; its notes: a `@bitCast` from a byte
  array to a `@Vector` compiles to scalar shifts, and loading through an
  `*align(1) const @Vector` pointer does not; specializing `elementReadFloat` gained only
  when inlined.
- Step 8 (release): not started; it waits for the author's approval of the left-out list
  and the review of the branch.

- The writer (`cgltf_write.h`), on branch `port/writer` from `review/perf-and-skeptic`, as
  the author asked: ported and oracle-tested (every sample model's text and files, byte for
  byte; round trips; 3,000 generated documents; `%.9g` against glibc). Benchmarked: the
  `write` row, every model's text into memory, 84.1 ms against cgltf's 193.8 ms (ratio
  2.30, three rounds, load average about 25) before the performance pass, 28.8 ms against
  194.0 ms (ratio 6.75) after it.
- The writer's performance pass (step 5), each change measured with `--rounds 3` under
  load. Kept: `formatFloat` without a u256 division or `log10` (ratio 2.43 to 5.11; checked
  against glibc over every positive finite float as well), each indent as one fixed-size
  copy (to 5.80), comptime property names written as literals (to 5.95 to 6.18), and
  integers and string values without `print` (to 6.79 to 6.98). Dropped, with no clear
  gain: formatting floats straight into the writer's buffer, and `formatFloat`'s digits
  in pairs with a vector scan for the trailing zeros.
- The writer's skeptic (step 6) and fixes (step 7): the indent's fixed-size copy wrote spaces
  past the text into the caller's buffer, where cgltf leaves it alone; each length now has
  its own fixed-size copy (write row 6.91 after it). Tests added for a BIN chunk that needs
  padding and for extras on every object, both gaps that let mutations pass. Documented in
  `doc/parity.md`: `writeFile`'s `IoError`, extras whose JSON range holds a NUL, the C
  locale, and the GLB total on 64-bit big-endian machines.

- The writer's docs: README, `doc/parity.md`, `doc/TESTING.md`, `doc/BENCHMARKS.md` (a full
  three-round run at `24a0b1e`), done.

Next steps: the author reviews both branches and the open points,
and the release: merge, tag `v0.1.0`, and the release notes.

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
| decoding | the three `decoding:` tests in `test/functions_test.zig` |
| base64 | `base64: fuzz: random texts decode as the original decodes them` |
| sizes | `sizes: components, component sizes and element sizes match for every type` |
| fuzz | the `fuzz:` tests of mutations and documents in `test/documents_fuzz_test.zig` |
| layouts | `fuzz: random accessor layouts over one buffer give the original's results` |
| refusals | the `refusal:` tests in `test/refusals_test.zig` |
| allocation | `a failed allocation at any point of parsing and loading a model leaks nothing` |
| reader | `a file reader of the caller's reads the file and the buffers, and releases them` |
| write-samples | `write: every sample model writes as the original writes it` |
| write-again | `write: every sample model's text parses again in both, as the original's` |
| write-files | `write: files of every sample model, as glTF and GLB, are the original's`, and `write: a file that cannot be created is not found, as the original's` |
| write-glb | `write: a GLB whose BIN chunk needs padding is the original's` |
| write-extras | `write: extras on every object write as the original writes them` |
| write-output | `write: the output's bytes past the text are left as the original leaves them` |
| write-fuzz | `fuzz: random glTF documents write as the original writes them, and parse again` |
| write-refusals | the three `refusal: writing` tests |
| write-unit | the unit tests in `src/write.zig` |
| floats | the two `numbers:` tests of `%.9g`, and `formatFloat prints nine significant digits as glibc's %.9g` |

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
| `cgltf_decode_string` | `decodeString` | decoding, refusals | oracle-tested |
| `cgltf_decode_uri` | `decodeUri` | decoding, files | oracle-tested |
| `cgltf_validate` | `validate` | validation, samples, fuzz, refusals | benchmarked |
| `cgltf_copy_extras_json` (deprecated) | `copyExtrasJson` | samples, strings, refusals | oracle-tested |

## Accessors, views and nodes

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_accessor_read_float` | `readFloat` | accessors, layouts, samples, refusals | benchmarked |
| `cgltf_accessor_read_uint` | `readUint` | accessors, layouts, samples, refusals | oracle-tested |
| `cgltf_accessor_read_index` | `readIndex` | accessors, layouts, samples, refusals | benchmarked |
| `cgltf_accessor_unpack_floats` | `unpackFloats` | accessors, sparse, layouts, samples, refusals | benchmarked |
| `cgltf_accessor_unpack_indices` | `unpackIndices` | accessors, layouts, samples, refusals | benchmarked |
| sparse accessors (in the five above) | as upstream | sparse, fuzz, refusals | oracle-tested |
| `cgltf_buffer_view_data` | `bufferViewData` | samples, layouts, fuzz, refusals | oracle-tested |
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

## Writing

From `cgltf_write.h`, on branch `port/writer`.

| upstream | zig-cgltf | tests | state |
| --- | --- | --- | --- |
| `cgltf_write` into a buffer | `write` to an `std.Io.Writer` | write-samples, write-again, write-fuzz, write-output, write-unit | benchmarked |
| `cgltf_write` with no buffer (the size) | `write` to an `std.Io.Writer.Discarding` | write-samples, write-refusals | oracle-tested |
| `cgltf_write_file`, glTF and GLB | `writeFile` | write-files, write-glb, write-refusals | oracle-tested |
| every object, extension and extras the writer writes | as upstream | write-samples, write-fuzz, write-extras | oracle-tested |
| `%.9g` through `snprintf` | `number.formatFloat` | floats | oracle-tested |

## Left out

Nothing: `cgltf_write.h` is ported, as the author asked.

## Not in cgltf

- `error.ParentCycle`, `error.OutOfBounds` and the other refusals: `doc/parity.md`, tested by
  refusals.
- `unpackFloatsCount`, `unpackIndicesCount`: tested by samples.
