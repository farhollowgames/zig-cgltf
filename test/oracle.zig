//! One input through the original and the port, step by step: parse,
//! load the buffers, validate, then every helper, comparing everything
//! after each step.

const std = @import("std");
const cgltf = @import("cgltf");
const c = @import("c");
const compare = @import("compare.zig");

pub const Source = union(enum) {
    /// Parsed with `cgltf_parse_file` and `parseFile`.
    path: [:0]const u8,
    /// Parsed from memory, with the path buffers are read beside, if any.
    bytes: struct { data: []const u8, gltf_path: ?[:0]const u8 = null },
};

pub const Options = struct {
    file_type: cgltf.FileType = .invalid,
    json_token_count: usize = 0,
};

/// How far an input went before both refused it.
pub const Reached = enum { refused, parsed, loaded, valid };

/// Runs `source` through both and fails on the first difference.
pub fn expectSame(gpa: std.mem.Allocator, io: std.Io, source: Source, options: Options) !Reached {
    var c_options = std.mem.zeroes(c.cgltf_options);
    c_options.type = @backingInt(options.file_type);
    c_options.json_token_count = options.json_token_count;
    const port_options: cgltf.Options = .{
        .file_type = options.file_type,
        .json_token_count = options.json_token_count,
    };

    var original: [*c]c.cgltf_data = null;
    defer if (original != null) c.cgltf_free(original);
    var gltf_path: ?[:0]const u8 = null;
    const parsed, var port = switch (source) {
        .path => |path| blk: {
            gltf_path = path;
            break :blk .{
                c.cgltf_parse_file(&c_options, path, &original),
                cgltf.parseFile(gpa, io, path, port_options),
            };
        },
        .bytes => |bytes| blk: {
            gltf_path = bytes.gltf_path;
            break :blk .{
                c.cgltf_parse(&c_options, bytes.data.ptr, bytes.data.len, &original),
                cgltf.parse(gpa, bytes.data, port_options),
            };
        },
    };
    defer if (port) |*gltf| gltf.deinit() else |_| {};
    try compare.expectResult("parse", parsed, if (port) |_| {} else |err| err);
    const gltf = if (port) |*gltf| gltf else |_| return .refused;
    try compare.expectSameData(original, gltf);
    try expectSameExtras(original, gltf);

    const c_path: [*c]const u8 = if (gltf_path) |path| path.ptr else null;
    const port_loaded = cgltf.loadBuffers(gltf, io, gltf_path);
    try compare.expectResult("load_buffers", c.cgltf_load_buffers(&c_options, original, c_path), port_loaded);
    try compare.expectSameData(original, gltf);

    const port_valid = cgltf.validate(gltf);
    if (port_valid != error.OutOfBounds) {
        try compare.expectResult("validate", c.cgltf_validate(original), port_valid);
    }
    try compare.expectSameHelpers(gpa, original, gltf);
    if (port_loaded) |_| {} else |_| return .parsed;
    if (port_valid) |_| {} else |_| return .loaded;
    return .valid;
}

/// Counts of how far fuzz cases went.
pub const Tally = struct {
    counts: std.EnumArray(Reached, usize) = .initFill(0),

    pub fn add(tally: *Tally, reached: Reached) void {
        tally.counts.getPtr(reached).* += 1;
    }

    /// Fails unless at least `min_valid` cases were valid and a tenth as
    /// many failed after parsing, so the fuzzer reaches every step.
    pub fn expectReach(tally: *const Tally, name: []const u8, min_valid: usize) !void {
        const counts = tally.counts;
        std.debug.print("{s}: refused {d}, parsed {d}, loaded {d}, valid {d}\n", .{
            name,
            counts.get(.refused),
            counts.get(.parsed),
            counts.get(.loaded),
            counts.get(.valid),
        });
        if (counts.get(.valid) < min_valid or counts.get(.loaded) + counts.get(.parsed) < min_valid / 10) {
            return error.FuzzTooNarrow;
        }
    }
};

fn expectSameExtras(original: [*c]const c.cgltf_data, port: *const cgltf.Gltf) !void {
    try compare.expectSameExtrasCopy(original, port, &port.extras, &original.*.extras);
    try compare.expectSameExtrasCopy(original, port, &port.asset.extras, &original.*.asset.extras);
    for (port.nodes, 0..) |*node, n| {
        try compare.expectSameExtrasCopy(original, port, &node.extras, &original.*.nodes[n].extras);
    }
    for (port.meshes, 0..) |*mesh, m| {
        try compare.expectSameExtrasCopy(original, port, &mesh.extras, &original.*.meshes[m].extras);
    }
    for (port.materials, 0..) |*material, m| {
        try compare.expectSameExtrasCopy(original, port, &material.extras, &original.*.materials[m].extras);
    }
}
