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

/// cgltf's `cgltf_load_buffer_base64`: the first `size` bytes `base64`
/// encodes, in memory from `gpa`. The text ends at its end or at a NUL;
/// any character outside the base64 alphabet before `size` bytes, `=`
/// included, is an `IoError`.
pub fn loadBufferBase64(gpa: Allocator, size: usize, base64: []const u8) Error![]u8 {
    const data = try gpa.alloc(u8, size);
    errdefer gpa.free(data);
    var buffer: u32 = 0;
    var buffer_bits: u5 = 0;
    var next: usize = 0;
    for (data) |*byte| {
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
/// place, writes a NUL after the result and returns its length. An escape
/// cut off by the end of the string is `error.OutOfBounds`: cgltf reads
/// past the end there. A `\u` escape with other characters than hex
/// digits decodes as cgltf decodes it, from their value of -1.
pub fn decodeString(string: [:0]u8) Error!usize {
    const len = string.len;
    var read = std.mem.indexOfScalar(u8, string, '\\') orelse return len;
    var write: usize = 0;
    var last: usize = 0;
    while (true) {
        const written = read - last;
        std.mem.copyForwards(u8, string[write..][0..written], string[last..read]);
        write += written;
        if (read == len) break;
        read += 1;
        if (read == len) return error.OutOfBounds;
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
                if (len - read < 4) return error.OutOfBounds;
                var character: i32 = 0;
                for (string[read..][0..4]) |c| {
                    // C shifts a negative int here; two's complement as
                    // every compiler does it.
                    character = (character << 4) +% unhex(c);
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
        read += std.mem.indexOfScalar(u8, string[read..], '\\') orelse len - read;
    }
    string[write] = 0;
    return write;
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

/// The path of `uri` beside `gltf_path`: everything up to its last `/` or
/// `\`, then the URI with its `%XX` escapes decoded.
fn combinePaths(gpa: Allocator, gltf_path: []const u8, uri: []const u8) Error![:0]u8 {
    const slash = std.mem.lastIndexOfAny(u8, gltf_path, "/\\");
    const prefix = if (slash) |at| at + 1 else 0;
    const path = try gpa.allocSentinel(u8, prefix + uri.len, 0);
    @memcpy(path[0..prefix], gltf_path[0..prefix]);
    @memcpy(path[prefix..], uri);
    const decoded = decodeUri(path[prefix..]);
    return path[0 .. prefix + decoded :0];
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
            buffer.data = try loadBufferBase64(gltf.arena.allocator(), buffer.size, uri[comma + 1 ..]);
        } else if (std.mem.indexOf(u8, uri, "://") == null and gltf_path != null) {
            const path = try combinePaths(gpa, gltf_path.?, uri);
            defer gpa.free(path);
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

test "decodeString decodes escapes and refuses a cut one" {
    var text = "a\\n\\u00e9\\\"b".*;
    const n = try decodeString(&text);
    try testing.expectEqualStrings("a\n\xc3\xa9\"b", text[0..n]);
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
