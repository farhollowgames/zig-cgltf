# zig-cgltf

Tracks cgltf 1.15 · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of cgltf, Johannes Kuhlmann's single-header C loader for glTF 2.0. It parses glTF
JSON and GLB files, loads their buffers, validates them, and reads accessors and node
transforms, as cgltf 1.15 does. The original is listed under
[Licence and references](#licence-and-references).

This port is not affiliated with or reviewed by the original authors. Its code was written
with AI assistance for Farhollow Games, and is only machine verified. See
[the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## Features

- Parsing glTF and GLB from memory or from a file, with cgltf's checks of the GLB container.
- Buffers from the GLB's BIN chunk, from base64 data URIs and from files beside the glTF.
- `validate`: cgltf's checks of sizes, offsets and references.
- The accessor helpers: `readFloat`, `readUint`, `readIndex`, `unpackFloats`, `unpackIndices`,
  sparse accessors included, and `bufferViewData` and `findAccessor`.
- Node transforms, local and world.
- Every extension cgltf reads (21 KHR and EXT extensions, listed in [`STATUS.md`](STATUS.md));
  extras and unknown extensions kept as offsets into the JSON.
- Pure Zig, with no libc. Memory comes from an `std.mem.Allocator`, and files are read through
  `std.Io` or a reader of the caller's.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-cgltf#v0.1.0
```

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

Everything in a `Gltf` lives until `deinit`; slices taken from it are stale after that. A
`Gltf` from `parse` points into the bytes it was given, which must outlive it.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md).

*Additions*:

- `error.OutOfBounds` where cgltf would read or write past a buffer, an output or a string.
- `error.ParentCycle` from `transformWorld` on a loop of parents, where cgltf never returns.
- `unpackFloatsCount` and `unpackIndicesCount`, the counts cgltf returns for a null output.
- `number`, the C library's `atoi`, `atoll` and `atof` as cgltf reads numbers with them.

*Changes to expect*:

- References are indices into the `Gltf`'s arrays, not pointers, so there are no `_index`
  functions; a missing optional reference is `null`.
- `cgltf_data` is `Gltf`, and `cgltf_free` is `Gltf.deinit`.
- `decodeString` returns the decoded text, since a slice kept from before keeps its old
  length.
- Result codes are an error set; functions return their value or an error.
- An `std.mem.Allocator` in place of the memory callbacks, and a `FileReader` in place of the
  file callbacks.
- `Camera` is a tagged union of perspective and orthographic.
- `unpackIndices` takes the output's integer type, where cgltf takes a size in bytes.
- `error.InvalidOptions` is never returned: cgltf returns it for a null options pointer, which
  the port has no way to be given.

## Not included

The parts of cgltf that are left out, each with its reason, are listed in
[`STATUS.md`](STATUS.md#left-out).

## Testing and benchmarks

`zig build test` runs 51 tests: 13 unit tests and 38 tests that build cgltf from `reference/`.
Most of the 38 run cgltf and the port on the same inputs (every Khronos sample model,
hand-made edge cases and 10,000 fuzzed files) and compare every field of the result, every
string byte, every reference as an index, and every float as bits.

Time taken by zig-cgltf against cgltf, one thread, over every sample model:

| feature | zig-cgltf vs cgltf |
| --- | ---: |
| parse glTF | 14% faster |
| parse GLB | 6% faster |
| validate | 7% faster |
| unpack floats | about 7 times faster |
| world transforms | 15% faster |

On an AMD Ryzen 9 9950X3D, Linux, Zig 0.17.0 (`x86_64` `znver5`), with cgltf built by Zig's
clang at `-O3`. [`doc/TESTING.md`](doc/TESTING.md) describes the tests, and
[`doc/BENCHMARKS.md`](doc/BENCHMARKS.md) has every row, the flags and the command.

## Licence and references

zig-cgltf is licensed under the MIT licence ([`LICENSE`](LICENSE)), as cgltf is, and keeps
cgltf's copyright notice:

    Copyright (c) 2018-2021 Johannes Kuhlmann

[`NOTICE`](NOTICE) names the translated sources, jsmn among them.

- cgltf: <https://github.com/jkuhlmann/cgltf>, by Johannes Kuhlmann, tag v1.15
  (`85cd623`), vendored in `reference/cgltf/` for the tests and the benchmark only.
- jsmn, the JSON tokenizer cgltf includes: <https://github.com/zserge/jsmn>, by Serge
  Zaitsev.
- glTF 2.0: <https://registry.khronos.org/glTF/>, and the Khronos sample models at
  <https://github.com/KhronosGroup/glTF-Sample-Assets>.
