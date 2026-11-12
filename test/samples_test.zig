//! Every sample model through both: parse, load the buffers, validate,
//! then every accessor helper, transform, lookup and extras copy.

const std = @import("std");
const cgltf = @import("cgltf");
const c = @import("c");
const compare = @import("compare.zig");
const samples = @import("samples.zig");

const testing = std.testing;

/// One file through both, from its path: everything compared at each step.
pub fn expectSameFile(gpa: std.mem.Allocator, io: std.Io, path: [:0]const u8) !void {
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    const parsed = c.cgltf_parse_file(&options, path, &original);
    defer if (original != null) c.cgltf_free(original);
    var port = cgltf.parseFile(gpa, io, path, .{});
    defer if (port) |*gltf| gltf.deinit() else |_| {};
    try compare.expectResult("parse_file", parsed, if (port) |_| {} else |err| err);
    const gltf = if (port) |*gltf| gltf else |_| return;
    try compare.expectSameData(original, gltf);
    try expectSameExtras(original, gltf);

    const port_loaded = cgltf.loadBuffers(gltf, io, path);
    try compare.expectResult("load_buffers", c.cgltf_load_buffers(&options, original, path), port_loaded);
    try compare.expectSameData(original, gltf);

    const port_valid = cgltf.validate(gltf);
    if (port_valid != error.OutOfBounds) {
        try compare.expectResult("validate", c.cgltf_validate(original), port_valid);
    }
    try compare.expectSameHelpers(gpa, original, gltf);
}

fn expectSameExtras(original: *const c.cgltf_data, port: *const cgltf.Gltf) !void {
    try compare.expectSameExtrasCopy(original, port, &port.extras, &original.extras);
    try compare.expectSameExtrasCopy(original, port, &port.asset.extras, &original.asset.extras);
    for (port.nodes, 0..) |*node, n| {
        try compare.expectSameExtrasCopy(original, port, &node.extras, &original.nodes[n].extras);
    }
    for (port.meshes, 0..) |*mesh, m| {
        try compare.expectSameExtrasCopy(original, port, &mesh.extras, &original.meshes[m].extras);
    }
}

test "every sample model parses, loads, validates and reads as the original" {
    const gpa = testing.allocator;
    const paths = try samples.modelPaths(gpa, testing.io);
    defer samples.freePaths(gpa, paths);
    try testing.expect(paths.len > 300);
    for (paths) |path| {
        expectSameFile(gpa, testing.io, path) catch |err| {
            std.debug.print("model: {s}\n", .{path});
            return err;
        };
    }
}
