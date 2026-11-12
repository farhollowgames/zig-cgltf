//! Reading accessors: one element at a time as floats, unsigned integers
//! or an index, or all of them at once, sparse substitutions included.
//! Every read is checked against the memory the buffer holds; where cgltf
//! would read or write past it, these return `error.OutOfBounds`.

const std = @import("std");
const native = @import("builtin").cpu.arch.endian();

const cgltf = @import("cgltf.zig");
const types = @import("types.zig");
const Gltf = cgltf.Gltf;
const Accessor = types.Accessor;
const ComponentType = types.ComponentType;

pub const ReadError = error{OutOfBounds};

/// cgltf's `cgltf_buffer_view_data`: the view's own `data` when set, else
/// its buffer's memory from the view's offset on, or null before the
/// buffer is loaded. The slice runs to the end of the buffer's memory, as
/// cgltf's pointer does.
pub fn bufferViewData(gltf: *const Gltf, view_index: u32) ReadError!?[]const u8 {
    const view = &gltf.buffer_views[view_index];
    if (view.data) |data| return data;
    const data = gltf.buffers[view.buffer].data orelse return null;
    if (view.offset > data.len) return error.OutOfBounds;
    return data[view.offset..];
}

/// cgltf's `cgltf_find_accessor`: the accessor of the primitive's first
/// attribute of `attribute_type` with set number `index`.
pub fn findAccessor(primitive: *const types.Primitive, attribute_type: types.AttributeType, index: i32) ?u32 {
    for (primitive.attributes) |attribute| {
        if (attribute.type == attribute_type and attribute.index == index) return attribute.data;
    }
    return null;
}

/// `count` bytes of `memory` from `offset`, which cgltf computes with
/// wrapping pointer arithmetic.
fn bytesAt(memory: []const u8, offset: usize, count: usize) ReadError![]const u8 {
    if (count == 0) return &.{};
    if (offset > memory.len or count > memory.len - offset) return error.OutOfBounds;
    return memory[offset..][0..count];
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], native);
}

/// cgltf's `cgltf_component_read_index`: 0 for a type that is not an
/// unsigned integer.
fn componentReadIndex(bytes: []const u8, component_type: ComponentType) usize {
    return switch (component_type) {
        .r_16u => readInt(u16, bytes),
        .r_32u => readInt(u32, bytes),
        .r_8u => bytes[0],
        else => 0,
    };
}

/// The integer type a component is stored as; a float is read as its bits.
fn Stored(comptime component_type: ComponentType) type {
    return switch (component_type) {
        .r_8 => i8,
        .r_8u, .invalid => u8,
        .r_16 => i16,
        .r_16u => u16,
        .r_32u, .r_32f => u32,
    };
}

/// cgltf's `cgltf_component_read_float` of components already read: a
/// float as it is, a normalized integer scaled to [0, 1] or [-1, 1], 0
/// for a type it does not read, and any other integer converted.
fn toFloats(
    comptime component_type: ComponentType,
    comptime normalized: bool,
    comptime lanes: usize,
    stored: @Vector(lanes, Stored(component_type)),
) @Vector(lanes, f32) {
    const Floats = @Vector(lanes, f32);
    if (component_type == .invalid) return @splat(0);
    if (component_type == .r_32f) return @bitCast(stored);
    const floats: Floats = @floatFromInt(stored);
    if (!normalized) return floats;
    const scale: f32 = switch (component_type) {
        .r_16 => 32767,
        .r_16u => 65535,
        .r_8 => 127,
        .r_8u => 255,
        else => return @splat(0),
    };
    return floats / @as(Floats, @splat(scale));
}

/// One element of type `t` from `bytes`, which hold its whole span, as
/// cgltf's `cgltf_element_read_float` reads it.
fn readElementFloats(
    comptime component_type: ComponentType,
    comptime normalized: bool,
    comptime t: types.Type,
    bytes: []const u8,
    out: *[cgltf.numComponents(t)]f32,
) void {
    const T = Stored(component_type);
    const n = comptime cgltf.numComponents(t);
    if (component_type == .invalid) {
        out.* = @splat(0);
        return;
    }
    const offsets = comptime componentOffsets(t, @sizeOf(T));
    var stored: @Vector(n, T) = undefined;
    inline for (0..n) |i| {
        const at = if (offsets.len > 0) offsets[i] else @sizeOf(T) * i;
        stored[i] = readInt(T, bytes[at..]);
    }
    out.* = toFloats(component_type, normalized, n, stored);
}

fn componentReadUint(bytes: []const u8, component_type: ComponentType) u32 {
    return switch (component_type) {
        .r_8 => @bitCast(@as(i32, @as(i8, @bitCast(bytes[0])))),
        .r_8u => bytes[0],
        .r_16 => @bitCast(@as(i32, readInt(i16, bytes))),
        .r_16u => readInt(u16, bytes),
        .r_32u => readInt(u32, bytes),
        else => 0,
    };
}

/// The byte offsets of each component in an element: glTF pads the
/// columns of small matrices to four bytes.
fn componentOffsets(t: types.Type, component_size: usize) []const u8 {
    if (t == .mat2 and component_size == 1) return &.{ 0, 1, 4, 5 };
    if (t == .mat3 and component_size == 1) return &.{ 0, 1, 2, 4, 5, 6, 8, 9, 10 };
    if (t == .mat3 and component_size == 2) return &.{ 0, 2, 4, 8, 10, 12, 16, 18, 20 };
    return &.{};
}

/// The bytes an element's components span.
fn elementSpan(t: types.Type, component_type: ComponentType) usize {
    const component_size = cgltf.componentSize(component_type);
    const offsets = componentOffsets(t, component_size);
    if (offsets.len > 0) return offsets[offsets.len - 1] + component_size;
    return cgltf.numComponents(t) * component_size;
}

/// The bytes `componentReadIndex` reads: none for a type it reads as 0.
fn indexSize(component_type: ComponentType) usize {
    return switch (component_type) {
        .r_8u, .r_16u, .r_32u => cgltf.componentSize(component_type),
        else => 0,
    };
}

/// cgltf's `cgltf_element_read_float`, the element at `offset` in `memory`.
/// Inline, so that a caller's loop over one accessor's elements can choose
/// the component and element type once, outside the loop.
inline fn elementReadFloat(
    memory: []const u8,
    offset: usize,
    accessor: *const Accessor,
    out: []f32,
) ReadError!bool {
    const num_components = cgltf.numComponents(accessor.type);
    if (out.len < num_components) return false;
    const bytes = try bytesAt(memory, offset, elementSpan(accessor.type, accessor.component_type));
    switch (accessor.component_type) {
        inline else => |component_type| switch (accessor.type) {
            inline else => |t| {
                const dest = out[0..comptime cgltf.numComponents(t)];
                if (accessor.normalized) {
                    readElementFloats(component_type, true, t, bytes, dest);
                } else {
                    readElementFloats(component_type, false, t, bytes, dest);
                }
            },
        },
    }
    return true;
}

fn elementReadUint(memory: []const u8, offset: usize, accessor: *const Accessor, out: []u32) ReadError!bool {
    const num_components = cgltf.numComponents(accessor.type);
    if (out.len < num_components) return false;
    switch (accessor.type) {
        .mat2, .mat3, .mat4 => return false,
        else => {},
    }
    const component_size = cgltf.componentSize(accessor.component_type);
    const bytes = try bytesAt(memory, offset, elementSpan(accessor.type, accessor.component_type));
    for (out[0..num_components], 0..) |*value, i| {
        value.* = componentReadUint(bytes[component_size * i ..], accessor.component_type);
    }
    return true;
}

const Element = struct { memory: []const u8, offset: usize };

/// cgltf's `cgltf_find_sparse_index`: where the sparse values hold the
/// element at `needle`, found by binary search over the sorted indices.
fn findSparseIndex(gltf: *const Gltf, accessor: *const Accessor, needle: usize) ReadError!?Element {
    const sparse = &accessor.sparse;
    const index_data = try bufferViewData(gltf, sparse.indices_buffer_view.?) orelse return null;
    const value_data = try bufferViewData(gltf, sparse.values_buffer_view.?) orelse return null;
    const index_stride = cgltf.componentSize(sparse.indices_component_type);
    const index_size = indexSize(sparse.indices_component_type);
    var offset: usize = 0;
    var length = sparse.count;
    while (length != 0) {
        const rem = length % 2;
        length /= 2;
        const at = sparse.indices_byte_offset +% (offset +% length) *% index_stride;
        const index = componentReadIndex(try bytesAt(index_data, at, index_size), sparse.indices_component_type);
        offset += if (index < needle) length + rem else 0;
    }
    if (offset == sparse.count) return null;
    const at = sparse.indices_byte_offset +% offset *% index_stride;
    const index = componentReadIndex(try bytesAt(index_data, at, index_size), sparse.indices_component_type);
    if (index != needle) return null;
    return .{ .memory = value_data, .offset = sparse.values_byte_offset +% offset *% accessor.stride };
}

/// cgltf's `cgltf_accessor_read_float`: element `index` as floats into
/// `out`, normalized integers scaled to [0, 1] or [-1, 1]. False when
/// `out` is shorter than an element or the buffer is not loaded; an
/// accessor with no buffer view reads as zeros.
pub fn readFloat(gltf: *const Gltf, accessor: *const Accessor, index: usize, out: []f32) ReadError!bool {
    if (accessor.is_sparse) {
        if (try findSparseIndex(gltf, accessor, index)) |element| {
            return elementReadFloat(element.memory, element.offset, accessor, out);
        }
    }
    const view = accessor.buffer_view orelse {
        @memset(out, 0);
        return true;
    };
    const memory = try bufferViewData(gltf, view) orelse return false;
    return elementReadFloat(memory, accessor.offset +% accessor.stride *% index, accessor, out);
}

/// cgltf's `cgltf_accessor_read_uint`: element `index` as unsigned
/// integers into `out`, signed ones sign-extended. False for a matrix, a
/// short `out` or an unloaded buffer.
pub fn readUint(gltf: *const Gltf, accessor: *const Accessor, index: usize, out: []u32) ReadError!bool {
    if (accessor.is_sparse) {
        if (try findSparseIndex(gltf, accessor, index)) |element| {
            return elementReadUint(element.memory, element.offset, accessor, out);
        }
    }
    const view = accessor.buffer_view orelse {
        @memset(out, 0);
        return true;
    };
    const memory = try bufferViewData(gltf, view) orelse return false;
    return elementReadUint(memory, accessor.offset +% accessor.stride *% index, accessor, out);
}

/// cgltf's `cgltf_accessor_read_index`: element `index`'s first component
/// as an index; 0 for a type that is not an unsigned integer, and for no
/// buffer view or an unloaded buffer.
pub fn readIndex(gltf: *const Gltf, accessor: *const Accessor, index: usize) ReadError!usize {
    const size = indexSize(accessor.component_type);
    if (accessor.is_sparse) {
        if (try findSparseIndex(gltf, accessor, index)) |element| {
            return componentReadIndex(try bytesAt(element.memory, element.offset, size), accessor.component_type);
        }
    }
    const view = accessor.buffer_view orelse return 0;
    const memory = try bufferViewData(gltf, view) orelse return 0;
    const bytes = try bytesAt(memory, accessor.offset +% accessor.stride *% index, size);
    return componentReadIndex(bytes, accessor.component_type);
}

/// The floats `unpackFloats` can write: every component of every element.
pub fn unpackFloatsCount(accessor: *const Accessor) usize {
    return accessor.count *% cgltf.numComponents(accessor.type);
}

/// cgltf's `cgltf_accessor_unpack_floats`: as many whole elements as fit
/// in `out`, as floats, then the sparse values over them. Returns the
/// floats written, or 0 when the buffer is not loaded or an element does
/// not convert. A sparse index whose element lies past the end of `out`
/// is `error.OutOfBounds`, where cgltf writes past it.
pub fn unpackFloats(gltf: *const Gltf, accessor: *const Accessor, out: []f32) ReadError!usize {
    const floats_per_element = cgltf.numComponents(accessor.type);
    const float_count = @min(unpackFloatsCount(accessor), out.len);
    const element_count = float_count / floats_per_element;
    const used = out[0 .. element_count * floats_per_element];

    if (accessor.buffer_view) |view| {
        const memory = try bufferViewData(gltf, view) orelse return 0;
        if (accessor.component_type == .r_32f and accessor.stride == floats_per_element * 4) {
            const bytes = try bytesAt(memory, accessor.offset, used.len * 4);
            @memcpy(std.mem.sliceAsBytes(used), bytes);
        } else {
            var offset = accessor.offset;
            var at: usize = 0;
            while (at < used.len) : (at += floats_per_element) {
                const dest = used[at..][0..floats_per_element];
                if (!try elementReadFloat(memory, offset, accessor, dest)) return 0;
                offset +%= accessor.stride;
            }
        }
    } else {
        @memset(used, 0);
    }

    if (accessor.is_sparse) {
        const sparse = &accessor.sparse;
        const index_data = try bufferViewData(gltf, sparse.indices_buffer_view.?) orelse return 0;
        const value_data = try bufferViewData(gltf, sparse.values_buffer_view.?) orelse return 0;
        const index_stride = cgltf.componentSize(sparse.indices_component_type);
        const index_size = indexSize(sparse.indices_component_type);
        var index_offset = sparse.indices_byte_offset;
        var value_offset = sparse.values_byte_offset;
        for (0..sparse.count) |_| {
            const index_bytes = try bytesAt(index_data, index_offset, index_size);
            const writer_index = componentReadIndex(index_bytes, sparse.indices_component_type);
            const start = std.math.mul(usize, writer_index, floats_per_element) catch
                return error.OutOfBounds;
            if (start > out.len or out.len - start < floats_per_element) return error.OutOfBounds;
            if (!try elementReadFloat(value_data, value_offset, accessor, out[start..][0..floats_per_element])) {
                return 0;
            }
            index_offset +%= index_stride;
            value_offset +%= accessor.stride;
        }
    }
    return used.len;
}

/// The count `unpackIndices` reports with no output: the element count.
pub fn unpackIndicesCount(accessor: *const Accessor) usize {
    return accessor.count;
}

/// cgltf's `cgltf_accessor_unpack_indices` into `out`, whose `T` is `u8`,
/// `u16` or `u32`: up to `out.len` indices, one from each element. Returns
/// the indices written, or 0 for a sparse accessor, no buffer view, an
/// unloaded buffer, or indices wider than `out`'s.
pub fn unpackIndices(
    comptime T: type,
    gltf: *const Gltf,
    accessor: *const Accessor,
    out: []T,
) ReadError!usize {
    if (T != u8 and T != u16 and T != u32) @compileError("indices unpack to u8, u16 or u32");
    const out_component_size = @sizeOf(T);

    const numbers_per_element = cgltf.numComponents(accessor.type);
    const available = accessor.count *% numbers_per_element;
    const index_count = @min(available, out.len);
    const index_component_size = cgltf.componentSize(accessor.component_type);

    if (accessor.is_sparse) return 0;
    const view = accessor.buffer_view orelse return 0;
    if (index_component_size > out_component_size) return 0;
    const memory = try bufferViewData(gltf, view) orelse return 0;

    if (index_component_size == out_component_size and
        accessor.stride == out_component_size * numbers_per_element)
    {
        const bytes = try bytesAt(memory, accessor.offset, index_count * index_component_size);
        @memcpy(std.mem.sliceAsBytes(out[0..index_count]), bytes);
        return index_count;
    }
    const size = indexSize(accessor.component_type);
    var offset = accessor.offset;
    for (out[0..index_count]) |*value| {
        const bytes = try bytesAt(memory, offset, size);
        value.* = @truncate(componentReadIndex(bytes, accessor.component_type));
        offset +%= accessor.stride;
    }
    return index_count;
}
