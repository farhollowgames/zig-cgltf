//! Buffers: from the GLB's BIN chunk, from base64 data URIs and from
//! files beside the glTF; and the string decoders cgltf offers with them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cgltf = @import("cgltf.zig");
const Error = cgltf.Error;
const Gltf = cgltf.Gltf;

/// The default `FileReader.read`: `path` relative to the working
/// directory, as C's `fopen` reads it.
pub fn defaultRead(
    context: ?*anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    size: usize,
) Error![]u8 {
    _ = context;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var file_size = size;
    if (file_size == 0) {
        const length = file.length(io) catch return error.IoError;
        file_size = std.math.cast(usize, length) orelse return error.OutOfMemory;
    }
    const data = try gpa.alloc(u8, file_size);
    errdefer gpa.free(data);
    const read_size = file.readPositionalAll(io, data, 0) catch return error.IoError;
    if (read_size != file_size) return error.IoError;
    return data;
}

/// The default `FileReader.release`.
pub fn defaultRelease(context: ?*anyopaque, gpa: Allocator, data: []u8) void {
    _ = context;
    gpa.free(data);
}

fn base64Index(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

const base64_chunk_chars = 64;
const base64_chunk_bytes = base64_chunk_chars / 4 * 3;
const Chars = @Vector(base64_chunk_chars, u8);
const Sextets = @Vector(base64_chunk_chars / 4, u8);

/// Every fourth lane of a chunk's characters, from lane `first`.
fn quadLanes(comptime first: usize) [base64_chunk_chars / 4]i32 {
    var mask: [base64_chunk_chars / 4]i32 = undefined;
    for (&mask, 0..) |*lane, i| lane.* = @intCast(4 * i + first);
    return mask;
}

/// Lane i of the first vector, then lane i of the second, for each i.
fn pairLanes() [base64_chunk_chars / 2]i32 {
    var mask: [base64_chunk_chars / 2]i32 = undefined;
    for (0..base64_chunk_chars / 4) |i| {
        mask[2 * i] = @intCast(i);
        mask[2 * i + 1] = ~@as(i32, @intCast(i));
    }
    return mask;
}

/// Lanes 2i and 2i + 1 of the first vector, then lane i of the second.
fn tripleLanes() [base64_chunk_bytes]i32 {
    var mask: [base64_chunk_bytes]i32 = undefined;
    for (0..base64_chunk_chars / 4) |i| {
        mask[3 * i] = @intCast(2 * i);
        mask[3 * i + 1] = @intCast(2 * i + 1);
        mask[3 * i + 2] = ~@as(i32, @intCast(i));
    }
    return mask;
}

/// Decodes a chunk of base64 characters into `out`, or returns false,
/// writing nothing, when one is outside the alphabet. Zig 0.17 leaves a
/// loop over a runtime length scalar, so the lanes are written out.
fn decodeBase64Chunk(text: *const [base64_chunk_chars]u8, out: *[base64_chunk_bytes]u8) bool {
    const c: Chars = text.*;
    const upper = c -% @as(Chars, @splat('A')) < @as(Chars, @splat(26));
    const lower = c -% @as(Chars, @splat('a')) < @as(Chars, @splat(26));
    const digit = c -% @as(Chars, @splat('0')) < @as(Chars, @splat(10));
    const plus = c == @as(Chars, @splat('+'));
    const slash = c == @as(Chars, @splat('/'));
    if (@reduce(.Or, ~(upper | lower | digit | plus | slash))) return false;
    var index = c -% @as(Chars, @splat('A'));
    index = @select(u8, lower, c -% @as(Chars, @splat('a' - 26)), index);
    index = @select(u8, digit, c +% @as(Chars, @splat(52 -% '0')), index);
    index = @select(u8, plus, @as(Chars, @splat(62)), index);
    index = @select(u8, slash, @as(Chars, @splat(63)), index);
    const s0: Sextets = @shuffle(u8, index, undefined, quadLanes(0));
    const s1: Sextets = @shuffle(u8, index, undefined, quadLanes(1));
    const s2: Sextets = @shuffle(u8, index, undefined, quadLanes(2));
    const s3: Sextets = @shuffle(u8, index, undefined, quadLanes(3));
    const byte0 = s0 << @splat(2) | s1 >> @splat(4);
    const byte1 = s1 << @splat(4) | s2 >> @splat(2);
    const byte2 = s2 << @splat(6) | s3;
    const bytes01 = @shuffle(u8, byte0, byte1, pairLanes());
    out.* = @shuffle(u8, bytes01, byte2, tripleLanes());
    return true;
}

/// cgltf's `cgltf_load_buffer_base64`: the first `size` bytes `base64`
/// encodes, in memory from `gpa`. The text ends at its end or at a NUL;
/// any character outside the base64 alphabet before `size` bytes, `=`
/// included, is an `IoError`.
pub fn loadBufferBase64(gpa: Allocator, size: usize, base64: []const u8) Error![]u8 {
    const data = try gpa.alloc(u8, size);
    errdefer gpa.free(data);
    // Whole chunks first: four characters make three bytes, so a chunk
    // ends where the bit buffer below is empty. A chunk with a character
    // outside the alphabet is left to the loop below, which refuses it.
    var next: usize = 0;
    var written: usize = 0;
    while (written + base64_chunk_bytes <= size and next + base64_chunk_chars <= base64.len) {
        const text = base64[next..][0..base64_chunk_chars];
        if (!decodeBase64Chunk(text, data[written..][0..base64_chunk_bytes])) break;
        next += base64_chunk_chars;
        written += base64_chunk_bytes;
    }
    var buffer: u32 = 0;
    var buffer_bits: u5 = 0;
    for (data[written..]) |*byte| {
        while (buffer_bits < 8) {
            const c = if (next < base64.len) base64[next] else 0;
            next += 1;
            const index = base64Index(c) orelse return error.IoError;
            buffer = buffer << 6 | index;
            buffer_bits += 6;
        }
        byte.* = @truncate(buffer >> (buffer_bits - 8));
        buffer_bits -= 8;
    }
    return data;
}

fn unhex(c: u8) i32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => -1,
    };
}

/// cgltf's `cgltf_decode_string`: decodes the JSON escapes of `string` in
/// place, up to its first NUL, and returns the decoded text, with a NUL
/// written after it. The decoded text is shorter than `string` when there
/// were escapes, so a slice kept from before, such as a name in a `Gltf`,
/// keeps its old length: take the returned slice in its place. An escape
/// that runs past the NUL at `string.len` is `error.OutOfBounds`: cgltf
/// reads past the end there. A `\u` escape with other characters than hex
/// digits decodes as cgltf decodes it, from their value of -1.
pub fn decodeString(string: [:0]u8) Error![:0]u8 {
    const len = string.len;
    var read = try spanToEscape(string, 0);
    if (string[read] == 0) return string[0..read :0];
    var write: usize = 0;
    var last: usize = 0;
    while (true) {
        const written = read - last;
        std.mem.copyForwards(u8, string[write..][0..written], string[last..read]);
        write += written;
        if (string[read] == 0) break;
        // `read` was at a backslash, before the NUL at `len`.
        read += 1;
        const escape = string[read];
        read += 1;
        switch (escape) {
            '"', '/', '\\' => |c| {
                string[write] = c;
                write += 1;
            },
            'b', 'f', 'r', 'n', 't' => {
                string[write] = switch (escape) {
                    'b' => 0x08,
                    'f' => 0x0C,
                    'r' => '\r',
                    'n' => '\n',
                    else => '\t',
                };
                write += 1;
            },
            'u' => {
                // The four characters may include the NUL at `len`.
                if (read + 4 > len + 1) return error.OutOfBounds;
                var character: i32 = 0;
                for (0..4) |i| {
                    // C shifts a negative int here; two's complement as
                    // every compiler does it.
                    character = (character << 4) +% unhex(string.ptr[read + i]);
                }
                read += 4;
                const bits: u32 = @bitCast(character);
                if (character <= 0x7F) {
                    string[write] = @truncate(bits);
                    write += 1;
                } else if (character <= 0x7FF) {
                    string[write] = @truncate(0xC0 | (bits >> 6));
                    string[write + 1] = @truncate(0x80 | (bits & 0x3F));
                    write += 2;
                } else {
                    string[write] = @truncate(0xE0 | (bits >> 12));
                    string[write + 1] = @truncate(0x80 | ((bits >> 6) & 0x3F));
                    string[write + 2] = @truncate(0x80 | (bits & 0x3F));
                    write += 3;
                }
            },
            else => {},
        }
        last = read;
        read = try spanToEscape(string, read);
    }
    string[write] = 0;
    return string[0..write :0];
}

/// C's `strcspn(string + from, "\\")` as an index: the first backslash or
/// NUL from `from` on. `from` may be the NUL at `string.len`, not past it.
fn spanToEscape(string: [:0]const u8, from: usize) Error!usize {
    if (from > string.len) return error.OutOfBounds;
    for (string.ptr[from .. string.len + 1], from..) |c, i| {
        if (c == '\\' or c == 0) return i;
    }
    unreachable;
}

/// cgltf's `cgltf_decode_uri`: decodes `%XX` escapes of `uri` in place,
/// writes a NUL after the result and returns its length.
pub fn decodeUri(uri: [:0]u8) usize {
    var write: usize = 0;
    var i: usize = 0;
    while (i < uri.len and uri[i] != 0) {
        if (uri[i] == '%') {
            const ch1 = unhex(uri[i + 1]);
            if (ch1 >= 0) {
                const ch2 = unhex(uri[i + 2]);
                if (ch2 >= 0) {
                    uri[write] = @intCast(ch1 * 16 + ch2);
                    write += 1;
                    i += 3;
                    continue;
                }
            }
        }
        uri[write] = uri[i];
        write += 1;
        i += 1;
    }
    uri[write] = 0;
    return write;
}

/// The path of `uri` beside `gltf_path`, in `memory`: everything up to
/// its last `/` or `\`, then the URI with its `%XX` escapes decoded, up
/// to the first NUL they give.
/// `memory` is `pathSize` bytes.
fn combinePaths(memory: []u8, gltf_path: []const u8, uri: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, gltf_path, "/\\");
    const prefix = if (slash) |at| at + 1 else 0;
    @memcpy(memory[0..prefix], gltf_path[0..prefix]);
    @memcpy(memory[prefix..][0..uri.len], uri);
    memory[prefix + uri.len] = 0;
    const decoded = decodeUri(memory[prefix .. prefix + uri.len :0]);
    // A `%00` ends the path, as the NUL ends cgltf's C string.
    const path = memory[0 .. prefix + decoded];
    return path[0 .. std.mem.indexOfScalar(u8, path, 0) orelse path.len];
}

fn pathSize(gltf_path: []const u8, uri: []const u8) usize {
    return gltf_path.len + uri.len + 1;
}

/// cgltf's `cgltf_load_buffers`: points the first buffer of a GLB at its
/// BIN chunk, decodes base64 data URIs, and reads other URIs as files
/// beside `gltf_path` with the file reader `gltf` was parsed with. With no
/// `gltf_path`, a file URI is `error.UnknownFormat`.
pub fn loadBuffers(gltf: *Gltf, io: Io, gltf_path: ?[]const u8) Error!void {
    const gpa = gltf.arena.child_allocator;
    if (gltf.buffers.len > 0 and gltf.buffers[0].data == null and gltf.buffers[0].uri == null) {
        if (gltf.bin) |bin| {
            if (bin.len < gltf.buffers[0].size) return error.DataTooShort;
            gltf.buffers[0].data = bin;
            gltf.buffers[0].data_free_method = .none;
        }
    }
    for (gltf.buffers) |*buffer| {
        if (buffer.data != null) continue;
        const uri = buffer.uri orelse continue;
        if (std.mem.startsWith(u8, uri, "data:")) {
            const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.UnknownFormat;
            if (comma < 7 or !std.mem.eql(u8, uri[comma - 7 .. comma], ";base64")) {
                return error.UnknownFormat;
            }
            buffer.data_free_method = .memory_free;
            // From `gpa`, not the arena: the size is the file's, and can be
            // more than any allocator can give.
            buffer.data = try loadBufferBase64(gpa, buffer.size, uri[comma + 1 ..]);
        } else if (std.mem.indexOf(u8, uri, "://") == null and gltf_path != null) {
            const memory = try gpa.alloc(u8, pathSize(gltf_path.?, uri));
            defer gpa.free(memory);
            const path = combinePaths(memory, gltf_path.?, uri);
            buffer.data_free_method = .file_release;
            const reader = gltf.file_reader;
            buffer.data = try reader.read(reader.context, gpa, io, path, buffer.size);
        } else {
            return error.UnknownFormat;
        }
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "base64 decodes and stops at the end of the text" {
    const data = try loadBufferBase64(testing.allocator, 5, "aGVsbG8=");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello", data);
    try testing.expectError(error.IoError, loadBufferBase64(testing.allocator, 6, "aGVsbG8="));
    try testing.expectError(error.IoError, loadBufferBase64(testing.allocator, 9, "aGVsbG8"));
}

test "base64 over whole chunks decodes, and refuses a bad character only where it reads one" {
    var prng = std.Random.DefaultPrng.init(0x6261_7365_3634);
    const random = prng.random();
    var raw: [300]u8 = undefined;
    var text: [400]u8 = undefined;
    for (0..2000) |_| {
        const raw_len = random.uintLessThan(usize, raw.len + 1);
        random.bytes(raw[0..raw_len]);
        const encoded = std.base64.standard.Encoder.encode(&text, raw[0..raw_len]);
        const size = random.uintLessThan(usize, raw_len + 1);
        const data = try loadBufferBase64(testing.allocator, size, encoded);
        try testing.expectEqualSlices(u8, raw[0..size], data);
        testing.allocator.free(data);

        if (encoded.len == 0) continue;
        const bad = random.uintLessThan(usize, encoded.len);
        text[bad] = if (random.boolean()) '=' else 0;
        const chars_read = std.math.divCeil(usize, size * 8, 6) catch unreachable;
        if (bad < chars_read) {
            const refused = loadBufferBase64(testing.allocator, size, encoded);
            try testing.expectError(error.IoError, refused);
        } else {
            const rest = try loadBufferBase64(testing.allocator, size, encoded);
            try testing.expectEqualSlices(u8, raw[0..size], rest);
            testing.allocator.free(rest);
        }
    }
}

test "decodeString decodes escapes and refuses a cut one" {
    var text = "a\\n\\u00e9\\\"b".*;
    try testing.expectEqualStrings("a\n\xc3\xa9\"b", try decodeString(&text));
    var cut = "ab\\".*;
    try testing.expectError(error.OutOfBounds, decodeString(&cut));
    var short = "\\u12".*;
    try testing.expectError(error.OutOfBounds, decodeString(&short));
}

test "decodeUri decodes percent escapes" {
    var text = "a%20b%2".*;
    const n = decodeUri(&text);
    try testing.expectEqualStrings("a b%2", text[0..n]);
}
