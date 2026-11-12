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

test "write: the output's bytes past the text are left as the original leaves them" {
    const json = "{\"asset\":{\"version\":\"2.0\"}}";
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    defer gltf.deinit();
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    try testing.expect(c.cgltf_parse(&options, json.ptr, json.len, &original) == c.cgltf_result_success);
    defer c.cgltf_free(original);
    var expected: [256]u8 = @splat(0xAA);
    const size = c.cgltf_write(&options, &expected, expected.len, original);
    var actual: [256]u8 = @splat(0xAA);
    var out: std.Io.Writer = .fixed(&actual);
    try cgltf.write(&gltf, &out);
    try testing.expectEqual(size - 1, out.end);
    // cgltf's NUL, which the port leaves out as documented.
    actual[size - 1] = 0;
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "write: a GLB whose BIN chunk needs padding is the original's" {
    // No sample GLB has a BIN chunk whose length is not a multiple of four,
    // so the BIN padding is never written by the file tests.
    const json = "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":5}]}";
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    defer gltf.deinit();
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    try testing.expect(c.cgltf_parse(&options, json.ptr, json.len, &original) == c.cgltf_result_success);
    defer c.cgltf_free(original);
    const bin = [_]u8{ 1, 2, 3, 4, 5 };
    original.*.bin = &bin;
    original.*.bin_size = bin.len;
    defer original.*.bin = null;
    gltf.bin = &bin;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir);
    const original_path = try std.fs.path.joinZ(gpa, &.{ dir, "original.glb" });
    defer gpa.free(original_path);
    const port_path = try std.fs.path.join(gpa, &.{ dir, "port.glb" });
    defer gpa.free(port_path);
    var glb_options = std.mem.zeroes(c.cgltf_options);
    glb_options.type = c.cgltf_file_type_glb;
    try testing.expect(c.cgltf_write_file(&glb_options, original_path, original) == c.cgltf_result_success);
    try cgltf.writeFile(&gltf, testing.io, port_path, .glb);
    const cwd = std.Io.Dir.cwd();
    const expected = try cwd.readFileAlloc(testing.io, original_path, gpa, .unlimited);
    defer gpa.free(expected);
    const actual = try cwd.readFileAlloc(testing.io, port_path, gpa, .unlimited);
    defer gpa.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "write: extras on every object write as the original writes them" {
    // The sample models have extras only on the asset, meshes and nodes,
    // and the documents fuzz adds materials, accessors and primitives: the
    // other objects' extras are never written by the oracle tests.
    // cgltf reads a channel's extras from inside its target.
    const json =
        \\{"asset":{"version":"2.0","extras":1},
        \\"buffers":[{"byteLength":4,"extras":2}],
        \\"bufferViews":[{"buffer":0,"byteLength":4,"extras":3}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"SCALAR","extras":4}],
        \\"images":[{"uri":"a.png","extras":5}],
        \\"samplers":[{"extras":6}],
        \\"textures":[{"source":0,"sampler":0,"extras":7}],
        \\"materials":[{"extras":8}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[0],"extras":9}]}},"extras":10}],"extras":11}],
        \\"nodes":[{"extras":12}],
        \\"scenes":[{"nodes":[0],"extras":13}],
        \\"skins":[{"joints":[0],"extras":14}],
        \\"animations":[{"samplers":[{"input":0,"output":0,"extras":15}],"channels":[{"sampler":0,"target":{"node":0,"path":"translation","extras":16}}],"extras":17}],
        \\"cameras":[{"perspective":{"yfov":1,"znear":0.1,"extras":18},"extras":19},{"orthographic":{"xmag":1,"ymag":1,"zfar":2,"znear":1,"extras":20}}],
        \\"extensions":{"KHR_lights_punctual":{"lights":[{"type":"point","extras":21}]},"KHR_materials_variants":{"variants":[{"name":"v","extras":22}]}},
        \\"extras":23}
    ;
    const gpa = testing.allocator;
    var gltf = try cgltf.parse(gpa, json, .{});
    defer gltf.deinit();
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    try testing.expect(c.cgltf_parse(&options, json.ptr, json.len, &original) == c.cgltf_result_success);
    defer c.cgltf_free(original);
    const text = try expectSameText(gpa, original, &gltf);
    defer gpa.free(text);
    // Every one of the 23 extras is in the text.
    try testing.expectEqual(@as(usize, 23), std.mem.count(u8, text, "\"extras\": "));
}
