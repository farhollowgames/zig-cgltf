//! A node's transform as a column-major 4x4 matrix, in its parent's space
//! or in the scene's.

const std = @import("std");

const cgltf = @import("cgltf.zig");
const types = @import("types.zig");

/// cgltf's `cgltf_node_transform_local`: the node's `matrix` when it has
/// one, else translation, rotation and scale combined, in cgltf's order
/// of float operations.
pub fn transformLocal(node: *const types.Node) [16]f32 {
    return @bitCast(columnsLocal(node));
}

const V = @Vector(4, f32);

/// `transformLocal` as four columns. Each rotation value is cgltf's
/// `first - a * b - c * d` or `a * b +- c * d`, computed here as
/// `(first + sign * a * b) + sign * c * d` with `-0.0` as the first of
/// the two-term values, which gives the same bits: negation and adding
/// `-0.0` are exact.
fn columnsLocal(node: *const types.Node) [4]V {
    if (node.has_matrix) return @bitCast(node.matrix);
    const q: V = node.rotation;
    const q2 = q * @as(V, @splat(2));
    const s = node.scale;
    const z = -0.0;
    const c0 = rotationColumn(q2, q, .{ 1, z, z, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 1, 2, 0 }, .{ -1, 1, 1, 0 }, .{ 2, 2, 1, 0 }, .{ 2, 3, 3, 0 }, .{ -1, 1, -1, 0 });
    const c1 = rotationColumn(q2, q, .{ z, 1, z, 0 }, .{ 0, 0, 1, 0 }, .{ 1, 0, 2, 0 }, .{ 1, -1, 1, 0 }, .{ 2, 2, 0, 0 }, .{ 3, 2, 3, 0 }, .{ -1, -1, 1, 0 });
    const c2 = rotationColumn(q2, q, .{ z, z, 1, 0 }, .{ 0, 1, 0, 0 }, .{ 2, 2, 0, 0 }, .{ 1, 1, -1, 0 }, .{ 1, 0, 1, 0 }, .{ 3, 3, 1, 0 }, .{ 1, -1, -1, 0 });
    const rows: @Vector(4, bool) = .{ true, true, true, false };
    const zero: V = @splat(0);
    return .{
        @select(f32, rows, c0 * @as(V, @splat(s[0])), zero),
        @select(f32, rows, c1 * @as(V, @splat(s[1])), zero),
        @select(f32, rows, c2 * @as(V, @splat(s[2])), zero),
        .{ node.translation[0], node.translation[1], node.translation[2], 1 },
    };
}

inline fn rotationColumn(
    q2: V,
    q: V,
    first: V,
    comptime a: @Vector(4, i32),
    comptime b: @Vector(4, i32),
    sign_ab: V,
    comptime c: @Vector(4, i32),
    comptime d: @Vector(4, i32),
    sign_cd: V,
) V {
    const ab = @shuffle(f32, q2, undefined, a) * @shuffle(f32, q, undefined, b);
    const cd = @shuffle(f32, q2, undefined, c) * @shuffle(f32, q, undefined, d);
    return (first + sign_ab * ab) + sign_cd * cd;
}

/// cgltf's `cgltf_node_transform_world`: node `node_index`'s local
/// transform times each parent's in turn. A chain of parents that loops,
/// where cgltf never returns, is `error.ParentCycle`; `validate` refuses
/// such files.
pub fn transformWorld(gltf: *const cgltf.Gltf, node_index: u32) error{ParentCycle}![16]f32 {
    // cgltf multiplies only the first three rows; each column's fourth
    // value is kept as the local transform has it.
    const rows: @Vector(4, bool) = .{ true, true, true, false };
    var lm = columnsLocal(&gltf.nodes[node_index]);
    var parent = gltf.nodes[node_index].parent;
    var steps: usize = 0;
    while (parent) |p| : (parent = gltf.nodes[p].parent) {
        steps += 1;
        if (steps > gltf.nodes.len) return error.ParentCycle;
        const pm = columnsLocal(&gltf.nodes[p]);
        inline for (&lm, 0..) |*column, i| {
            const l = column.*;
            var r = @as(V, @splat(l[0])) * pm[0] + @as(V, @splat(l[1])) * pm[1] + @as(V, @splat(l[2])) * pm[2];
            if (i == 3) r += pm[3];
            column.* = @select(f32, rows, r, l);
        }
    }
    return @bitCast(lm);
}
