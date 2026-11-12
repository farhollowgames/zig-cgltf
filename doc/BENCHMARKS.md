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

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), at commit `bbca431`, on
12 November 2026, three rounds (`zig build bench -- --rounds 3`). Other builds were running:
the one-minute load average was 9 to 18 on 32 hardware threads, which is why some ranges
are wide.

## Results

| feature | zig-cgltf ms | range | cgltf ms | range | cgltf / zig-cgltf |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse glTF | 71.684 | 7.1% | 83.101 | 10.1% | 1.16 |
| parse GLB | 36.961 | 9.4% | 39.326 | 17.6% | 1.06 |
| decode base64 | 1.022 | 14.7% | 63.490 | 1.6% | 62.14 |
| validate | 4.009 | 9.5% | 4.303 | 6.4% | 1.07 |
| unpack floats | 11.851 | 7.5% | 88.133 | 16.8% | 7.44 |
| read float | 178.977 | 5.1% | 199.149 | 8.7% | 1.11 |
| unpack indices | 2.867 | 79.0% | 8.939 | 38.7% | 3.12 |
| read index | 34.708 | 7.8% | 44.249 | 29.3% | 1.27 |
| world transforms | 0.295 | 4.9% | 0.349 | 2.4% | 1.18 |

The parse rows move with the load: at `3387a54`, a run at a load of about 10 gave parse glTF
1.63 and parse GLB 1.15, with the same parser.

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
- **read index**: `readIndex` switches on the component type once and reads a fixed-size
  integer, where it switched for the size and again for the read. Over seven unpinned runs
  the row's median went from 0.89 to 1.23 (from 1.22 to 1.28).
- **world transforms**: the local transform's rotation columns and the parent product are
  written with `@Vector`, in cgltf's order of float operations, so the bits match. Over five
  runs on one core the row's median went from 0.77 to 1.18 (from 1.17 to 1.19). The 1.19
  given before for this row came from the branch `port/writer`, commit `cde6c5b`, measured
  alone (`--filter`, `--rounds 5`); `review/perf-and-skeptic` never had that change and
  measures 0.77. This branch has the same change, picked from `port/writer`.
- The sample models are one input set. Files with much larger buffers or many more nodes may
  give other ratios.
