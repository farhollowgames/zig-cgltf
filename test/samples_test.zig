//! Every sample model through both: parse, load the buffers, validate,
//! then every accessor helper, transform, lookup and extras copy.

const std = @import("std");
const oracle = @import("oracle.zig");
const samples = @import("samples.zig");

const testing = std.testing;

test "every sample model parses, loads, validates and reads as the original" {
    const gpa = testing.allocator;
    const paths = try samples.modelPaths(gpa, testing.io);
    defer samples.freePaths(gpa, paths);
    try testing.expect(paths.len > 300);
    for (paths) |path| {
        _ = oracle.expectSame(gpa, testing.io, .{ .path = path }, .{}) catch |err| {
            std.debug.print("model: {s}\n", .{path});
            return err;
        };
    }
}

test "every sample model parses from memory with an exact token count as the original" {
    const gpa = testing.allocator;
    const io = testing.io;
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        for ([_]usize{ 0, 1, 100 }) |tokens| {
            _ = oracle.expectSame(gpa, io, .{ .bytes = .{ .data = bytes, .gltf_path = path } }, .{
                .json_token_count = tokens,
            }) catch |err| {
                std.debug.print("model: {s}, tokens {d}\n", .{ path, tokens });
                return err;
            };
        }
    }
}
