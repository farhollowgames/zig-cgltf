# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The original

`reference/cgltf/` holds cgltf at tag v1.15 (`85cd623`), copied unmodified;
`reference/shim/cgltf.c` compiles the implementation of `cgltf.h`, and
`reference/shim/cgltf_write.c` that of `cgltf_write.h`. `zig build test` builds them with
Zig's clang at `-O3`, as `-std=c99` with `-ffp-contract=off -fno-fast-math`, so float steps
round as written, as Zig's do, and links them with the C library. Zig's `translate-c` turns
`cgltf.h` and `cgltf_write.h` into the declarations the tests call them through. The Khronos
glTF-Sample-Assets models are a lazy dependency at commit `8f49239`, fetched only for the
tests and the benchmark.

### What is compared

`test/oracle.zig` runs one input through both, step by step: parse (from a file or from
memory), compare; load the buffers, compare; validate, compare; then every helper. After each
step `test/compare.zig` walks every field of every C struct at compile time and compares it
with the port's field of the same name:

- integers, booleans, sizes, offsets and enum values are equal;
- floats are equal as bits;
- strings are equal byte for byte, and a missing string matches only a missing one;
- every pointer is compared as an index into the array it points into, and a null pointer
  matches only `null`;
- extras and unknown extensions are compared as offsets and as JSON text.

A C field the comparison does not handle is a compile error, so a field cannot be left out
by accident. The fields it skips are the ones that are memory and not results: the file
bytes, the JSON and BIN chunk pointers, the callbacks, and the buffers' and views' data
pointers, whose contents the helpers compare. A camera's `type` and `data` are compared as the
port's tagged union.

The helpers, on both sides:

- `readFloat` and `readUint` on every element (up to 65,536 per accessor), with outputs of
  0, 1, 3 and 16 values, and `readIndex` on every element;
- `unpackFloats` with an output of the full count, half of it and one less, and the count
  itself;
- `unpackIndices` into `u8`, `u16` and `u32` outputs, and its count;
- `bufferViewData` on every view, as an offset into its buffer;
- `transformLocal` and `transformWorld` on every node;
- `findAccessor` on every attribute of every primitive, and on the set after it;
- `copyExtrasJson` on every output size up to two past the text's, for the file's, the asset's
  and each node's, mesh's and material's extras.

Every result code must match: the port's error is mapped to cgltf's `cgltf_result`.

The writer, on both sides:

- `cgltf_write` and `write` of every sample model, once with extras as parsed and once with
  extras as JSON offsets only: the texts are compared byte for byte, and the size cgltf
  returns for no buffer with the count of a `std.Io.Writer.Discarding`;
- the written text parsed again by both and compared field by field, then written again and
  compared;
- `cgltf_write_file` and `writeFile` of every sample model as glTF and as GLB, the files
  compared byte for byte, a GLB whose BIN chunk needs padding, and a path that cannot be
  created;
- extras on every kind of object the writer writes, and a fixed output larger than the
  text, whose bytes past the text must be left as cgltf leaves them.

`number.formatFloat` is compared with glibc's `snprintf("%.9g")` on hand-picked floats (ties
at the ninth digit, every power of 2 and of 10 and its neighbours, the edges of the fixed and
the scientific forms, infinities, NaNs and `-0`) and on 220,000 random floats. A probe run
once, outside the tests, compared every positive finite float.

One exception to comparing bits: a transform computed from a NaN may keep the NaN of either
operand of an addition or a product, as the compiler orders them, and neither C nor Zig fixes
that order. Computed transforms therefore count any NaN as equal to any NaN; a node's own
matrix, which both copy, and every other float, NaN included, are compared as bits.

### Tests and counts

`zig build test` runs 66 tests: 16 unit tests in `src/` and 50 tests in `test/`, through
`test/differential.zig`. 35 of the 50 are oracle tests; the other 15 check the port's
refusals, failed allocations and a file reader of the caller's.

| feature | inputs |
| --- | --- |
| parsing, loading, validation and every helper | every `.gltf` and `.glb` file of the sample models (339 files, glTF, GLB, embedded and with files beside them), parsed from a file, and from memory with token counts of 0, 1 and 100 |
| the GLB container's checks | hand-made headers and chunks: bad magic, versions, lengths, chunk types, a missing BIN chunk |
| file types, short input, token counts | forced `gltf` and `glb` on the other kind, inputs shorter than a header, too few tokens |
| JSON the tokenizer and the parser refuse, glTF 1.0 | broken JSON, wrong value kinds, references past their arrays, glTF 1.0 assets |
| numbers | integers and floats in every form C reads: spaces, signs, trailing text, hexadecimal, `inf`, `nan(...)`, overflow |
| strings and extras | escapes of every kind, extras of every JSON type |
| extensions | each of the 21 extensions cgltf reads, with its defaults and with every value set |
| material variants | mappings with missing, repeated and out-of-range variants and materials |
| accessors | every type, component type, normalization, stride and offset |
| sparse accessors | with and without a base view, every index component type and two invalid ones, sorted, unsorted, repeated and too large indices |
| validation | views (meshopt compression included), accessors, meshes, morph targets and weights, nodes and animations that break each check |
| buffers | data URIs of every form cgltf accepts or refuses, other URI schemes, the BIN chunk, files beside the glTF with escaped names, and sizes of 0, short and exact |
| `number` | `atoi`, `atoll` and `atof` against the C library on hand-picked texts, 20,000 random texts and 20,000 random floats printed and read back |
| `decodeString`, `decodeUri` | hand-picked texts, NUL bytes inside included, and 20,000 random texts; both sides decode in place, and every byte of the buffer is compared; a name from a parsed file decoded on both sides |
| `loadBufferBase64` | 20,000 random texts of up to 400 characters, mostly valid with a bad character here and there, so the decoder's 64-character chunks are reached |
| `numComponents`, `componentSize`, `calcSize` | every type and component type |
| `write`, `writeFile` | every sample model as text, as a glTF file and as a GLB file; extras on every object; a padded BIN chunk; 3,000 generated documents |
| `formatFloat` | hand-picked floats and 220,000 random ones, against glibc's `%.9g` |

### Fuzzing

Four oracle tests fuzz whole files:

- **Mutations**: 3,000 cases, each one of the sample models of at most 32 KiB or a file of
  cgltf's own fuzz corpus, changed by random byte edits, insertions from cgltf's AFL
  dictionary, cuts, and changes to GLB headers and chunks, then parsed with a random file
  type and now and then a random token count.
- **Documents**: 4,000 generated glTF documents that use every object, every extension and
  sparse and strided accessors with real buffers. Half keep to the glTF rules, so they get
  through validation and into the helpers; the other half break the rules here and there.
- **Layouts**: 3,000 files of one buffer of random bytes, two views and one accessor of a
  random type, component type, normalization, count, stride and offset, sparse one time in
  three, none of them validated, so the accessor helpers meet every edge of the buffer.

- **Written documents**: 3,000 more generated documents, each written by both sides and
  compared byte for byte, then parsed again from the text and compared; at least 1,000 must
  be written.

Each test counts how far its cases went, and fails if too few got through validation or
failed after parsing, so the fuzzing reaches every step: at least 250 valid cases for the
mutations, 600 for the documents and 50 for the layouts, whose helpers run whether or not
they validate. With the recorded seeds, the mutations refused 2,580 cases at parsing, and of
the rest 15 failed loading, 86 failed validation and 319 were valid; the documents refused
1,892, and 19, 1,205 and 884; the layouts refused none, and 2,893 failed validation and 107
were valid. The floors sit below what other seeds give: seed 13 gave 299 valid mutations.

Every case's seed comes from the test's name and the case's number. `-Dfuzz-seed=N` changes
every seed, and `-Dfuzz-replay=S` runs only the case with seed `S`, which a failing case
prints. Seeds 1 to 4, 11, 12 and 13 have also been run and passed.

### Malformed input

Where cgltf reads or writes out of bounds or never returns, the port returns an error, and
the oracle does not run cgltf on that call. [`doc/parity.md`](parity.md) lists each case
with its test. So that a wrong refusal cannot pass unseen, the oracle works out from cgltf's
own structs, for each refused call, whether cgltf could read past the memory or write past
the output there, and fails the test if it could not; a world transform refused for a loop
must have a loop of parents in cgltf's nodes. The fuzz tests above check every other
malformed input against cgltf's result.

### Failed allocations

A test fails each allocation in turn while parsing, loading and validating four sample
models, and checks that each run returns `error.OutOfMemory` or succeeds, and leaks nothing.

### Determinism

zig-cgltf has no threads and no randomness, and no output depends on addresses.

### Build modes

The tests run in ReleaseSafe by default (`-Dtest-optimize` selects another mode), on
x86-64 Linux with Zig 0.17.0. cgltf is always built with optimization on.

### State

`STATUS.md` marks each item as oracle-tested or benchmarked. None is marked reviewed yet:
that state is set at a release, after the review above.
