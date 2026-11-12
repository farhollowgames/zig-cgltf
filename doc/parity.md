# Parity with cgltf

zig-cgltf gives cgltf 1.15's results: the same parsed fields, strings, references, floats and
result codes, and the same written text and files byte for byte, on every input the tests
give both (see [`TESTING.md`](TESTING.md)). This file lists where it differs, and why.

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
| `write` of extras without `data` whose offsets a caller moved past the JSON | reads past the JSON | `error.OutOfBounds` | `refusal: writing extras whose offsets lie outside the JSON` |
| `write` into an output too small for the text: cgltf's cursor moves past the end, and its next `snprintf` writes there | writes past the output | `error.WriteFailed`, as from any full `std.Io.Writer` | `refusal: writing into an output too small for the text` |

`bufferViewData` of a view whose offset lies past its buffer's memory is also
`error.OutOfBounds`, where cgltf returns a pointer past the end (test: `refusal: a view's data
past the buffer's memory`). The accessor helpers read such a view as empty: a call that reads
nothing from it, such as `unpackFloats` into an empty output, gives cgltf's result, and one
that reads anything is refused.

The oracle tests check every refusal: for each call the port refuses, they work out from
cgltf's structs whether cgltf could read past the memory or write past the output there, and
fail if it could not.

The port checks every read against the memory a buffer holds, not against the buffer's
`size`: a read past `size` but inside the memory, such as a GLB's BIN chunk longer than its
buffer, reads the same bytes as cgltf.

## Results that depend on how cgltf is compiled

- **NaN in transforms.** A transform computed from a NaN may keep either operand's NaN in an
  addition or a product, as the compiler orders the operands; neither C nor Zig fixes the
  order. The port's NaN payload can differ from cgltf's there, so the tests count any NaN as
  equal to any NaN in computed transforms. A node's own matrix, copied by both, and every
  other float, NaN included, are compared as bits.
- **`\u` escapes with characters that are not hex digits.** cgltf adds their value, -1, after
  shifting a negative `int` left, which C leaves undefined. The port computes the
  two's-complement result every compiler gives, and the tests compare it with cgltf's.
- **Numbers.** cgltf reads every number through the C library's `atoi`, `atoll` and `atof`,
  whose results on unusual text (hexadecimal floats, `nan(...)`, overflow, trailing text) differ
  between C libraries. `number` gives glibc's results in the C locale, and the tests compare it
  with glibc's. On other C libraries cgltf can read such numbers differently; the port reads
  them the same way everywhere.
- **Floats in written text.** cgltf prints floats with `snprintf`'s `%.9g`. `number.formatFloat`
  gives glibc's text in the C locale, and the tests compare it with glibc's `snprintf`. In a
  locale with a decimal comma, cgltf turns the comma of a single float back into a point but
  not the commas in an array of floats; the port always writes points.
- **GLB sizes on 64-bit big-endian machines.** cgltf copies the first four bytes of the
  GLB's 64-bit total length, which there are its high half. The port writes the low 32 bits
  on every machine, which is what cgltf writes on a little-endian one.
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
- **Decoding in place.** `decodeString` returns the decoded text, where cgltf returns its
  length: the text shrinks when it had escapes, and a slice kept from before, such as a name
  in a `Gltf`, keeps its old length. Both stop at the first NUL, as C strings do, and a
  file URI's `%00` ends the path `loadBuffers` opens, as in cgltf.
- **Writing.** `write` writes the text to an `std.Io.Writer`, where cgltf writes it into a
  buffer of a given size and adds a NUL; the size cgltf returns for a null buffer is the
  count of an `std.Io.Writer.Discarding`, plus one for that NUL. `writeFile` takes the file
  type, where cgltf reads it from its options, and writes the JSON twice, once to count it
  and once to the file, so it allocates nothing.
- **Write errors.** `writeFile` returns `error.IoError` when writing or flushing the file
  fails; cgltf ignores the results of `fwrite` and `fclose` and returns success.
- **Extras with a NUL.** Extras without `data` are written from the JSON at their offsets,
  up to the first NUL, as cgltf's `%.*s` writes them. cgltf counts the whole range in its
  size and moves its cursor past it, leaving the bytes after the NUL unwritten; the port
  counts what it writes. jsmn stops at a NUL, so this needs JSON text a caller changed after
  parsing.
- **Empty arrays.** A node's `children`, a skin's `joints` and a scene's `nodes` are `null`
  when the file has none and empty when it has `[]`, because cgltf writes back the empty
  arrays it read.
- **`min_version`.** cgltf writes the asset's minimum version under the name `min_version`,
  where glTF and cgltf's parser use `minVersion`, so text written and read again loses it.
  The port writes the same text.
- **Lifetimes.** A `Gltf` from `parse` points into the bytes it was given, as cgltf's
  `cgltf_data` does, so they must outlive it. Slices into a `Gltf` are stale after `deinit`.
