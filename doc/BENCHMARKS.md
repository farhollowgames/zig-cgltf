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
| write | `write` of every model's text into memory: the port into an `std.Io.Writer.fixed`, cgltf with `cgltf_write` into a buffer of the same size |

```sh
zig build bench
zig build bench -- --rounds 3              # each side's best median of three rounds
zig build bench -- --filter parse          # the rows whose name contains "parse"
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), at commit `24a0b1e` on
the branch `port/writer`, on 11 November 2026, three rounds (`zig build bench -- --rounds
3`). Other builds were running: the one-minute load average was 12 to 22 on 32 hardware
threads, which is why some ranges are wide.

## Results

| feature | zig-cgltf ms | range | cgltf ms | range | cgltf / zig-cgltf |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse glTF | 65.785 | 4.8% | 86.706 | 13.8% | 1.32 |
| parse GLB | 34.138 | 2.7% | 38.094 | 5.8% | 1.12 |
| decode base64 | 1.010 | 4.3% | 61.525 | 2.0% | 60.92 |
| validate | 5.152 | 8.1% | 4.691 | 11.2% | 0.91 |
| unpack floats | 12.524 | 22.2% | 77.877 | 18.4% | 6.22 |
| read float | 177.398 | 78.8% | 196.939 | 11.5% | 1.11 |
| unpack indices | 4.044 | 3.6% | 10.311 | 6.3% | 2.55 |
| read index | 48.464 | 3.3% | 42.559 | 18.8% | 0.88 |
| world transforms | 0.455 | 5.9% | 0.347 | 2.3% | 0.76 |
| write | 26.980 | 1.4% | 191.725 | 2.9% | 7.11 |

Before this run, on the branch `review/perf-and-skeptic` at commit `e0b7e45` and a load of
about 15, parse glTF gave 1.48, parse GLB 1.14, read float 1.17 and read index 1.00; those
rows move with the load from run to run.

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
- **validate**: both sides spend most of the time in the index bound loop, which is now
  vectorized on both and bound by memory; the row moves between 0.89 and 1.05 from run to
  run.
- **write**: cgltf formats every value with `snprintf`; the port writes property names as
  constants, integers two digits at a time, and floats with its own `%.9g` (`formatFloat`),
  which works from the float's binary exponent with integer multiplies.
- **world transforms**: 31% slower, not yet looked into; the row takes under half a
  millisecond over all 339 models.
- The sample models are one input set. Files with much larger buffers or many more nodes may
  give other ratios.
