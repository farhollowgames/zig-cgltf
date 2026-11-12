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
| read uint | `readUint` of every element of every accessor, into 4 integers |
| unpack indices | `unpackIndices` into `u32` of every scalar, unsigned, non-sparse accessor |
| read index | `readIndex` of every element of those accessors |
| world transforms | `transformWorld` of every node |
| write | `write` of every model's text into memory: the port into an `std.Io.Writer.fixed`, cgltf with `cgltf_write` into a buffer of the same size |

```sh
zig build bench
zig build bench -- --rounds 3              # each side's best median of three rounds
zig build bench -- --filter parse          # the rows whose name contains "parse"
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), on the branch
`release/candidate`, which merges `review/perf-and-skeptic`, `port/writer` and
`perf/validate`, on 12 November 2026, three rounds (`zig build bench -- --rounds 3`). Other
builds were running: the one-minute load average was 32 when the run started and 14 when it
ended, on 32 hardware threads, which is why some ranges are wide.

## Results

| feature | zig-cgltf ms | range | cgltf ms | range | cgltf / zig-cgltf |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse glTF | 64.542 | 4.8% | 86.845 | 3.2% | 1.35 |
| parse GLB | 35.898 | 20.0% | 38.797 | 16.8% | 1.08 |
| decode base64 | 1.024 | 0.9% | 60.149 | 1.8% | 58.72 |
| validate | 4.283 | 7.8% | 4.703 | 7.2% | 1.10 |
| unpack floats | 12.302 | 2.2% | 87.608 | 8.3% | 7.12 |
| read float | 177.262 | 0.7% | 199.345 | 2.3% | 1.12 |
| read uint | 134.711 | 5.1% | 191.357 | 7.3% | 1.42 |
| unpack indices | 3.507 | 22.4% | 9.672 | 9.0% | 2.76 |
| read index | 36.527 | 13.2% | 42.849 | 1.3% | 1.17 |
| world transforms | 0.292 | 1.1% | 0.346 | 1.0% | 1.18 |
| write | 26.901 | 1.1% | 190.592 | 1.9% | 7.08 |

The parse rows move most with the load: other runs of the same parser gave parse glTF from
1.16 to 1.63 and parse GLB from 1.06 to 1.15.

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
  sides read each primitive's few indices and the accessors they check, bound by memory.
  The port reads an index run's last bytes, and a run under 64 bytes, as overlapping
  vectors; a walk up the parents stops at a node already walked from; and the fields it
  reads of every accessor and node are laid out among the first. Over nine runs the row's
  median went from 0.91 to 1.10 (from 1.05 to 1.12); on a core of the 96 MiB-cache CCD it is
  about 1.3.
- **read index** and **read uint**: `readIndex` switches on the component type once and
  reads a fixed-size integer, and `readUint` chooses the element and component type at
  compile time, where both switched for the size and again for the read. Read index went
  from 0.89 to 1.23 over seven runs; read uint from 0.95 to 1.35, measured alone.
- **world transforms**: the local transform's rotation columns and the parent product are
  written with `@Vector`, in cgltf's order of float operations, so the bits match. Over five
  runs on one core the row's median went from 0.77 to 1.18 (from 1.17 to 1.19).
- **write**: cgltf formats every value with `snprintf`; the port writes property names as
  constants, integers two digits at a time, and floats with its own `%.9g` (`formatFloat`),
  which works from the float's binary exponent with integer multiplies.
- The sample models are one input set. Files with much larger buffers or many more nodes may
  give other ratios.
