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
- **Reported**: the median of 11 samples in milliseconds a pass; range is
  (slowest - fastest) / median over the samples. The last column is cgltf's time divided by
  zig-cgltf's: above 1, zig-cgltf takes less time.

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

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), at commit `cf58b87`, on
11 November 2026, one round. Other builds were running: the one-minute load average was
14 to 28 on 32 hardware threads, which is why some ranges are wide.

## Results

| feature | zig-cgltf ms | range | cgltf ms | range | cgltf / zig-cgltf |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse glTF | 87.390 | 71.0% | 106.392 | 34.4% | 1.22 |
| parse GLB | 44.540 | 35.8% | 47.279 | 46.6% | 1.06 |
| decode base64 | 89.749 | 13.8% | 71.052 | 13.8% | 0.79 |
| validate | 36.568 | 28.0% | 6.255 | 61.8% | 0.17 |
| unpack floats | 199.921 | 26.9% | 150.307 | 29.0% | 0.75 |
| read float | 277.207 | 13.0% | 221.793 | 13.4% | 0.80 |
| unpack indices | 15.287 | 34.0% | 13.622 | 34.7% | 0.89 |
| read index | 41.550 | 22.6% | 47.249 | 19.1% | 1.14 |
| world transforms | 0.199 | 6.9% | 0.373 | 6.6% | 1.87 |

## Known biases and slower rows

- The port checks every read against the memory its buffer holds, which cgltf does not
  (see [`parity.md`](parity.md)). The accessor rows pay for those checks.
- Zig 0.17 builds with LLVM's loop vectorizer turned off, so a loop over a length known only at
  run time stays scalar unless it is written with `@Vector`; clang vectorizes cgltf's loops.
  `validate`'s index bound loop is the largest gap: cgltf's loop over the indices is vectorized
  by clang, and the port's reads one index at a time with a switch on the component type.
- `decode base64` and the accessor rows have not been tuned yet.
- The sample models are one input set. Files with much larger buffers or many more nodes may
  give other ratios.
