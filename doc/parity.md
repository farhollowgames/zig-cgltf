# Parity with cgltf

zig-cgltf gives cgltf 1.15's results: the same parsed fields, strings, references, floats and
result codes, on every input the tests give both (see [`TESTING.md`](TESTING.md)). This file
lists where it differs, and why.

## Refusals where cgltf reads or writes out of bounds

On these inputs cgltf reads or writes memory it does not own, or never returns, so there is no
result of cgltf's to match. The port returns an error, and the oracle tests do not run cgltf
on those calls. Each case has a test in `test/refusals_test.zig`.

| case | cgltf | zig-cgltf | test |
| --- | --- | --- | --- |
| `validate` of a sparse accessor whose index view lies past its buffer: cgltf reads the indices before it checks the view | reads past the buffer | `error.OutOfBounds` | `refusal: validate reads indices past the buffer's memory` |
| `validate` of primitive indices in a buffer whose `data` is shorter than its `size`, as a caller may set it | reads past the data | `error.OutOfBounds` | `refusal: validate reads primitive indices past the buffer's memory` |
| `readFloat`, `readUint` and `unpackFloats` of an accessor past its view and buffer, without `validate`; in a GLB, reads past the BIN chunk | reads past the buffer | `error.OutOfBounds` | `refusal: accessor reads past the buffer's memory` |
| `unpackIndices` and `readIndex` of a vector accessor: cgltf reads `count` indices at one per element's stride, past the elements | reads past the buffer | `error.OutOfBounds` | `refusal: unpacking indices of a vector accessor reads past its elements` |
| `unpackFloats` with a sparse index whose element lies past the end of the output | writes past the output | `error.OutOfBounds` | `refusal: a sparse index past the output is not written` |
| `transformWorld` of a node in a loop of parents (`validate` refuses such a file, as cgltf's does) | never returns | `error.ParentCycle` | `refusal: a loop of parents is an error, where the world transform never returns` |
| `copyExtrasJson` into an output of 0 bytes, or of the text's length or one less: cgltf's NUL lands past the end; and extras offsets a caller moved past the JSON | writes or reads past the end | `error.OutOfBounds` | `refusal: copying extras into a buffer too small for cgltf's NUL` |
| `decodeString` of a string that ends inside an escape (`\`, or `\u` with fewer than four characters) | reads past the end | `error.OutOfBounds` | `refusal: decoding a string whose escape runs past its end` |
| `parse` with a token count whose array size overflows `size_t` | allocates a wrapped size and writes past it | `error.OutOfMemory` | `refusal: a token count whose array size overflows is out of memory` |
| `parse` of JSON with more than 2^31 - 1 tokens: cgltf keeps the count in an `int` | overflows the `int` | `error.InvalidJson` | none: the input needs a file of more than 4 GiB |

`bufferViewData` of a view whose offset lies past its buffer's memory is also
`error.OutOfBounds`, where cgltf returns a pointer past the end (test: `refusal: a view's data
past the buffer's memory`).

The port checks every read against the memory a buffer holds, not against the buffer's
`size`: a read past `size` but inside the memory, such as a GLB's BIN chunk longer than its
buffer, reads the same bytes as cgltf.

## Results that depend on how cgltf is compiled

- **NaN in transforms.** A transform computed from a NaN may keep either operand's NaN in an
  addition or a product, as the compiler orders the operands; neither C nor Zig fixes the
  order. The port's NaN payload can differ from cgltf's there, so the tests count any NaN as
  equal to any NaN in `transformLocal` and `transformWorld`. Every other float, NaN included,
  is compared as bits.
- **`\u` escapes with characters that are not hex digits.** cgltf adds their value, -1, after
  shifting a negative `int` left, which C leaves undefined. The port computes the
  two's-complement result every compiler gives, and the tests compare it with cgltf's.
- **Numbers.** cgltf reads every number through the C library's `atoi`, `atoll` and `atof`,
  whose results on unusual text (hexadecimal floats, `nan(...)`, overflow, trailing text) differ
  between C libraries. `number` gives glibc's results in the C locale, and the tests compare it
  with glibc's. On other C libraries cgltf can read such numbers differently; the port reads
  them the same way everywhere.
- **Floats.** cgltf is built with `-ffp-contract=off -fno-fast-math`, so its float steps round
  as written, as Zig's do.

## Changes to the interface

- **References are indices.** Every pointer between cgltf's objects is an index into the
  `Gltf` array of that kind, `?u32` where the reference is optional and `u32` where glTF
  requires it; an animation channel's sampler is an index into its animation's samplers. The
  16 `cgltf_*_index` functions are therefore not needed.
- **Errors.** Each `cgltf_result` other than success is an error of `Error`, with
  `OutOfBounds` added; functions return their value, not an output pointer. The port never
  returns `InvalidOptions`, which cgltf returns for a null options pointer, or for
  `cgltf_copy_extras_json` with neither an output nor a size.
- **Memory.** An `std.mem.Allocator` takes the place of cgltf's `alloc_func` and
  `free_func`. Everything parsed lives in an arena until `Gltf.deinit`; a buffer decoded from a
  data URI is allocated from the allocator itself, because its size comes from the file and can
  be more than an arena can add to its own bookkeeping without overflowing.
- **Files.** `FileReader` takes the place of cgltf's `read` and `release` callbacks, with
  `std.Io` and the allocator passed to it; the default reads with `std.Io`, from the working
  directory, as `fopen` does.
- **Cameras.** A camera's `type` and `data` are one tagged union.
- **Counts.** `unpackFloatsCount` and `unpackIndicesCount` return what cgltf returns for a
  null output.
- **`unpackIndices`** takes the output's integer type (`u8`, `u16` or `u32`) where cgltf
  takes an output size in bytes, and returns 0 for indices wider than it, as cgltf does.
- **Lifetimes.** A `Gltf` from `parse` points into the bytes it was given, as cgltf's
  `cgltf_data` does, so they must outlive it. Slices into a `Gltf` are stale after `deinit`.
