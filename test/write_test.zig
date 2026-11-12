//! The writer against cgltf_write.h: every sample model, parsed by each
//! side and written by each, must give the same text byte for byte, and
//! the same files from `writeFile`; the port's text must parse again, in
//! both, to the same result.

const std = @import("std");
const cgltf = @import("cgltf");
const c = @import("c");
const oracle = @import("oracle.zig");
const samples = @import("samples.zig");
const compare = @import("compare.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// cgltf_write's text, without its NUL, owned by `gpa`, after checking its
/// size query against the text it writes.
fn originalText(gpa: Allocator, original: *const c.cgltf_data) ![]u8 {
    var options = std.mem.zeroes(c.cgltf_options);
    const size = c.cgltf_write(&options, null, 0, original);
    const text = try gpa.alloc(u8, size);
    errdefer gpa.free(text);
    const written = c.cgltf_write(&options, text.ptr, size, original);
    if (written != size) return compare.fail("cgltf_write wrote {d} bytes of {d}", .{ written, size });
    if (text[size - 1] != 0) return compare.fail("cgltf_write's text has no NUL", .{});
    return gpa.realloc(text, size - 1);
}

/// Both sides' text for the same file, which must be the same; returns the
/// port's, owned by `gpa`.
pub fn expectSameText(gpa: Allocator, original: *const c.cgltf_data, port: *const cgltf.Gltf) ![]u8 {
    const expected = try originalText(gpa, original);
    defer gpa.free(expected);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try cgltf.write(port, &out.writer);
    const actual = out.written();
    if (!std.mem.eql(u8, expected, actual)) {
        const at = std.mem.indexOfDiff(u8, expected, actual).?;
        const from = at -| 60;
        std.debug.print("original: ...{s}\nport:     ...{s}\n", .{
            expected[from..@min(at + 40, expected.len)],
            actual[from..@min(at + 40, actual.len)],
        });
        return compare.fail("written text differs at byte {d}", .{at});
    }
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try cgltf.write(port, &counter.writer);
    if (counter.fullCount() != actual.len) return compare.fail("counted {d} bytes", .{counter.fullCount()});
    return out.toOwnedSlice();
}

/// The extras of every object of the file's top-level arrays, the
/// primitives' and the file's own, made to be written from their offsets
/// into the JSON, as cgltf writes extras without `data`.
fn dropExtrasData(original: *c.cgltf_data, port: *cgltf.Gltf) void {
    original.extras.data = null;
    port.extras.data = null;
    original.asset.extras.data = null;
    port.asset.extras.data = null;
    inline for (.{
        "accessors", "buffer_views", "buffers",  "images", "textures", "samplers",
        "materials", "meshes",       "nodes",    "scenes", "skins",    "animations",
        "cameras",   "lights",       "variants",
    }) |name| {
        for (@field(port, name), 0..) |*item, i| {
            item.extras.data = null;
            @field(original, name)[i].extras.data = null;
        }
    }
    for (port.meshes, 0..) |*mesh, m| {
        for (mesh.primitives, 0..) |*primitive, p| {
            primitive.extras.data = null;
            original.meshes[m].primitives[p].extras.data = null;
        }
    }
}

const Parsed = struct {
    original: [*c]c.cgltf_data,
    port: cgltf.Gltf,

    fn deinit(parsed: *Parsed) void {
        c.cgltf_free(parsed.original);
        parsed.port.deinit();
    }
};

fn parseBoth(gpa: Allocator, io: std.Io, path: [:0]const u8) !?Parsed {
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    const result = c.cgltf_parse_file(&options, path, &original);
    var port = cgltf.parseFile(gpa, io, path, .{}) catch {
        if (original != null) c.cgltf_free(original);
        try testing.expect(result != c.cgltf_result_success);
        return null;
    };
    if (result != c.cgltf_result_success) {
        port.deinit();
        return compare.fail("{s}: only the port parses", .{path});
    }
    return .{ .original = original, .port = port };
}

test "write: every sample model writes as the original writes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    for (paths) |path| {
        var parsed = (try parseBoth(gpa, io, path)) orelse continue;
        defer parsed.deinit();
        errdefer std.debug.print("model: {s}\n", .{path});
        gpa.free(try expectSameText(gpa, parsed.original, &parsed.port));
        dropExtrasData(parsed.original, &parsed.port);
        gpa.free(try expectSameText(gpa, parsed.original, &parsed.port));
    }
}

test "write: every sample model's text parses again in both, as the original's" {
    const gpa = testing.allocator;
    const io = testing.io;
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    for (paths) |path| {
        var parsed = (try parseBoth(gpa, io, path)) orelse continue;
        defer parsed.deinit();
        errdefer std.debug.print("model: {s}\n", .{path});
        const text = try expectSameText(gpa, parsed.original, &parsed.port);
        defer gpa.free(text);
        // Parsed, loaded beside the model, validated and read by both.
        const reached = try oracle.expectSame(gpa, io, .{ .bytes = .{ .data = text, .gltf_path = path } }, .{});
        if (reached == .refused) return compare.fail("the written text does not parse", .{});
        // Parsed from that text and written again, by both. It is not
        // always the same text: cgltf writes `minVersion` as `min_version`,
        // which it does not read back.
        var options = std.mem.zeroes(c.cgltf_options);
        var original: [*c]c.cgltf_data = null;
        try testing.expect(c.cgltf_parse(&options, text.ptr, text.len, &original) == c.cgltf_result_success);
        defer c.cgltf_free(original);
        var again = try cgltf.parse(gpa, text, .{});
        defer again.deinit();
        gpa.free(try expectSameText(gpa, original, &again));
    }
}

test "write: files of every sample model, as glTF and GLB, are the original's" {
    const gpa = testing.allocator;
    const io = testing.io;
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir);
    const original_path = try std.fs.path.joinZ(gpa, &.{ dir, "original" });
    defer gpa.free(original_path);
    const port_path = try std.fs.path.join(gpa, &.{ dir, "port" });
    defer gpa.free(port_path);
    for (paths) |path| {
        var parsed = (try parseBoth(gpa, io, path)) orelse continue;
        defer parsed.deinit();
        errdefer std.debug.print("model: {s}\n", .{path});
        for ([_]cgltf.FileType{ .gltf, .glb }) |file_type| {
            var options = std.mem.zeroes(c.cgltf_options);
            options.type = @backingInt(file_type);
            try testing.expect(c.cgltf_write_file(&options, original_path, parsed.original) == c.cgltf_result_success);
            try cgltf.writeFile(&parsed.port, io, port_path, file_type);
            const cwd = std.Io.Dir.cwd();
            const expected = try cwd.readFileAlloc(io, original_path, gpa, .unlimited);
            defer gpa.free(expected);
            const actual = try cwd.readFileAlloc(io, port_path, gpa, .unlimited);
            defer gpa.free(actual);
            if (!std.mem.eql(u8, expected, actual)) {
                return compare.fail("{t} file differs at byte {d}", .{ file_type, std.mem.indexOfDiff(u8, expected, actual).? });
            }
        }
    }
}

test "write: a file that cannot be created is not found, as the original's" {
    var gltf = try cgltf.parse(testing.allocator, "{\"asset\":{\"version\":\"2.0\"}}", .{});
    defer gltf.deinit();
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    const json = "{\"asset\":{\"version\":\"2.0\"}}";
    try testing.expect(c.cgltf_parse(&options, json.ptr, json.len, &original) == c.cgltf_result_success);
    defer c.cgltf_free(original);
    const path = "no/such/directory/model.gltf";
    try testing.expect(c.cgltf_write_file(&options, path, original) == c.cgltf_result_file_not_found);
    try testing.expectError(error.FileNotFound, cgltf.writeFile(&gltf, testing.io, path, .gltf));
}
