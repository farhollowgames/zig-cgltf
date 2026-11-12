# Benchmarks

These are measurements on one machine, under the conditions below. They are not a verdict on
either side.

## Method

`zig build bench` times each feature of zig-cgltf against cgltf's on one thread, over the
Khronos sample models (339 `.gltf` and `.glb` files, read into memory once), and checks that
both sides give the same outputs.

- **zig-cgltf**: ReleaseFast, for the CPU it runs on.
- **cgltf**: `reference/cgltf/` built by Zig's clang at `-O3`, for the same CPU, as `-std=c99`
  with `-ffp-contract=off -fno-fast-math`, the flags the tests use.
- **Memory**: both sides allocate with the C library's `malloc`.
- **Samples**: each lasts at least 50 ms of the benchmark thread's CPU time, after two
  warm-ups, and the two sides' samples alternate, so both see the same load. Every pass folds
  its outputs into a checksum kept behind a compiler barrier, so no pass can be removed, and
  the two sides' checksums are compared: a row whose outputs differ says so.
- **Reported**: the median of 11 samples in milliseconds a pass, the best median of three
  rounds for each side; range is (slowest - fastest) / median over the samples. The last
  column is cgltf's time divided by zig-cgltf's: above 1, zig-cgltf takes less time.

The rows:

| feature | one pass |
| --- | --- |
| parse glTF | `parse` of every `.gltf` file, then `deinit` |
| parse GLB | `parse` of every `.glb` file, then `deinit` |
| decode base64 | `loadBufferBase64` of every data URI of the models (38) |
| validate | `validate` of every model, parsed and loaded beforehand |
| unpack floats | `unpackFloats` of every accessor |
| read float | `readFloat` of every element of every accessor, into 16 floats |
| unpack indices | `unpackIndices` into `u32` of every scalar, unsigned, non-sparse accessor |
| read index | `readIndex` of every element of those accessors |
| world transforms | `transformWorld` of every node |

```sh
zig build bench
zig build bench -- --rounds 3              # each side's best median of three rounds
zig build bench -- --filter parse          # the rows whose name contains "parse"
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), at commit `3387a54`, on
12 November 2026, three rounds (`zig build bench -- --rounds 3`). Other builds were running:
the one-minute load average was about 10 on 32 hardware threads, which is why some ranges
are wide.

## Results

| feature | zig-cgltf ms | range | cgltf ms | range | cgltf / zig-cgltf |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse glTF | 57.695 | 3.1% | 93.775 | 10.0% | 1.63 |
| parse GLB | 34.981 | 2.4% | 40.228 | 4.9% | 1.15 |
| decode base64 | 1.036 | 3.6% | 63.496 | 1.0% | 61.29 |
| validate | 4.340 | 4.6% | 4.635 | 10.6% | 1.07 |
| unpack floats | 12.333 | 2.1% | 85.873 | 18.1% | 6.96 |
| read float | 179.392 | 5.0% | 200.480 | 6.1% | 1.12 |
| unpack indices | 3.346 | 17.2% | 11.393 | 5.4% | 3.40 |
| read index | 46.515 | 26.7% | 43.405 | 13.2% | 0.93 |
| world transforms | 0.447 | 0.9% | 0.343 | 0.8% | 0.77 |

## Known biases and slower rows

- zig-cgltf is compiled with the benchmark, so its functions can be inlined into the
  benchmark's loops; cgltf is a separate library, called through its interface, as a C user
  would call it. Every output is kept behind a compiler barrier on both sides, so inlining
  cannot remove work, but it can move work out of a loop.
- The port checks every read against the memory its buffer holds, which cgltf does not
  (see [`parity.md`](parity.md)). The accessor rows check once per call where every element
  fits, and per element otherwise.
- Zig 0.17 builds with LLVM's loop vectorizer turned off, so a loop over a length known only
  at run time stays scalar unless it is written with `@Vector`, while clang vectorizes
  cgltf's loops. The port's index bound in `validate`, its base64 decoder and its packed
  accessor reads are written with `@Vector`.
- **decode base64**: the port decodes 64 characters at a time with vectors; cgltf decodes
  one character at a time.
- **validate**: most of the time goes to NodePerformanceTest's 10,000 meshes, where both
  sides read each primitive's few indices and the accessors they check, bound by
  memory. The port reads an index run's last bytes, and a run under 64 bytes, as
  overlapping vectors; a walk up the parents stops at a node already walked from; and the
  fields it reads of every accessor and node are laid out among the first. Over nine
  unpinned runs the row's median was 1.10 (from 1.05 to 1.12), where it was 0.91 before;
  on a core of the 96 MiB-cache CCD it is about 1.3.
- **read index**: between 0.91 and 1.00 from run to run, as before these changes; not yet
  looked into.
- **world transforms**: 29% slower, not yet looked into; the row takes under half a
  millisecond over all 339 models.
- The sample models are one input set. Files with much larger buffers or many more nodes may
  give other ratios.
