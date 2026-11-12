//! cgltf's `cgltf_validate`: the glTF rules cgltf checks after parsing,
//! mostly that accessors and views fit in what they point at.

const std = @import("std");

const cgltf = @import("cgltf.zig");
const types = @import("types.zig");
const Gltf = cgltf.Gltf;
const Error = cgltf.Error;

/// cgltf's `cgltf_calc_index_bound`: the largest index among `count` from
/// the view's buffer at `offset`. cgltf reads them unchecked, before it
/// has checked the view against its buffer.
fn indexBound(
    gltf: *const Gltf,
    view: *const types.BufferView,
    offset: usize,
    component_type: types.ComponentType,
    count: usize,
) Error!usize {
    const size: usize = switch (component_type) {
        .r_8u => 1,
        .r_16u => 2,
        .r_32u => 4,
        else => return 0,
    };
    const memory = gltf.buffers[view.buffer].data.?;
    const start = offset +% view.offset;
    if (count == 0) return 0;
    const length = std.math.mul(usize, count, size) catch return error.OutOfBounds;
    if (start > memory.len or length > memory.len - start) return error.OutOfBounds;
    const bytes = memory[start..][0..length];
    return switch (size) {
        1 => maxOf(u8, bytes),
        2 => maxOf(u16, bytes),
        else => maxOf(u32, bytes),
    };
}

/// The largest of the native-endian `T`s that fill `bytes`, at least one.
/// Zig 0.17 leaves a loop over a runtime length scalar, so the lanes are
/// written out: four 64-byte vectors at a time, then one, then the last
/// 64 bytes, which may overlap what the loops read, as reading a value
/// twice leaves the largest the same. The vectors load through pointers,
/// since a `@bitCast` of a byte array to a vector compiles to scalar
/// shifts.
fn maxOf(comptime T: type, bytes: []const u8) usize {
    const lanes = 64 / @sizeOf(T);
    const V = @Vector(lanes, T);
    const vector_bytes = lanes * @sizeOf(T);
    if (bytes.len < vector_bytes) return maxOfShort(T, vector_bytes / 2, bytes);
    var acc: [4]V = @splat(@splat(0));
    var at: usize = 0;
    while (at + 4 * vector_bytes <= bytes.len) : (at += 4 * vector_bytes) {
        inline for (&acc, 0..) |*a, k| {
            const chunk: *align(1) const V = @ptrCast(bytes[at + k * vector_bytes ..][0..vector_bytes]);
            a.* = @max(a.*, chunk.*);
        }
    }
    while (at + vector_bytes <= bytes.len) : (at += vector_bytes) {
        const chunk: *align(1) const V = @ptrCast(bytes[at..][0..vector_bytes]);
        acc[0] = @max(acc[0], chunk.*);
    }
    if (at < bytes.len) {
        const last: *align(1) const V = @ptrCast(bytes[bytes.len - vector_bytes ..][0..vector_bytes]);
        acc[1] = @max(acc[1], last.*);
    }
    return @reduce(.Max, @max(@max(acc[0], acc[1]), @max(acc[2], acc[3])));
}

/// `maxOf` of fewer than `2 * width` bytes: a vector of `width` bytes at
/// the start and one at the end, overlapping, cover them, or a narrower
/// pair does when they are fewer than `width`.
fn maxOfShort(comptime T: type, comptime width: usize, bytes: []const u8) usize {
    if (width > @sizeOf(T)) {
        if (bytes.len < width) return maxOfShort(T, width / 2, bytes);
    }
    const V = @Vector(width / @sizeOf(T), T);
    const first: *align(1) const V = @ptrCast(bytes[0..width]);
    const last: *align(1) const V = @ptrCast(bytes[bytes.len - width ..][0..width]);
    return @reduce(.Max, @max(first.*, last.*));
}

fn isIndexType(component_type: types.ComponentType) bool {
    return component_type == .r_8u or component_type == .r_16u or component_type == .r_32u;
}

/// Checks what cgltf checks, in its order, with its wrapping arithmetic:
/// `error.DataTooShort` for an accessor or view past the end of what it
/// reads, `error.InvalidGltf` for the rest. Reading a buffer's memory
/// past its end, which cgltf would do for some invalid files, is
/// `error.OutOfBounds`.
pub fn validate(gltf: *const Gltf) Error!void {
    for (gltf.accessors) |*accessor| {
        if (accessor.component_type == .invalid) return error.InvalidGltf;
        if (accessor.type == .invalid) return error.InvalidGltf;
        const element_size = cgltf.calcSize(accessor.type, accessor.component_type);
        if (accessor.buffer_view) |view| {
            const req_size = accessor.offset +% accessor.stride *% (accessor.count -% 1) +% element_size;
            if (gltf.buffer_views[view].size < req_size) return error.DataTooShort;
        }
        if (accessor.is_sparse) {
            const sparse = &accessor.sparse;
            const indices_view = &gltf.buffer_views[sparse.indices_buffer_view.?];
            const values_view = &gltf.buffer_views[sparse.values_buffer_view.?];
            const indices_component_size = cgltf.componentSize(sparse.indices_component_type);
            const indices_req_size = sparse.indices_byte_offset +% indices_component_size *% sparse.count;
            const values_req_size = sparse.values_byte_offset +% element_size *% sparse.count;
            if (indices_view.size < indices_req_size or values_view.size < values_req_size) {
                return error.DataTooShort;
            }
            if (!isIndexType(sparse.indices_component_type)) return error.InvalidGltf;
            if (gltf.buffers[indices_view.buffer].data != null) {
                const bound = try indexBound(
                    gltf,
                    indices_view,
                    sparse.indices_byte_offset,
                    sparse.indices_component_type,
                    sparse.count,
                );
                if (bound >= accessor.count) return error.DataTooShort;
            }
        }
    }

    for (gltf.buffer_views) |*view| {
        const req_size = view.offset +% view.size;
        if (gltf.buffers[view.buffer].size < req_size) return error.DataTooShort;
        if (view.has_meshopt_compression) {
            const mc = &view.meshopt_compression;
            if (gltf.buffers[mc.buffer.?].size < mc.offset +% mc.size) return error.DataTooShort;
            if (view.stride != 0 and mc.stride != view.stride) return error.InvalidGltf;
            if (view.size != mc.stride *% mc.count) return error.InvalidGltf;
            if (mc.mode == .invalid) return error.InvalidGltf;
            if (mc.mode == .attributes and !(mc.stride % 4 == 0 and mc.stride <= 256)) {
                return error.InvalidGltf;
            }
            if (mc.mode == .triangles and mc.count % 3 != 0) return error.InvalidGltf;
            const index_mode = mc.mode == .triangles or mc.mode == .indices;
            if (index_mode and mc.stride != 2 and mc.stride != 4) return error.InvalidGltf;
            if (index_mode and mc.filter != .none) return error.InvalidGltf;
            if (mc.filter == .octahedral and mc.stride != 4 and mc.stride != 8) return error.InvalidGltf;
            if (mc.filter == .quaternion and mc.stride != 8) return error.InvalidGltf;
            if (mc.filter == .color and mc.stride != 4 and mc.stride != 8) return error.InvalidGltf;
        }
    }

    for (gltf.meshes) |*mesh| {
        if (mesh.weights) |weights| {
            if (mesh.primitives.len > 0 and mesh.primitives[0].targets.len != weights.len) {
                return error.InvalidGltf;
            }
        }
        if (mesh.target_names) |names| {
            if (mesh.primitives.len > 0 and mesh.primitives[0].targets.len != names.len) {
                return error.InvalidGltf;
            }
        }
        for (mesh.primitives) |*primitive| {
            if (primitive.type == .invalid) return error.InvalidGltf;
            if (primitive.targets.len != mesh.primitives[0].targets.len) return error.InvalidGltf;
            if (primitive.attributes.len == 0) return error.InvalidGltf;
            const first = &gltf.accessors[primitive.attributes[0].data];
            if (first.count == 0) return error.InvalidGltf;
            for (primitive.attributes) |attribute| {
                if (gltf.accessors[attribute.data].count != first.count) return error.InvalidGltf;
            }
            for (primitive.targets) |target| {
                for (target.attributes) |attribute| {
                    if (gltf.accessors[attribute.data].count != first.count) return error.InvalidGltf;
                }
            }
            if (primitive.indices) |indices_index| {
                const indices = &gltf.accessors[indices_index];
                if (!isIndexType(indices.component_type)) return error.InvalidGltf;
                if (indices.type != .scalar) return error.InvalidGltf;
                if (indices.stride != cgltf.componentSize(indices.component_type)) return error.InvalidGltf;
                if (indices.buffer_view) |view_index| {
                    const view = &gltf.buffer_views[view_index];
                    if (gltf.buffers[view.buffer].data != null) {
                        const bound = try indexBound(
                            gltf,
                            view,
                            indices.offset,
                            indices.component_type,
                            indices.count,
                        );
                        if (bound >= first.count) return error.DataTooShort;
                    }
                }
            }
            for (primitive.mappings) |mapping| {
                if (mapping.variant >= gltf.variants.len) return error.InvalidGltf;
            }
        }
    }

    for (gltf.nodes) |*node| {
        if (node.weights) |weights| {
            if (node.mesh) |mesh_index| {
                const mesh = &gltf.meshes[mesh_index];
                if (mesh.primitives.len > 0 and mesh.primitives[0].targets.len != weights.len) {
                    return error.InvalidGltf;
                }
            }
        }
        if (node.has_mesh_gpu_instancing) {
            if (node.mesh == null) return error.InvalidGltf;
            const attributes = node.mesh_gpu_instancing.attributes;
            if (attributes.len == 0) return error.InvalidGltf;
            const first = &gltf.accessors[attributes[0].data];
            for (attributes) |attribute| {
                if (gltf.accessors[attribute.data].count != first.count) return error.InvalidGltf;
            }
        }
    }

    // A loop in the parents. Each node before `i` is known to reach a
    // root, so a walk up from `i` ends at the first of them it meets.
    // Otherwise a loop is found as Brent's method finds one: the walk
    // compares each node with a mark, which moves up to where the walk
    // is after 1, 2, 4, ... steps.
    for (gltf.nodes, 0..) |*node, i| {
        var mark = i;
        var steps: usize = 0;
        var steps_to_move: usize = 1;
        var next = node.parent;
        while (next) |parent| : (next = gltf.nodes[parent].parent) {
            if (parent < i) break;
            if (parent == mark) return error.InvalidGltf;
            steps += 1;
            if (steps == steps_to_move) {
                mark = parent;
                steps = 0;
                steps_to_move *= 2;
            }
        }
    }

    for (gltf.scenes) |scene| {
        for (scene.nodes) |root| {
            if (gltf.nodes[root].parent != null) return error.InvalidGltf;
        }
    }

    for (gltf.animations) |*animation| {
        for (animation.channels) |channel| {
            const target = channel.target_node orelse continue;
            var components: usize = 1;
            if (channel.target_path == .weights) {
                const mesh_index = gltf.nodes[target].mesh orelse return error.InvalidGltf;
                const mesh = &gltf.meshes[mesh_index];
                if (mesh.primitives.len == 0) return error.InvalidGltf;
                components = mesh.primitives[0].targets.len;
            }
            const sampler = &animation.samplers[channel.sampler];
            const values: usize = if (sampler.interpolation == .cubic_spline) 3 else 1;
            const input = gltf.accessors[sampler.input].count;
            if (input *% components *% values != gltf.accessors[sampler.output].count) {
                return error.InvalidGltf;
            }
        }
    }

    for (gltf.variants) |variant| {
        if (variant.name == null) return error.InvalidGltf;
    }
}

test "maxOf finds the largest at every position of every length and alignment" {
    var storage: [64 + 300]u8 align(64) = undefined;
    inline for (.{ u8, u16, u32 }) |T| {
        for ([_]usize{ 0, 1, 2, 3, 4, 6, 8, 12, 16, 33, 60, 63 }) |shift| {
            for (1..300 / @sizeOf(T)) |count| {
                const bytes = storage[shift..][0 .. count * @sizeOf(T)];
                const values: []align(1) T = @ptrCast(bytes);
                for (0..count) |top| {
                    for (values, 0..) |*v, k| v.* = @intCast(k % 7 + 1);
                    values[top] = std.math.maxInt(T) - 1;
                    try std.testing.expectEqual(std.math.maxInt(T) - 1, maxOf(T, bytes));
                }
            }
        }
    }
}
