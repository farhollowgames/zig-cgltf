//! The oracle: runs the original and the port on the same input and
//! compares every field of every struct, every string's bytes, every
//! reference as an index into its array, every float as bits, and every
//! accessor helper's output. A C field the comparison does not handle is
//! a compile error, so a struct cannot gain a field the tests skip.

const std = @import("std");
const cgltf = @import("cgltf");
const c = @import("c");

pub const Mismatch = error{Mismatch};

pub fn fail(comptime format: []const u8, args: anytype) Mismatch {
    std.debug.print("mismatch: " ++ format ++ "\n", args);
    return error.Mismatch;
}

/// The original's result code for a port error.
pub fn resultCode(err: cgltf.Error) c.cgltf_result {
    return switch (err) {
        error.DataTooShort => c.cgltf_result_data_too_short,
        error.UnknownFormat => c.cgltf_result_unknown_format,
        error.InvalidJson => c.cgltf_result_invalid_json,
        error.InvalidGltf => c.cgltf_result_invalid_gltf,
        error.InvalidOptions => c.cgltf_result_invalid_options,
        error.FileNotFound => c.cgltf_result_file_not_found,
        error.IoError => c.cgltf_result_io_error,
        error.OutOfMemory => c.cgltf_result_out_of_memory,
        error.LegacyGltf => c.cgltf_result_legacy_gltf,
        error.OutOfBounds => unreachable,
    };
}

pub fn expectResult(where: []const u8, original: c.cgltf_result, port: cgltf.Error!void) Mismatch!void {
    const code: c.cgltf_result = if (port) |_| c.cgltf_result_success else |err| resultCode(err);
    if (code != original) return fail("{s}: original {d}, port {d}", .{ where, original, code });
}

fn isCString(comptime T: type) bool {
    return T == [*c]u8 or T == [*c]const u8;
}

fn pointee(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .c) return null;
    return info.pointer.child;
}

fn isObject(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

/// C fields compared by hand, or not compared: the allocator and file
/// callbacks, and the camera's type and union, which the port's tagged
/// union holds.
fn skipped(comptime C: type, comptime name: []const u8) bool {
    const skips = .{
        .{ c.cgltf_data, "file_data" },
        .{ c.cgltf_data, "file_size" },
        .{ c.cgltf_data, "json" },
        .{ c.cgltf_data, "json_size" },
        .{ c.cgltf_data, "bin" },
        .{ c.cgltf_data, "bin_size" },
        .{ c.cgltf_data, "memory" },
        .{ c.cgltf_data, "file" },
        .{ c.cgltf_camera, "type" },
        .{ c.cgltf_camera, "data" },
        .{ c.cgltf_buffer, "data" },
        .{ c.cgltf_buffer_view, "data" },
    };
    inline for (skips) |skip| {
        if (C == skip[0] and std.mem.eql(u8, name, skip[1])) return true;
    }
    return false;
}

/// Port fields with no C field of the same name.
fn portOnly(comptime Z: type, comptime name: []const u8) bool {
    const extra = .{
        .{ cgltf.Gltf, "arena" },
        .{ cgltf.Gltf, "file_reader" },
    };
    inline for (extra) |field| {
        if (Z == field[0] and std.mem.eql(u8, name, field[1])) return true;
    }
    return false;
}

pub const Comparer = struct {
    data: *const c.cgltf_data,
    animation: ?*const c.cgltf_animation = null,

    /// The C array a reference to a `T` points into.
    fn base(self: *const Comparer, comptime T: type) [*c]const T {
        if (T == c.cgltf_animation_sampler) return self.animation.?.samplers;
        const info = @typeInfo(c.cgltf_data).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (comptime F == [*c]T and @hasField(c.cgltf_data, name ++ "_count")) {
                return @field(self.data, name);
            }
        }
        @compileError("no array of " ++ @typeName(T));
    }

    fn count(self: *const Comparer, comptime T: type) usize {
        if (T == c.cgltf_animation_sampler) return self.animation.?.samplers_count;
        const info = @typeInfo(c.cgltf_data).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (comptime F == [*c]T and @hasField(c.cgltf_data, name ++ "_count")) {
                return @field(self.data, name ++ "_count");
            }
        }
        unreachable;
    }

    /// A C pointer to an object as the index the port stores.
    pub fn indexOf(self: *const Comparer, comptime T: type, pointer: [*c]const T) ?usize {
        if (pointer == null) return null;
        const offset = @intFromPtr(pointer) - @intFromPtr(self.base(T));
        const index = offset / @sizeOf(T);
        std.debug.assert(index < self.count(T));
        return index;
    }

    fn reference(self: *const Comparer, comptime T: type, pointer: [*c]const T, port: anytype, where: []const u8) Mismatch!void {
        const expected = self.indexOf(T, pointer);
        const actual: ?usize = if (@TypeOf(port) == u32) port else if (port) |p| p else null;
        if (!std.meta.eql(expected, actual)) return fail("{s}: original {?d}, port {?d}", .{ where, expected, actual });
    }

    fn string(original: [*c]const u8, port: anytype, where: []const u8) Mismatch!void {
        const actual: ?[]const u8 = if (@typeInfo(@TypeOf(port)) == .optional) (if (port) |p| p else null) else port;
        if (original == null) {
            if (actual != null) return fail("{s}: original null, port \"{s}\"", .{ where, actual.? });
            return;
        }
        const expected = std.mem.span(original);
        const got = actual orelse return fail("{s}: original \"{s}\", port null", .{ where, expected });
        if (!std.mem.eql(u8, expected, got)) return fail("{s}: original \"{s}\", port \"{s}\"", .{ where, expected, got });
    }

    fn value(self: *Comparer, comptime C: type, original: C, port: anytype, where: []const u8) Mismatch!void {
        const Z = @TypeOf(port);
        if (C == f32) {
            if (@as(u32, @bitCast(original)) != @as(u32, @bitCast(port))) {
                return fail("{s}: original {e} ({x}), port {e} ({x})", .{ where, original, @as(u32, @bitCast(original)), port, @as(u32, @bitCast(port)) });
            }
        } else if (comptime isCString(C)) {
            try string(original, port, where);
        } else if (comptime pointee(C)) |T| {
            try self.reference(T, original, port, where);
        } else if (@typeInfo(C) == .array) {
            for (original, port, 0..) |o, z, i| {
                _ = i;
                try self.value(@TypeOf(o), o, z, where);
            }
        } else if (@typeInfo(C) == .@"struct") {
            try self.object(C, &original, &port);
        } else if (Z == bool) {
            if ((original != 0) != port) return fail("{s}: original {d}, port {}", .{ where, original, port });
        } else if (@typeInfo(Z) == .@"enum") {
            // The bits: cgltf's enums are unsigned, where the port keeps
            // glTF's signed numbers for filters and wrap modes.
            const z: C = @bitCast(@backingInt(port));
            if (original != z) return fail("{s}: original {d}, port {d}", .{ where, original, z });
        } else if (@typeInfo(Z) == .int) {
            if (@as(i128, original) != @as(i128, port)) return fail("{s}: original {d}, port {d}", .{ where, original, port });
        } else {
            @compileError("cannot compare " ++ @typeName(C) ++ " with " ++ @typeName(Z));
        }
    }

    /// A C array with a count against the port's slice, or optional slice.
    fn array(self: *Comparer, comptime T: type, items: [*c]const T, n: usize, port: anytype, where: []const u8) Mismatch!void {
        const P = @TypeOf(port);
        const slice = if (@typeInfo(P) == .optional) blk: {
            if ((items == null) != (port == null)) {
                return fail("{s}: original {s}, port {s}", .{ where, if (items == null) "null" else "set", if (port == null) "null" else "set" });
            }
            break :blk port orelse return;
        } else port;
        if (n != slice.len) return fail("{s}: original {d} items, port {d}", .{ where, n, slice.len });
        if (n == 0) return;
        const originals = items[0..n];
        for (slice, originals) |*item, *o| {
            if (comptime isObject(T)) {
                try self.object(T, o, item);
            } else {
                try self.value(T, o.*, item.*, where);
            }
        }
    }

    pub fn object(self: *Comparer, comptime C: type, original: *const C, port: anytype) Mismatch!void {
        const Z = @typeInfo(@TypeOf(port)).pointer.child;
        comptime for (@typeInfo(Z).@"struct".field_names) |name| {
            if (!@hasField(C, name) and !portOnly(Z, name)) {
                if (!(C == c.cgltf_camera and std.mem.eql(u8, name, "data"))) {
                    @compileError(@typeName(Z) ++ "." ++ name ++ " is not compared");
                }
            }
        };
        if (C == c.cgltf_animation) self.animation = original;
        const info = @typeInfo(C).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            const counted = comptime std.mem.endsWith(u8, name, "_count") and
                @hasField(C, name[0 .. name.len - "_count".len]);
            if (comptime counted or skipped(C, name)) continue;
            const here = @typeName(C) ++ "." ++ name;
            if (comptime @hasField(C, name ++ "_count")) {
                const T = pointee(F).?;
                try self.array(T, @field(original, name), @field(original, name ++ "_count"), @field(port, name), here);
            } else {
                try self.value(F, @field(original, name), @field(port, name), here);
            }
        }
        if (C == c.cgltf_camera) try self.camera(original, port);
        if (C == c.cgltf_buffer) try buffer(original, port);
        if (C == c.cgltf_buffer_view) {
            if (original.data != null or port.data != null) return fail("buffer view data set", .{});
        }
        if (C == c.cgltf_data) try self.root(original, port);
    }

    fn camera(self: *Comparer, original: *const c.cgltf_camera, port: *const cgltf.Camera) Mismatch!void {
        const tag: c.cgltf_camera_type = @backingInt(std.meta.activeTag(port.data));
        if (original.type != tag) return fail("camera type: original {d}, port {d}", .{ original.type, tag });
        switch (port.data) {
            .invalid => {},
            .perspective => |*p| try self.object(c.cgltf_camera_perspective, &original.data.perspective, p),
            .orthographic => |*o| try self.object(c.cgltf_camera_orthographic, &original.data.orthographic, o),
        }
    }

    fn buffer(original: *const c.cgltf_buffer, port: *const cgltf.Buffer) Mismatch!void {
        if ((original.data == null) != (port.data == null)) return fail("buffer data loaded on one side only", .{});
        const data = port.data orelse return;
        const n = @min(data.len, original.size);
        const expected: [*]const u8 = @ptrCast(original.data.?);
        if (!std.mem.eql(u8, expected[0..n], data[0..n])) return fail("buffer data differs", .{});
    }

    fn root(self: *Comparer, original: *const c.cgltf_data, port: *const cgltf.Gltf) Mismatch!void {
        _ = self;
        if (original.json_size != port.json.len) return fail("json size", .{});
        if (!std.mem.eql(u8, original.json[0..original.json_size], port.json)) return fail("json text", .{});
        if ((original.bin == null) != (port.bin == null)) return fail("bin", .{});
        if (port.bin) |bin| {
            const expected: [*]const u8 = @ptrCast(original.bin.?);
            if (original.bin_size != bin.len or !std.mem.eql(u8, expected[0..bin.len], bin)) {
                return fail("bin chunk", .{});
            }
        }
    }
};

/// Compares the whole parsed file.
pub fn expectSameData(original: *const c.cgltf_data, port: *const cgltf.Gltf) Mismatch!void {
    var comparer: Comparer = .{ .data = original };
    try comparer.object(c.cgltf_data, original, port);
}

fn floatsEqual(a: []const f32, b: []const f32) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

/// Bits equal, or both NaN: for floats computed from NaN, which keep one
/// operand's NaN or the other's as each compiler orders the operands of
/// an addition or a product. Neither C nor Zig fixes the order.
fn computedFloatsEqual(a: []const f32, b: []const f32) bool {
    for (a, b) |x, y| {
        if (std.math.isNan(x) and std.math.isNan(y)) continue;
        if (@as(u32, @bitCast(x)) != @as(u32, @bitCast(y))) return false;
    }
    return true;
}

/// Every accessor helper on every element of every accessor, every
/// node's transforms, every attribute's lookup and every view's data,
/// on both sides. A helper the port refuses with `OutOfBounds` is not run
/// on the original, which would read or write out of bounds there.
pub fn expectSameHelpers(gpa: std.mem.Allocator, original: *const c.cgltf_data, port: *const cgltf.Gltf) !void {
    var comparer: Comparer = .{ .data = original };
    for (port.accessors, 0..) |*accessor, a| {
        const ca = &original.accessors[a];
        try expectSameAccessor(gpa, original, ca, port, accessor, a);
    }
    for (port.buffer_views, 0..) |_, v| {
        const cv = &original.buffer_views[v];
        const expected = c.cgltf_buffer_view_data(cv);
        const actual = cgltf.bufferViewData(port, @intCast(v)) catch {
            const memory = port.buffers[port.buffer_views[v].buffer].data;
            if (cv.*.data != null or memory == null or cv.*.offset <= memory.?.len) {
                return fail("view {d} data refused, inside the buffer's memory", .{v});
            }
            continue;
        };
        if ((expected == null) != (actual == null)) return fail("view {d} data", .{v});
        if (actual) |bytes| {
            const buffer_data: [*]const u8 = @ptrCast(original.buffer_views[v].buffer.*.data.?);
            const port_buffer = port.buffers[port.buffer_views[v].buffer].data.?;
            if (@intFromPtr(expected) - @intFromPtr(buffer_data) != @intFromPtr(bytes.ptr) - @intFromPtr(port_buffer.ptr)) {
                return fail("view {d} data offset", .{v});
            }
        }
    }
    for (port.nodes, 0..) |*node, n| {
        const cn = &original.nodes[n];
        var expected: [16]f32 = undefined;
        c.cgltf_node_transform_local(cn, &expected);
        // A node's own matrix is copied, not computed, so its bits match.
        const local_equal: *const fn ([]const f32, []const f32) bool = if (node.has_matrix) &floatsEqual else &computedFloatsEqual;
        if (!local_equal(&expected, &cgltf.transformLocal(node))) return fail("node {d} local transform", .{n});
        const world = cgltf.transformWorld(port, @intCast(n)) catch |err| {
            try expectCycle(original, n);
            switch (err) {
                error.ParentCycle => continue,
            }
        };
        c.cgltf_node_transform_world(cn, &expected);
        const world_equal = if (node.parent == null) local_equal else &computedFloatsEqual;
        if (!world_equal(&expected, &world)) {
            return fail("node {d} world transform: original {any}, port {any}", .{ n, expected, world });
        }
    }
    for (port.meshes, 0..) |*mesh, m| {
        for (mesh.primitives, 0..) |*primitive, p| {
            const cp = &original.meshes[m].primitives[p];
            for (primitive.attributes) |attribute| {
                for ([_]i32{ attribute.index, attribute.index + 1 }) |set| {
                    const expected = c.cgltf_find_accessor(cp, @backingInt(attribute.type), set);
                    const actual = cgltf.findAccessor(primitive, attribute.type, set);
                    try comparer.reference(c.cgltf_accessor, expected, actual, "find_accessor");
                }
            }
        }
    }
}

fn expectSameAccessor(
    gpa: std.mem.Allocator,
    original: *const c.cgltf_data,
    ca: [*c]const c.cgltf_accessor,
    port: *const cgltf.Gltf,
    accessor: *const cgltf.Accessor,
    a: usize,
) !void {
    const element_size = c.cgltf_calc_size(ca.*.type, ca.*.component_type);
    const component_size = c.cgltf_component_size(ca.*.component_type);
    const components = c.cgltf_num_components(ca.*.type);
    // Element by element, with outputs of every size up to 16.
    const elements = @min(accessor.count, 1 << 16);
    for (0..elements) |e| {
        for ([_]usize{ 0, 1, 3, 16 }) |size| {
            var expected: [16]f32 = @splat(-7);
            var actual: [16]f32 = @splat(-7);
            const ok = cgltf.readFloat(port, accessor, e, actual[0..size]) catch {
                try expectMayRead(port, original, ca, e + 1, element_size, "read_float", a);
                continue;
            };
            const expected_ok = c.cgltf_accessor_read_float(ca, e, &expected, size) != 0;
            if (ok != expected_ok or !floatsEqual(&expected, &actual)) {
                return fail("accessor {d} read_float({d}, {d})", .{ a, e, size });
            }
            var expected_u: [16]u32 = @splat(7);
            var actual_u: [16]u32 = @splat(7);
            const ok_u = cgltf.readUint(port, accessor, e, actual_u[0..size]) catch {
                try expectMayRead(port, original, ca, e + 1, element_size, "read_uint", a);
                continue;
            };
            const expected_ok_u = c.cgltf_accessor_read_uint(ca, e, &expected_u, size) != 0;
            if (ok_u != expected_ok_u or !std.mem.eql(u32, &expected_u, &actual_u)) {
                return fail("accessor {d} read_uint({d}, {d})", .{ a, e, size });
            }
        }
        const index = cgltf.readIndex(port, accessor, e) catch {
            try expectMayRead(port, original, ca, e + 1, component_size, "read_index", a);
            continue;
        };
        if (index != c.cgltf_accessor_read_index(ca, e)) return fail("accessor {d} read_index({d})", .{ a, e });
    }

    const float_count = cgltf.unpackFloatsCount(accessor);
    if (float_count != c.cgltf_accessor_unpack_floats(ca, null, 0)) return fail("accessor {d} unpack_floats count", .{a});
    if (float_count <= 1 << 24) {
        for ([_]usize{ float_count, float_count / 2, float_count -| 1 }) |n| {
            const expected = try gpa.alloc(f32, n);
            defer gpa.free(expected);
            const actual = try gpa.alloc(f32, n);
            defer gpa.free(actual);
            @memset(expected, -7);
            @memset(actual, -7);
            const written = cgltf.unpackFloats(port, accessor, actual) catch {
                const unpacked = @min(float_count, n) / @max(components, 1);
                if (!mayReadPast(port, original, ca, unpacked, element_size) and
                    !sparseMayWritePast(port, original, ca, n))
                {
                    return fail("accessor {d} unpack_floats({d}) refused, inside memory and output", .{ a, n });
                }
                continue;
            };
            if (written != c.cgltf_accessor_unpack_floats(ca, expected.ptr, n) or !floatsEqual(expected, actual)) {
                return fail("accessor {d} unpack_floats({d})", .{ a, n });
            }
        }
    }

    if (cgltf.unpackIndicesCount(accessor) != c.cgltf_accessor_unpack_indices(ca, null, 4, 0)) {
        return fail("accessor {d} unpack_indices count", .{a});
    }
    const index_count = float_count;
    if (index_count <= 1 << 24) {
        inline for (.{ u8, u16, u32 }) |T| {
            const expected = try gpa.alloc(T, index_count);
            defer gpa.free(expected);
            const actual = try gpa.alloc(T, index_count);
            defer gpa.free(actual);
            @memset(expected, 7);
            @memset(actual, 7);
            if (cgltf.unpackIndices(T, port, accessor, actual)) |written| {
                if (written != c.cgltf_accessor_unpack_indices(ca, expected.ptr, @sizeOf(T), index_count) or
                    !std.mem.eql(T, expected, actual))
                {
                    return fail("accessor {d} unpack_indices({s})", .{ a, @typeName(T) });
                }
            } else |_| {
                const reads = ca.*.is_sparse == 0 and ca.*.buffer_view != null and component_size <= @sizeOf(T);
                if (!reads or !viewMayReadPast(port, original, ca.*.buffer_view, ca.*.offset, ca.*.stride, index_count, component_size)) {
                    return fail("accessor {d} unpack_indices({s}) refused, inside the buffer's memory", .{ a, @typeName(T) });
                }
            }
        }
    }
}

// The port refuses with `OutOfBounds` where the original would read or
// write out of bounds, and the original is not run there. The functions
// below work out from the original's structs whether it could, so that a
// refusal they do not allow fails the test.

/// Whether reading `elements` elements of `size` bytes, `stride` apart,
/// from `offset` in `view` can reach past the memory behind it.
fn viewMayReadPast(
    port: *const cgltf.Gltf,
    original: *const c.cgltf_data,
    view: [*c]const c.cgltf_buffer_view,
    offset: usize,
    stride: usize,
    elements: usize,
    size: usize,
) bool {
    if (view == null or elements == 0) return false;
    const start, const memory = viewMemory(port, original, view, offset) orelse return false;
    const span = std.math.mul(usize, stride, elements - 1) catch return true;
    const end = std.math.add(usize, start, span) catch return true;
    return (std.math.add(usize, end, size) catch return true) > memory.len;
}

/// The memory behind `view` and where `offset` lies in it, or null when
/// the original has no memory there and reads nothing.
fn viewMemory(
    port: *const cgltf.Gltf,
    original: *const c.cgltf_data,
    view: [*c]const c.cgltf_buffer_view,
    offset: usize,
) ?struct { usize, []const u8 } {
    const v = (@intFromPtr(view) - @intFromPtr(original.buffer_views)) / @sizeOf(c.cgltf_buffer_view);
    if (port.buffer_views[v].data) |data| return .{ offset, data };
    const memory = port.buffers[port.buffer_views[v].buffer].data orelse return null;
    // Past `maxInt(usize)`, the original's pointer wraps: count it as past.
    return .{ std.math.add(usize, view.*.offset, offset) catch std.math.maxInt(usize), memory };
}

/// Whether an accessor's base elements, up to `elements`, or its sparse
/// indices and values can be read past their memory.
fn mayReadPast(
    port: *const cgltf.Gltf,
    original: *const c.cgltf_data,
    ca: [*c]const c.cgltf_accessor,
    elements: usize,
    size: usize,
) bool {
    const a = ca.*;
    if (viewMayReadPast(port, original, a.buffer_view, a.offset, a.stride, elements, size)) return true;
    if (a.is_sparse == 0) return false;
    const sparse = a.sparse;
    const index_size = c.cgltf_component_size(sparse.indices_component_type);
    return viewMayReadPast(port, original, sparse.indices_buffer_view, sparse.indices_byte_offset, index_size, sparse.count, index_size) or
        viewMayReadPast(port, original, sparse.values_buffer_view, sparse.values_byte_offset, a.stride, sparse.count, size);
}

fn expectMayRead(
    port: *const cgltf.Gltf,
    original: *const c.cgltf_data,
    ca: [*c]const c.cgltf_accessor,
    elements: usize,
    size: usize,
    comptime what: []const u8,
    a: usize,
) Mismatch!void {
    if (!mayReadPast(port, original, ca, elements, size)) {
        return fail("accessor {d} " ++ what ++ "({d}) refused, inside the buffer's memory", .{ a, elements - 1 });
    }
}

/// Whether a sparse index puts its element past the first `out_len`
/// floats of the output, read from the indices in memory.
fn sparseMayWritePast(
    port: *const cgltf.Gltf,
    original: *const c.cgltf_data,
    ca: [*c]const c.cgltf_accessor,
    out_len: usize,
) bool {
    const a = ca.*;
    if (a.is_sparse == 0) return false;
    const sparse = a.sparse;
    if (sparse.indices_buffer_view == null) return false;
    const start, const memory = viewMemory(port, original, sparse.indices_buffer_view, sparse.indices_byte_offset) orelse
        return false;
    const components = c.cgltf_num_components(a.type);
    const index_size = c.cgltf_component_size(sparse.indices_component_type);
    for (0..sparse.count) |i| {
        const at = start +| i *| index_size;
        if (at +| index_size > memory.len) return true;
        const bytes = memory[at..];
        const index: usize = switch (sparse.indices_component_type) {
            c.cgltf_component_type_r_8u => bytes[0],
            c.cgltf_component_type_r_16u => std.mem.readInt(u16, bytes[0..2], .native),
            c.cgltf_component_type_r_32u => std.mem.readInt(u32, bytes[0..4], .native),
            else => 0,
        };
        if ((index +| 1) *| components > out_len) return true;
    }
    return false;
}

/// A port refusal of a node's world transform: its parents must loop.
fn expectCycle(original: *const c.cgltf_data, n: usize) Mismatch!void {
    var node: [*c]const c.cgltf_node = &original.nodes[n];
    for (0..original.nodes_count + 1) |_| {
        node = node.*.parent;
        if (node == null) return fail("node {d} world transform refused, with no loop of parents", .{n});
    }
}

/// `cgltf_copy_extras_json` on every output size around the text's.
pub fn expectSameExtrasCopy(
    original: *const c.cgltf_data,
    port: *const cgltf.Gltf,
    extras: *const cgltf.Extras,
    c_extras: [*c]const c.cgltf_extras,
) !void {
    var size: usize = 0;
    if (c.cgltf_copy_extras_json(original, c_extras, null, &size) != c.cgltf_result_success) return fail("extras size", .{});
    if (size != try cgltf.copyExtrasJson(port, extras, null)) return fail("extras size", .{});
    var expected: [64]u8 = undefined;
    var actual: [64]u8 = undefined;
    for (0..@min(size + 2, expected.len)) |n| {
        @memset(&expected, 0xAA);
        @memset(&actual, 0xAA);
        _ = cgltf.copyExtrasJson(port, extras, actual[0..n]) catch continue;
        var dest_size = n;
        _ = c.cgltf_copy_extras_json(original, c_extras, &expected, &dest_size);
        if (!std.mem.eql(u8, &expected, &actual)) return fail("copy_extras_json({d})", .{n});
    }
}
