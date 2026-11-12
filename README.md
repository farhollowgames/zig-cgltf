# zig-cgltf

Ported from cgltf 1.15 (`85cd623`) · Zig 0.17.0 · [status](STATUS.md)

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## What it is

A Zig port of cgltf, Johannes Kuhlmann's single-header C loader for glTF
2.0, and of its writer, `cgltf_write.h`. It parses glTF JSON and GLB files,
loads their buffers, validates them, reads accessors and node transforms,
and writes glTF and GLB files, as cgltf 1.15 does. It is pure Zig, with no
dependencies beyond the standard library, and links no libc. The original
is listed under [References](#references).

## Features

- Parsing glTF and GLB from memory or from a file, with cgltf's checks of
  the GLB container.
- Buffers from the GLB's BIN chunk, from base64 data URIs and from files
  beside the glTF.
- `validate`: cgltf's checks of sizes, offsets and references.
- The accessor helpers: `readFloat`, `readUint`, `readIndex`,
  `unpackFloats`, `unpackIndices`, sparse accessors included, and
  `bufferViewData` and `findAccessor`.
- Node transforms, local and world.
- Every extension cgltf reads (21 KHR and EXT extensions, listed in
  [`STATUS.md`](STATUS.md)); extras and unknown extensions kept as offsets
  into the JSON.
- Writing: `write` puts the glTF JSON text to an `std.Io.Writer`, and
  `writeFile` writes a glTF or GLB file, byte for byte as `cgltf_write.h`
  writes them, floats printed as glibc's `%.9g`.
- Memory comes from an `std.mem.Allocator`, and files are read through
  `std.Io` or a reader of the caller's.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-cgltf#main
```

There is no release yet; this fetches `main`. The package needs Zig 0.17.0.

In `build.zig`:

```zig
const cgltf = b.dependency("cgltf", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("cgltf", cgltf.module("cgltf"));
```

## Use

Load a model and read the positions of its first primitive:

```zig
const std = @import("std");
const cgltf = @import("cgltf");

pub fn positions(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]f32 {
    var gltf = try cgltf.parseFile(gpa, io, path, .{});
    defer gltf.deinit();
    try cgltf.loadBuffers(&gltf, io, path);
    try cgltf.validate(&gltf);

    const primitive = &gltf.meshes[0].primitives[0];
    const index = cgltf.findAccessor(primitive, .position, 0) orelse return error.NoPositions;
    const accessor = &gltf.accessors[index];
    const out = try gpa.alloc(f32, cgltf.unpackFloatsCount(accessor));
    errdefer gpa.free(out);
    _ = try cgltf.unpackFloats(&gltf, accessor, out);
    return out;
}
```

Write a model back, as glTF or GLB:

```zig
try cgltf.writeFile(&gltf, io, "copy.glb", .glb);
```

The API follows the original's, function for function, without the
`cgltf_` prefix (`cgltf_validate` is `cgltf.validate`), and
[`STATUS.md`](STATUS.md) lists every function with its tests. Everything in
a `Gltf` lives until `deinit`; slices taken from it are stale after that. A
`Gltf` from `parse` points into the bytes it was given, which must outlive
it.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md).

*Additions*:

- `error.OutOfBounds` where cgltf would read or write past a buffer, an
  output or a string, extras outside the JSON among them.
- `error.ParentCycle` from `transformWorld` on a loop of parents, where
  cgltf never returns.
- `unpackFloatsCount` and `unpackIndicesCount`, the counts cgltf returns for
  a null output.
- `number`, the C library's `atoi`, `atoll` and `atof` as cgltf reads
  numbers with them.

*Changes to expect*:

- References are indices into the `Gltf`'s arrays, not pointers, so there
  are no `_index` functions; a missing optional reference is `null`.
- `cgltf_data` is `Gltf`, and `cgltf_free` is `Gltf.deinit`.
- `decodeString` returns the decoded text, since a slice kept from before
  keeps its old length.
- Result codes are an error set; functions return their value or an error.
- An `std.mem.Allocator` in place of the memory callbacks, and a
  `FileReader` in place of the file callbacks.
- `Camera` is a tagged union of perspective and orthographic.
- `unpackIndices` takes the output's integer type, where cgltf takes a size
  in bytes.
- `write` writes to an `std.Io.Writer` and adds no NUL; the size cgltf
  returns for no buffer is the count of an `std.Io.Writer.Discarding`. An
  output too small for the text is `error.WriteFailed`, where cgltf writes
  past it.
- `writeFile` takes the file type, where cgltf reads it from its options,
  and returns `error.IoError` when writing the file fails, where cgltf
  ignores the failure and returns success.
- `error.InvalidExtras` from `write` and `writeFile` for extras whose data
  or JSON holds a NUL, which cgltf cuts at the NUL, leaving the extras' JSON
  unclosed.
- A node's `children`, a skin's `joints` and a scene's `nodes` are
  optional: `null` when the file has none, and empty for `[]`, which cgltf
  writes back.
- `error.InvalidOptions` is never returned: cgltf returns it for a null
  options pointer, which the port has no way to be given.

## Left out

Nothing: every function of `cgltf.h` and `cgltf_write.h` is ported, and
[`STATUS.md`](STATUS.md) lists each one with its tests.

## Tests

`zig build test` runs 69 tests: 17 unit tests and 52 tests that build cgltf
from `reference/`. 36 of the 52 run cgltf and the port on the same inputs
(every Khronos sample model, hand-made edge cases and 13,000 fuzzed files)
and compare every field of the result, every string byte, every reference
as an index, every float as bits, and every byte of the text and files
written; the other 16 check the port's refusals, failed allocations and a
file reader of the caller's.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/parity.md`](doc/parity.md): where the port differs from cgltf, and
  the test of each difference.

## Speed

Port time against original time, one thread, over every sample model:

| feature | time, port / original | port vs original |
| --- | ---: | ---: |
| parse glTF | 0.74 | 26% faster |
| parse GLB | 0.93 | 7% faster |
| validate | 0.91 | 9% faster |
| unpack floats | 0.14 | 86% faster |
| world transforms | 0.85 | 15% faster |
| write | 0.14 | 86% faster |

No row of the full table is slower than cgltf. The parse rows move most
with the machine's load; other runs gave parse GLB from 6% to 13% faster.

AMD Ryzen 9 9950X3D, one thread, Linux 7.3, Zig 0.17.0 ReleaseFast against
Zig's clang `-O3`, on the `release/candidate` branch; each side's best
median of three rounds; a load average of 14 to 32 on 32 hardware threads,
from other builds.

- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every row, the flags on both
  sides, the biases and the command.

## Licence

MIT licence, the original's ([`LICENSE`](LICENSE)). zig-cgltf is an altered
version of cgltf: the code is rewritten in Zig, with its own interface. The
original's notices, "Copyright (c) 2018-2021 Johannes Kuhlmann" and
"Copyright (c) 2019-2021 Philip Rideout", are kept in `LICENSE` as they are,
beside "Copyright 2026 Farhollow Games". [`NOTICE`](NOTICE) names the
translated sources, jsmn among them.

## References

- [cgltf](https://github.com/jkuhlmann/cgltf), the original, by
  [Johannes Kuhlmann](https://github.com/jkuhlmann), with `cgltf_write.h` by
  Philip Rideout, tag `v1.15` (`85cd623`), copied into `reference/cgltf/`
  for the tests and the benchmark only.
- [jsmn](https://github.com/zserge/jsmn), the JSON tokenizer cgltf includes,
  by Serge Zaitsev.
- [glTF 2.0](https://registry.khronos.org/glTF/), the format, and the
  Khronos [sample models](https://github.com/KhronosGroup/glTF-Sample-Assets).

Made by Farhollow Games for the Loomwork Engine.
