//! The Khronos sample models: every `.gltf` and `.glb` file under
//! `Models/`, in path order.

const std = @import("std");
const test_options = @import("test_options");

/// The directory of the sample models.
pub const models = std.fs.path.dirname(test_options.model_index).?;

/// The models' absolute paths, each owned with the list by `gpa`.
pub fn modelPaths(gpa: std.mem.Allocator, io: std.Io) ![][:0]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, models, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var paths: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".gltf") and !std.mem.eql(u8, ext, ".glb")) continue;
        const path = try std.fs.path.joinZ(gpa, &.{ models, entry.path });
        errdefer gpa.free(path);
        try paths.append(gpa, path);
    }
    std.mem.sort([:0]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: [:0]u8, b: [:0]u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return paths.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: std.mem.Allocator, paths: [][:0]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}
