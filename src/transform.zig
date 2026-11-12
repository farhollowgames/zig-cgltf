//! A node's transform as a column-major 4x4 matrix, in its parent's space
//! or in the scene's.

const std = @import("std");

const cgltf = @import("cgltf.zig");
const types = @import("types.zig");

/// cgltf's `cgltf_node_transform_local`: the node's `matrix` when it has
/// one, else translation, rotation and scale combined, in cgltf's order
/// of float operations.
pub fn transformLocal(node: *const types.Node) [16]f32 {
    if (node.has_matrix) return node.matrix;
    const tx = node.translation[0];
    const ty = node.translation[1];
    const tz = node.translation[2];
    const qx = node.rotation[0];
    const qy = node.rotation[1];
    const qz = node.rotation[2];
    const qw = node.rotation[3];
    const sx = node.scale[0];
    const sy = node.scale[1];
    const sz = node.scale[2];
    return .{
        (1 - 2 * qy * qy - 2 * qz * qz) * sx,
        (2 * qx * qy + 2 * qz * qw) * sx,
        (2 * qx * qz - 2 * qy * qw) * sx,
        0,
        (2 * qx * qy - 2 * qz * qw) * sy,
        (1 - 2 * qx * qx - 2 * qz * qz) * sy,
        (2 * qy * qz + 2 * qx * qw) * sy,
        0,
        (2 * qx * qz + 2 * qy * qw) * sz,
        (2 * qy * qz - 2 * qx * qw) * sz,
        (1 - 2 * qx * qx - 2 * qy * qy) * sz,
        0,
        tx,
        ty,
        tz,
        1,
    };
}

/// cgltf's `cgltf_node_transform_world`: node `node_index`'s local
/// transform times each parent's in turn. A chain of parents that loops,
/// where cgltf never returns, is `error.ParentCycle`; `validate` refuses
/// such files.
pub fn transformWorld(gltf: *const cgltf.Gltf, node_index: u32) error{ParentCycle}![16]f32 {
    var lm = transformLocal(&gltf.nodes[node_index]);
    var parent = gltf.nodes[node_index].parent;
    var steps: usize = 0;
    while (parent) |p| : (parent = gltf.nodes[p].parent) {
        steps += 1;
        if (steps > gltf.nodes.len) return error.ParentCycle;
        const pm = transformLocal(&gltf.nodes[p]);
        for (0..4) |i| {
            const l0 = lm[i * 4 + 0];
            const l1 = lm[i * 4 + 1];
            const l2 = lm[i * 4 + 2];
            lm[i * 4 + 0] = l0 * pm[0] + l1 * pm[4] + l2 * pm[8];
            lm[i * 4 + 1] = l0 * pm[1] + l1 * pm[5] + l2 * pm[9];
            lm[i * 4 + 2] = l0 * pm[2] + l1 * pm[6] + l2 * pm[10];
        }
        lm[12] += pm[12];
        lm[13] += pm[13];
        lm[14] += pm[14];
    }
    return lm;
}
