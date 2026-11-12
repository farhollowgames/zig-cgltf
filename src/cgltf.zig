//! A Zig port of cgltf, the glTF 2.0 loader, and of its writer: parse glTF
//! and GLB files, load their buffers, check them against the glTF rules,
//! read their accessors as floats and integers, and write them back as
//! glTF or GLB.
//!
//! References between objects are indices into the `Gltf` arrays, so a
//! `Gltf` can be copied and moved freely. Everything it holds lives in its
//! arena and goes with `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.zig");
const parse_json = @import("parse.zig");
const load = @import("load.zig");
const check = @import("validate.zig");
const accessor = @import("accessor.zig");
const transform = @import("transform.zig");
const write_json = @import("write.zig");

/// The C library's `atoi`, `atoll` and `atof` as glibc reads text in the C
/// locale, which cgltf reads every JSON number with.
pub const number = @import("number.zig");

pub const invalid_index = types.invalid_index;
pub const FileType = types.FileType;
pub const BufferViewType = types.BufferViewType;
pub const AttributeType = types.AttributeType;
pub const ComponentType = types.ComponentType;
pub const Type = types.Type;
pub const PrimitiveType = types.PrimitiveType;
pub const AlphaMode = types.AlphaMode;
pub const AnimationPathType = types.AnimationPathType;
pub const InterpolationType = types.InterpolationType;
pub const CameraType = types.CameraType;
pub const LightType = types.LightType;
pub const DataFreeMethod = types.DataFreeMethod;
pub const FilterType = types.FilterType;
pub const WrapMode = types.WrapMode;
pub const MeshoptCompressionMode = types.MeshoptCompressionMode;
pub const MeshoptCompressionFilter = types.MeshoptCompressionFilter;
pub const Extras = types.Extras;
pub const Extension = types.Extension;
pub const Buffer = types.Buffer;
pub const MeshoptCompression = types.MeshoptCompression;
pub const BufferView = types.BufferView;
pub const AccessorSparse = types.AccessorSparse;
pub const Accessor = types.Accessor;
pub const Attribute = types.Attribute;
pub const Image = types.Image;
pub const Sampler = types.Sampler;
pub const Texture = types.Texture;
pub const TextureTransform = types.TextureTransform;
pub const TextureView = types.TextureView;
pub const PbrMetallicRoughness = types.PbrMetallicRoughness;
pub const PbrSpecularGlossiness = types.PbrSpecularGlossiness;
pub const Clearcoat = types.Clearcoat;
pub const Transmission = types.Transmission;
pub const Ior = types.Ior;
pub const Specular = types.Specular;
pub const Volume = types.Volume;
pub const Sheen = types.Sheen;
pub const EmissiveStrength = types.EmissiveStrength;
pub const Iridescence = types.Iridescence;
pub const DiffuseTransmission = types.DiffuseTransmission;
pub const Anisotropy = types.Anisotropy;
pub const Dispersion = types.Dispersion;
pub const Material = types.Material;
pub const MaterialMapping = types.MaterialMapping;
pub const MorphTarget = types.MorphTarget;
pub const DracoMeshCompression = types.DracoMeshCompression;
pub const MeshGpuInstancing = types.MeshGpuInstancing;
pub const Primitive = types.Primitive;
pub const Mesh = types.Mesh;
pub const Skin = types.Skin;
pub const CameraPerspective = types.CameraPerspective;
pub const CameraOrthographic = types.CameraOrthographic;
pub const Camera = types.Camera;
pub const Light = types.Light;
pub const Node = types.Node;
pub const Scene = types.Scene;
pub const AnimationSampler = types.AnimationSampler;
pub const AnimationChannel = types.AnimationChannel;
pub const Animation = types.Animation;
pub const MaterialVariant = types.MaterialVariant;
pub const Asset = types.Asset;

pub const loadBuffers = load.loadBuffers;
pub const loadBufferBase64 = load.loadBufferBase64;
pub const decodeString = load.decodeString;
pub const decodeUri = load.decodeUri;
pub const validate = check.validate;
pub const readFloat = accessor.readFloat;
pub const readUint = accessor.readUint;
pub const readIndex = accessor.readIndex;
pub const unpackFloats = accessor.unpackFloats;
pub const unpackFloatsCount = accessor.unpackFloatsCount;
pub const unpackIndices = accessor.unpackIndices;
pub const unpackIndicesCount = accessor.unpackIndicesCount;
pub const bufferViewData = accessor.bufferViewData;
pub const findAccessor = accessor.findAccessor;
pub const transformLocal = transform.transformLocal;
pub const transformWorld = transform.transformWorld;
pub const WriteError = write_json.WriteError;
pub const write = write_json.write;
pub const writeFile = write_json.writeFile;

/// cgltf's results other than success, and the port's own refusals.
pub const Error = error{
    DataTooShort,
    UnknownFormat,
    InvalidJson,
    InvalidGltf,
    InvalidOptions,
    FileNotFound,
    IoError,
    OutOfMemory,
    LegacyGltf,
    /// A read or write past the end of a buffer, an output or a string,
    /// which cgltf would make unchecked.
    OutOfBounds,
};

/// Reads the files a glTF names: the file itself for `parseFile`, and
/// buffers for `loadBuffers`. The default reads with `std.Io` from the
/// working directory.
pub const FileReader = struct {
    context: ?*anyopaque = null,
    /// Returns the file's first `size` bytes, or the whole file when
    /// `size` is 0. The memory is the reader's until `release`.
    read: *const fn (
        context: ?*anyopaque,
        gpa: Allocator,
        io: Io,
        path: []const u8,
        size: usize,
    ) Error![]u8 = load.defaultRead,
    release: *const fn (context: ?*anyopaque, gpa: Allocator, data: []u8) void = load.defaultRelease,

    pub const default: FileReader = .{};
};

pub const Options = struct {
    /// `.invalid` detects GLB from its magic number.
    file_type: FileType = .invalid,
    /// The JSON tokens to allocate; 0 counts them first.
    json_token_count: usize = 0,
    file_reader: FileReader = .default,
};

/// cgltf's `cgltf_data`: the parsed file.
pub const Gltf = struct {
    /// Holds everything below except `file_data` and the buffers'
    /// `data`, which `deinit` frees as their `data_free_method` says.
    arena: std.heap.ArenaAllocator,
    file_type: FileType = .invalid,
    /// What `parseFile` read, released by `deinit`.
    file_data: ?[]u8 = null,
    asset: Asset = .{},
    meshes: []Mesh = &.{},
    materials: []Material = &.{},
    accessors: []Accessor = &.{},
    buffer_views: []BufferView = &.{},
    buffers: []Buffer = &.{},
    images: []Image = &.{},
    textures: []Texture = &.{},
    samplers: []Sampler = &.{},
    skins: []Skin = &.{},
    cameras: []Camera = &.{},
    lights: []Light = &.{},
    nodes: []Node = &.{},
    scenes: []Scene = &.{},
    scene: ?u32 = null,
    animations: []Animation = &.{},
    variants: []MaterialVariant = &.{},
    extras: Extras = .{},
    data_extensions: []Extension = &.{},
    extensions_used: [][:0]u8 = &.{},
    extensions_required: [][:0]u8 = &.{},
    /// The JSON text, inside the bytes given to `parse`, which must
    /// outlive the `Gltf`; `parseFile`'s points into `file_data`.
    json: []const u8 = &.{},
    /// A GLB's BIN chunk, inside the parsed bytes as `json` is.
    bin: ?[]const u8 = null,
    file_reader: FileReader = .default,

    /// Frees everything, releasing what the file reader read. Slices into
    /// the `Gltf` are stale after it.
    pub fn deinit(gltf: *Gltf) void {
        const gpa = gltf.arena.child_allocator;
        for (gltf.buffers) |buffer| {
            const data = @constCast(buffer.data orelse continue);
            switch (buffer.data_free_method) {
                .none => {},
                .file_release => gltf.file_reader.release(gltf.file_reader.context, gpa, data),
                .memory_free => gpa.free(data),
            }
        }
        if (gltf.file_data) |data| gltf.file_reader.release(gltf.file_reader.context, gpa, data);
        gltf.arena.deinit();
        gltf.* = undefined;
    }
};

const glb_magic: u32 = 0x46546C67;
const glb_version: u32 = 2;
const glb_magic_json_chunk: u32 = 0x4E4F534A;
const glb_magic_bin_chunk: u32 = 0x004E4942;
const glb_header_size = 12;
const glb_chunk_header_size = 8;

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .native);
}

/// cgltf's `cgltf_parse`: a glTF or GLB from memory. The `Gltf` points
/// into `bytes`, which must outlive it.
pub fn parse(gpa: Allocator, bytes: []const u8, options: Options) Error!Gltf {
    if (bytes.len < glb_header_size) return error.DataTooShort;
    var file_type = options.file_type;
    if (readU32(bytes, 0) != glb_magic) {
        if (file_type == .invalid) {
            file_type = .gltf;
        } else if (file_type == .glb) {
            return error.UnknownFormat;
        }
    }
    var gltf: Gltf = .{ .arena = .init(gpa), .file_reader = options.file_reader };
    errdefer gltf.arena.deinit();

    if (file_type == .gltf) {
        try parse_json.parseJson(&gltf, gpa, bytes, options.json_token_count);
        gltf.file_type = .gltf;
        return gltf;
    }

    const version = readU32(bytes, 4);
    if (version != glb_version) {
        return if (version < glb_version) error.LegacyGltf else error.UnknownFormat;
    }
    if (readU32(bytes, 8) > bytes.len) return error.DataTooShort;
    if (glb_header_size + glb_chunk_header_size > bytes.len) return error.DataTooShort;
    const json_length = readU32(bytes, glb_header_size);
    const after_json_header = bytes.len - glb_header_size - glb_chunk_header_size;
    if (json_length > after_json_header) return error.DataTooShort;
    if (readU32(bytes, glb_header_size + 4) != glb_magic_json_chunk) return error.UnknownFormat;
    const json_start = glb_header_size + glb_chunk_header_size;
    const json_chunk = bytes[json_start..][0..json_length];

    var bin: ?[]const u8 = null;
    if (glb_chunk_header_size <= after_json_header - json_length) {
        const bin_header = json_start + json_length;
        const bin_length = readU32(bytes, bin_header);
        if (bin_length > after_json_header - json_length - glb_chunk_header_size) {
            return error.DataTooShort;
        }
        if (readU32(bytes, bin_header + 4) != glb_magic_bin_chunk) return error.UnknownFormat;
        bin = bytes[bin_header + glb_chunk_header_size ..][0..bin_length];
    }

    try parse_json.parseJson(&gltf, gpa, json_chunk, options.json_token_count);
    gltf.file_type = .glb;
    gltf.bin = bin;
    return gltf;
}

/// cgltf's `cgltf_parse_file`: reads `path` with the options' file reader
/// and parses it. The `Gltf` keeps the file until `deinit`.
pub fn parseFile(gpa: Allocator, io: Io, path: []const u8, options: Options) Error!Gltf {
    const reader = options.file_reader;
    const data = try reader.read(reader.context, gpa, io, path, 0);
    var gltf = parse(gpa, data, options) catch |err| {
        reader.release(reader.context, gpa, data);
        return err;
    };
    gltf.file_data = data;
    return gltf;
}

/// cgltf's `cgltf_copy_extras_json`, deprecated there in favour of
/// `Extras.data`: copies the extras' JSON text into `dest` with a NUL
/// after it, cut to fit, and returns the bytes written before the NUL.
/// With no `dest`, returns the size `dest` needs, NUL included.
pub fn copyExtrasJson(gltf: *const Gltf, extras: *const Extras, dest: ?[]u8) Error!usize {
    const json_size = extras.end_offset -% extras.start_offset;
    const out = dest orelse return json_size +% 1;
    // cgltf writes `dest_size - 1` bytes when the text is more than one
    // byte longer than `dest`, and all of it otherwise, which can be one
    // byte past `dest`.
    const copy = if (out.len +% 1 < json_size) out.len -% 1 else json_size;
    if (copy >= out.len) return error.OutOfBounds;
    if (extras.start_offset > gltf.json.len or copy > gltf.json.len - extras.start_offset) {
        return error.OutOfBounds;
    }
    const source = gltf.json[extras.start_offset..][0..copy];
    // strncpy stops at a NUL and pads with NULs.
    const text = source[0 .. std.mem.indexOfScalar(u8, source, 0) orelse copy];
    @memcpy(out[0..text.len], text);
    @memset(out[text.len..copy], 0);
    out[copy] = 0;
    return copy;
}

/// cgltf's `cgltf_num_components`.
pub fn numComponents(t: Type) usize {
    return switch (t) {
        .vec2 => 2,
        .vec3 => 3,
        .vec4, .mat2 => 4,
        .mat3 => 9,
        .mat4 => 16,
        .invalid, .scalar => 1,
    };
}

/// cgltf's `cgltf_component_size`, in bytes.
pub fn componentSize(component_type: ComponentType) usize {
    return switch (component_type) {
        .r_8, .r_8u => 1,
        .r_16, .r_16u => 2,
        .r_32u, .r_32f => 4,
        .invalid => 0,
    };
}

/// cgltf's `cgltf_calc_size`: an element's size in bytes, with the padding
/// glTF puts in the columns of small matrices.
pub fn calcSize(t: Type, component_type: ComponentType) usize {
    const component_size = componentSize(component_type);
    if (t == .mat2 and component_size == 1) return 8 * component_size;
    if (t == .mat3 and (component_size == 1 or component_size == 2)) return 12 * component_size;
    return component_size * numComponents(t);
}

test {
    _ = number;
    _ = @import("jsmn.zig");
    _ = parse_json;
    _ = load;
    _ = check;
    _ = accessor;
    _ = transform;
    _ = write_json;
}

const testing = std.testing;

test "a small glTF parses, loads its buffer, validates and reads" {
    const json =
        \\{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
        \\"nodes":[{"mesh":0,"translation":[1,2,3],"children":[1]},{"scale":[2,2,2]}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        \\"buffers":[{"byteLength":42,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAABAAIA"}],
        \\"bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}]}
    ;
    var gltf = try parse(testing.allocator, json, .{});
    defer gltf.deinit();
    try loadBuffers(&gltf, testing.io, null);
    try validate(&gltf);
    var position: [3]f32 = undefined;
    try testing.expect(try readFloat(&gltf, &gltf.accessors[0], 1, &position));
    try testing.expectEqual([3]f32{ 1, 0, 0 }, position);
    try testing.expectEqual(@as(usize, 2), try readIndex(&gltf, &gltf.accessors[1], 2));
    var indices: [3]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), try unpackIndices(u32, &gltf, &gltf.accessors[1], &indices));
    try testing.expectEqual([3]u32{ 0, 1, 2 }, indices);
    const world = try transformWorld(&gltf, 1);
    try testing.expectEqual(@as(f32, 2), world[0]);
    try testing.expectEqual(@as(f32, 3), world[14]);
    try testing.expectEqual(@as(?u32, 0), gltf.nodes[1].parent);
}

test "a failed allocation anywhere in a parse leaks nothing" {
    const json =
        \\{"asset":{"version":"2.0","extras":{"a":1}},"nodes":[{"name":"n","extensions":{"X":{}}}],
        \\"extensionsUsed":["X"]}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, text: []const u8) !void {
            var gltf = try parse(gpa, text, .{});
            gltf.deinit();
        }
    }.run, .{json});
}
