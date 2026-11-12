//! Where the original reads or writes out of bounds, never returns, or
//! overflows a size, the port returns an error instead. Each test here
//! builds such an input and checks the port's refusal; the original is
//! not run on them. doc/parity.md lists them.
//!
//! Also here: failed allocations, and a file reader of the caller's.

const std = @import("std");
const cgltf = @import("cgltf");
const samples = @import("samples.zig");

const testing = std.testing;

fn parseLoaded(json: []const u8) !cgltf.Gltf {
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    errdefer gltf.deinit();
    try cgltf.loadBuffers(&gltf, testing.io, null);
    return gltf;
}

test "refusal: validate reads indices past the buffer's memory" {
    // The view lies past the end of the buffer, which validate checks only
    // after the accessors; cgltf reads the sparse indices there first.
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"data:;base64,AAAAAA=="}],
        \\"bufferViews":[{"buffer":0,"byteOffset":2,"byteLength":64}],
        \\"accessors":[{"componentType":5126,"type":"SCALAR","count":8,
        \\"sparse":{"count":8,"indices":{"bufferView":0,"componentType":5125},"values":{"bufferView":0}}}]}
    );
    defer gltf.deinit();
    try testing.expectError(error.OutOfBounds, cgltf.validate(&gltf));
}

test "refusal: validate reads primitive indices past the buffer's memory" {
    // A buffer's data shorter than its size, as a caller may set it.
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":64}],
        \\"bufferViews":[{"buffer":0,"byteLength":64}],
        \\"accessors":[{"bufferView":0,"componentType":5125,"type":"SCALAR","count":16},
        \\{"componentType":5126,"type":"VEC3","count":3}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":1},"indices":0}]}]}
    );
    defer gltf.deinit();
    const short: [8]u8 = @splat(0);
    gltf.buffers[0].data = &short;
    try testing.expectError(error.OutOfBounds, cgltf.validate(&gltf));
}

test "refusal: accessor reads past the buffer's memory" {
    // Without validate, an accessor past its view and buffer.
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"data:;base64,AAAAAA=="}],
        \\"bufferViews":[{"buffer":0,"byteLength":4}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"type":"VEC4","count":4}]}
    );
    defer gltf.deinit();
    const accessor = &gltf.accessors[0];
    var out: [16]f32 = undefined;
    try testing.expectError(error.OutOfBounds, cgltf.readFloat(&gltf, accessor, 0, &out));
    var out_u: [4]u32 = undefined;
    try testing.expectError(error.OutOfBounds, cgltf.readUint(&gltf, accessor, 3, &out_u));
    var all: [16]f32 = undefined;
    try testing.expectError(error.OutOfBounds, cgltf.unpackFloats(&gltf, accessor, &all));
}

test "refusal: a view's data past the buffer's memory" {
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"data:;base64,AAAAAA=="}],
        \\"bufferViews":[{"buffer":0,"byteOffset":8,"byteLength":4}]}
    );
    defer gltf.deinit();
    try testing.expectError(error.OutOfBounds, cgltf.bufferViewData(&gltf, 0));
}

test "refusal: unpacking indices of a vector accessor reads past its elements" {
    // cgltf reads count * components indices at one per element's stride.
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"data:;base64,AAECAw=="}],
        \\"bufferViews":[{"buffer":0,"byteLength":4}],
        \\"accessors":[{"bufferView":0,"componentType":5121,"type":"VEC2","count":2}]}
    );
    defer gltf.deinit();
    var out: [4]u16 = undefined;
    try testing.expectError(error.OutOfBounds, cgltf.unpackIndices(u16, &gltf, &gltf.accessors[0], &out));
    try testing.expectError(error.OutOfBounds, cgltf.readIndex(&gltf, &gltf.accessors[0], 2));
    try testing.expectEqual(@as(usize, 2), try cgltf.readIndex(&gltf, &gltf.accessors[0], 1));
    // Two fit.
    try testing.expectEqual(@as(usize, 2), try cgltf.unpackIndices(u16, &gltf, &gltf.accessors[0], out[0..2]));
}

test "refusal: a sparse index past the output is not written" {
    // cgltf writes the sparse value at index 3 into an output of 2 floats.
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":8,"uri":"data:;base64,AwAAAAAAgD8="}],
        \\"bufferViews":[{"buffer":0,"byteLength":8}],
        \\"accessors":[{"componentType":5126,"type":"SCALAR","count":4,
        \\"sparse":{"count":1,"indices":{"bufferView":0,"componentType":5125},"values":{"bufferView":0,"byteOffset":4}}}]}
    );
    defer gltf.deinit();
    var short: [2]f32 = undefined;
    try testing.expectError(error.OutOfBounds, cgltf.unpackFloats(&gltf, &gltf.accessors[0], &short));
    var full: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try cgltf.unpackFloats(&gltf, &gltf.accessors[0], &full));
    try testing.expectEqual([4]f32{ 0, 0, 0, 1 }, full);
}

test "refusal: a loop of parents is an error, where the world transform never returns" {
    var gltf = try parseLoaded(
        \\{"asset":{"version":"2.0"},"nodes":[{"children":[1]},{"children":[0]}]}
    );
    defer gltf.deinit();
    try testing.expectError(error.ParentCycle, cgltf.transformWorld(&gltf, 0));
    try testing.expectError(error.InvalidGltf, cgltf.validate(&gltf));
}

test "refusal: copying extras into a buffer too small for cgltf's NUL" {
    var gltf = try cgltf.parse(testing.allocator, "{\"asset\":{\"version\":\"2.0\"},\"extras\":{\"abc\":1}}", .{});
    defer gltf.deinit();
    const size = try cgltf.copyExtrasJson(&gltf, &gltf.extras, null);
    try testing.expectEqual(@as(usize, 10), size);
    var dest: [16]u8 = undefined;
    // Sizes 0, and the text's length and one less, write past the end.
    try testing.expectError(error.OutOfBounds, cgltf.copyExtrasJson(&gltf, &gltf.extras, dest[0..0]));
    try testing.expectError(error.OutOfBounds, cgltf.copyExtrasJson(&gltf, &gltf.extras, dest[0..9]));
    try testing.expectError(error.OutOfBounds, cgltf.copyExtrasJson(&gltf, &gltf.extras, dest[0..8]));
    try testing.expectEqual(@as(usize, 9), try cgltf.copyExtrasJson(&gltf, &gltf.extras, dest[0..10]));
    try testing.expectEqualStrings("{\"abc\":1}", dest[0..9]);
    try testing.expectEqual(@as(usize, 4), try cgltf.copyExtrasJson(&gltf, &gltf.extras, dest[0..5]));
    // Offsets a caller changed past the text.
    var moved = gltf.extras;
    moved.end_offset = gltf.json.len + 5;
    try testing.expectError(error.OutOfBounds, cgltf.copyExtrasJson(&gltf, &moved, &dest));
}

test "refusal: decoding a string whose escape runs past its end" {
    for ([_][]const u8{ "\\", "ab\\", "\\u", "\\u1", "\\u12", "\\u123" }) |text| {
        var buffer: [8:0]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        try testing.expectError(error.OutOfBounds, cgltf.decodeString(buffer[0..text.len :0]));
    }
}

test "refusal: a token count whose array size overflows is out of memory" {
    // cgltf's size computation wraps there, and it writes past a small
    // allocation.
    const json = "{\"asset\":{\"version\":\"2.0\"}}";
    try testing.expectError(error.OutOfMemory, cgltf.parse(testing.allocator, json, .{
        .json_token_count = std.math.maxInt(usize),
    }));
    try testing.expectError(error.OutOfMemory, cgltf.parse(testing.allocator, json, .{
        .json_token_count = std.math.maxInt(usize) / 16,
    }));
}

test "refusal: writing extras whose offsets lie outside the JSON" {
    // cgltf writes extras without `data` from the JSON at their offsets,
    // unchecked.
    var gltf = try cgltf.parse(testing.allocator, "{\"asset\":{\"version\":\"2.0\"},\"extras\":{\"a\":1}}", .{});
    defer gltf.deinit();
    gltf.extras.data = null;
    var out: std.Io.Writer.Discarding = .init(&.{});
    try cgltf.write(&gltf, &out.writer);
    gltf.extras.end_offset = gltf.json.len + 1;
    try testing.expectError(error.OutOfBounds, cgltf.write(&gltf, &out.writer));
    gltf.extras.start_offset = gltf.json.len;
    gltf.extras.end_offset = 2;
    try testing.expectError(error.OutOfBounds, cgltf.write(&gltf, &out.writer));
}

test "refusal: writing into an output too small for the text" {
    // cgltf's snprintf calls move past a short buffer's end, and the next
    // call writes past it.
    var gltf = try cgltf.parse(testing.allocator, "{\"asset\":{\"version\":\"2.0\"}}", .{});
    defer gltf.deinit();
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try cgltf.write(&gltf, &counter.writer);
    const size: usize = @intCast(counter.fullCount());
    var buffer: [256]u8 = undefined;
    for (0..size) |n| {
        var out: std.Io.Writer = .fixed(buffer[0..n]);
        try testing.expectError(error.WriteFailed, cgltf.write(&gltf, &out));
    }
    var out: std.Io.Writer = .fixed(buffer[0..size]);
    try cgltf.write(&gltf, &out);
}

fn parseLoadValidate(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    var gltf = try cgltf.parseFile(allocator, testing.io, path, .{});
    defer gltf.deinit();
    try cgltf.loadBuffers(&gltf, testing.io, path);
    try cgltf.validate(&gltf);
}

test "a failed allocation at any point of parsing and loading a model leaks nothing" {
    // Each allocation fails in turn, and the run returns OutOfMemory or,
    // where the arena grew in place rather than allocate, succeeds; the
    // testing allocator fails the test on any leak. std's
    // checkAllAllocationFailures would need the arena's count of
    // allocations to be the same on every run, which in-place growth
    // breaks.
    const gpa = testing.allocator;
    const io = testing.io;
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    var models: usize = 0;
    for (paths) |path| {
        if (!std.mem.endsWith(u8, path, "/Box/glTF/Box.gltf") and
            !std.mem.endsWith(u8, path, "/Box/glTF-Embedded/Box.gltf") and
            !std.mem.endsWith(u8, path, "/BoxAnimated/glTF-Binary/BoxAnimated.glb") and
            !std.mem.endsWith(u8, path, "/MaterialsVariantsShoe/glTF/MaterialsVariantsShoe.gltf")) continue;
        models += 1;
        var counting = std.testing.FailingAllocator.init(gpa, .{});
        try parseLoadValidate(counting.allocator(), path);
        const needed = counting.alloc_index;
        try testing.expect(needed > 3);
        for (0..needed) |fail_index| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            parseLoadValidate(failing.allocator(), path) catch |err| {
                if (err != error.OutOfMemory) {
                    std.debug.print("model {s}, allocation {d}: {t}\n", .{ path, fail_index, err });
                    return err;
                }
            };
        }
    }
    try testing.expectEqual(@as(usize, 4), models);
}

test "a file reader of the caller's reads the file and the buffers, and releases them" {
    const Reader = struct {
        reads: usize = 0,
        releases: usize = 0,

        fn read(context: ?*anyopaque, gpa: std.mem.Allocator, _: std.Io, path: []const u8, size: usize) cgltf.Error![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            if (std.mem.endsWith(u8, path, "model.gltf")) {
                return gpa.dupe(u8, "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":3,\"uri\":\"a%20b.bin\"}]}");
            }
            if (!std.mem.eql(u8, path, "dir/a b.bin")) return error.FileNotFound;
            if (size != 3) return error.IoError;
            return gpa.dupe(u8, "xyz");
        }

        fn release(context: ?*anyopaque, gpa: std.mem.Allocator, data: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.releases += 1;
            gpa.free(data);
        }
    };
    var reader: Reader = .{};
    var gltf = try cgltf.parseFile(testing.allocator, testing.io, "dir/model.gltf", .{ .file_reader = .{
        .context = &reader,
        .read = Reader.read,
        .release = Reader.release,
    } });
    try cgltf.loadBuffers(&gltf, testing.io, "dir/model.gltf");
    try testing.expectEqualStrings("xyz", gltf.buffers[0].data.?);
    gltf.deinit();
    try testing.expectEqual(@as(usize, 2), reader.reads);
    try testing.expectEqual(@as(usize, 2), reader.releases);
}
