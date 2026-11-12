//! Seeded fuzzing of whole files through both: byte mutations of small
//! sample models, GLB containers and upstream's fuzz corpus with its
//! dictionary, and random glTF documents built from the glTF grammar,
//! with buffers, references in and out of range, and every extension.

const std = @import("std");
const cgltf = @import("cgltf");
const test_options = @import("test_options");
const oracle = @import("oracle.zig");
const samples = @import("samples.zig");
const fuzz = @import("fuzz.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const Seed = struct {
    bytes: []u8,
    /// Where the file's buffers are, for its external `.bin` files.
    path: [:0]const u8,
};

const Corpus = struct {
    seeds: std.ArrayList(Seed) = .empty,
    dictionary: std.ArrayList([]u8) = .empty,
    paths: [][:0]u8 = &.{},

    fn deinit(corpus: *Corpus, gpa: Allocator) void {
        for (corpus.seeds.items) |seed| gpa.free(seed.bytes);
        corpus.seeds.deinit(gpa);
        for (corpus.dictionary.items) |word| gpa.free(word);
        corpus.dictionary.deinit(gpa);
        samples.freePaths(gpa, corpus.paths);
    }
};

const reference_dir = std.fs.path.dirname(test_options.reference_header).?;

/// The sample models of at most 32 KiB, upstream's fuzz corpus, and
/// upstream's AFL dictionary.
fn loadCorpus(gpa: Allocator, io: std.Io) !Corpus {
    var corpus: Corpus = .{};
    errdefer corpus.deinit(gpa);
    corpus.paths = try samples.modelPaths(gpa, io);
    const cwd = std.Io.Dir.cwd();
    for (corpus.paths) |path| {
        const bytes = cwd.readFileAlloc(io, path, gpa, .limited(32 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => continue,
            else => return err,
        };
        errdefer gpa.free(bytes);
        try corpus.seeds.append(gpa, .{ .bytes = bytes, .path = path });
    }
    for ([_][]const u8{ "BadBasisU.gltf", "Box.glb", "TriangleWithoutIndices.gltf", "WaterBottle.gltf" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ reference_dir, "fuzz", "data", name });
        defer gpa.free(path);
        const bytes = try cwd.readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        try corpus.seeds.append(gpa, .{ .bytes = bytes, .path = corpus.paths[0] });
    }
    const dict_path = try std.fs.path.join(gpa, &.{ reference_dir, "fuzz", "gltf.dict" });
    defer gpa.free(dict_path);
    const dict = try cwd.readFileAlloc(io, dict_path, gpa, .unlimited);
    defer gpa.free(dict);
    var lines = std.mem.splitScalar(u8, dict, '\n');
    while (lines.next()) |line| {
        const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        if (line[0] == '#') continue;
        const close = std.mem.lastIndexOfScalar(u8, line, '"').?;
        if (close <= open) continue;
        var word: std.ArrayList(u8) = .empty;
        errdefer word.deinit(gpa);
        var i = open + 1;
        while (i < close) : (i += 1) {
            if (line[i] == '\\' and i + 1 < close) {
                i += 1;
                if (line[i] == 'x' and i + 2 < close) {
                    try word.append(gpa, try std.fmt.parseInt(u8, line[i + 1 .. i + 3], 16));
                    i += 2;
                } else {
                    try word.append(gpa, line[i]);
                }
            } else {
                try word.append(gpa, line[i]);
            }
        }
        try corpus.dictionary.append(gpa, try word.toOwnedSlice(gpa));
    }
    return corpus;
}

/// Applies one to eight random edits to `bytes`.
fn mutate(gpa: Allocator, random: std.Random, corpus: *const Corpus, bytes: *std.ArrayList(u8)) !void {
    // Mostly one edit, which keeps more files parsing.
    const edits = if (random.boolean()) 1 else 1 + random.uintLessThan(usize, 8);
    for (0..edits) |_| {
        const len = bytes.items.len;
        const at = if (len == 0) 0 else random.uintLessThan(usize, len);
        switch (random.uintLessThan(u8, 9)) {
            0 => if (len > 0) {
                bytes.items[at] ^= @as(u8, 1) << random.int(u3);
            },
            1 => if (len > 0) {
                bytes.items[at] = random.int(u8);
            },
            2 => {
                const word = corpus.dictionary.items[random.uintLessThan(usize, corpus.dictionary.items.len)];
                try bytes.insertSlice(gpa, at, word);
            },
            3 => if (len > 0) {
                const n = @min(len - at, 1 + random.uintLessThan(usize, 16));
                bytes.replaceRangeAssumeCapacity(at, n, &.{});
            },
            4 => if (len > 0) {
                const n = @min(len - at, 1 + random.uintLessThan(usize, 32));
                const copy = try gpa.dupe(u8, bytes.items[at..][0..n]);
                defer gpa.free(copy);
                try bytes.insertSlice(gpa, random.uintLessThan(usize, len), copy);
            },
            5 => if (len > 0) bytes.shrinkRetainingCapacity(at),
            // A digit or sign where one was: numbers and indices change.
            6 => if (len > 0) {
                bytes.items[at] = "0123456789-+.eE"[random.uintLessThan(usize, 15)];
            },
            // A 32-bit word of a GLB header or chunk header.
            7 => if (len >= 28) {
                const offsets = [_]usize{ 4, 8, 12, 16 };
                const offset = offsets[random.uintLessThan(usize, offsets.len)];
                const value: u32 = switch (random.uintLessThan(u8, 3)) {
                    0 => random.int(u32),
                    1 => std.mem.readInt(u32, bytes.items[offset..][0..4], .little) +% random.intRangeAtMost(u32, 0, 8) -% 4,
                    else => 0,
                };
                std.mem.writeInt(u32, bytes.items[offset..][0..4], value, .little);
            },
            else => try bytes.insert(gpa, at, random.int(u8)),
        }
    }
}

test "fuzz: mutated sample models, GLB containers and upstream's corpus give the original's results" {
    const gpa = testing.allocator;
    const io = testing.io;
    var corpus = try loadCorpus(gpa, io);
    defer corpus.deinit(gpa);
    try testing.expect(corpus.seeds.items.len > 50);
    const Context = struct {
        var current: *const Corpus = undefined;
        var tally: oracle.Tally = .{};
    };
    Context.current = &corpus;
    Context.tally = .{};
    try fuzz.run("mutations", 3000, struct {
        fn case(random: std.Random) !void {
            const c = Context.current;
            const seed = c.seeds.items[random.uintLessThan(usize, c.seeds.items.len)];
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(testing.allocator);
            try bytes.appendSlice(testing.allocator, seed.bytes);
            try mutate(testing.allocator, random, c, &bytes);
            const options: oracle.Options = .{
                .file_type = switch (random.uintLessThan(u8, 8)) {
                    0 => .gltf,
                    1 => .glb,
                    else => .invalid,
                },
                .json_token_count = if (random.uintLessThan(u8, 8) == 0) random.uintLessThan(usize, 200) else 0,
            };
            Context.tally.add(try oracle.expectSame(testing.allocator, testing.io, .{ .bytes = .{
                .data = bytes.items,
                .gltf_path = seed.path,
            } }, options));
        }
    }.case);
    if (test_options.fuzz_replay == null) try Context.tally.expectReach("mutations", 300);
}

/// A random glTF document written as JSON. A strict document keeps to
/// the glTF rules, so it gets through validation and into the accessor
/// helpers; a wild one breaks them now and then, anywhere.
const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: Allocator,
    random: std.Random,
    strict: bool,
    /// How many of each object the document has, for references.
    counts: Counts = .{},
    /// Each view's stride, 0 for none, and each accessor's count.
    view_strides: [max_objects]u32 = @splat(0),
    accessor_counts: [max_objects]u32 = @splat(0),
    /// The next node without a parent, in a strict document's tree.
    next_child: u32 = 1,

    const max_objects = 8;
    const view_length = 64;
    const buffer_length = 96;

    const Counts = struct {
        buffers: u32 = 0,
        views: u32 = 0,
        accessors: u32 = 0,
        meshes: u32 = 0,
        materials: u32 = 0,
        textures: u32 = 0,
        images: u32 = 0,
        samplers: u32 = 0,
        nodes: u32 = 0,
        scenes: u32 = 0,
        skins: u32 = 0,
        cameras: u32 = 0,
        lights: u32 = 0,
        variants: u32 = 0,
    };

    fn print(w: *Writer, comptime format: []const u8, args: anytype) !void {
        try w.out.print(w.gpa, format, args);
    }

    fn chance(w: *Writer, n: u32) bool {
        return w.random.uintLessThan(u32, n) == 0;
    }

    /// A rule broken, one time in `n`, in a wild document only.
    fn wild(w: *Writer, n: u32) bool {
        return !w.strict and w.chance(n);
    }

    fn pick(w: *Writer, comptime T: type, items: []const T) T {
        return items[w.random.uintLessThan(usize, items.len)];
    }

    /// An index into an array of `count`: in a strict document always in
    /// range, or -1, none, when the array is empty.
    fn ref(w: *Writer, count: u32) !void {
        if (w.wild(25)) return w.print("{s}", .{w.pick([]const u8, &.{ "-1", "-2", "4294967296", "1.5", "\"0\"", "null" })});
        if (w.wild(30)) return w.print("{d}", .{w.random.uintLessThan(u32, count + 2)});
        if (count == 0) return w.print("-1", .{});
        try w.print("{d}", .{w.random.uintLessThan(u32, count)});
    }

    fn float(w: *Writer) !void {
        if (w.wild(5)) {
            if (w.chance(2)) return w.print("{e}", .{@as(f32, @bitCast(w.random.int(u32)))});
            return w.print("{s}", .{w.pick([]const u8, &.{ "1e39", "-0", "nan", "0x10", "1e-45", "-1e400", "3.4028235e38" })});
        }
        if (w.chance(5)) return w.print("{d}", .{w.random.intRangeAtMost(i32, -3, 3)});
        try w.print("{d}", .{w.random.float(f32) * 4 - 2});
    }

    fn floats(w: *Writer, n: usize) !void {
        const count = if (w.wild(20)) w.random.uintLessThan(usize, n + 2) else n;
        try w.print("[", .{});
        for (0..count) |i| {
            if (i > 0) try w.print(",", .{});
            try w.float();
        }
        try w.print("]", .{});
    }

    fn size(w: *Writer, max: u32) !void {
        if (w.wild(40)) return w.print("{d}", .{w.random.int(u64)});
        try w.print("{d}", .{w.random.uintLessThan(u32, max)});
    }

    fn extras(w: *Writer) !void {
        if (!w.chance(4)) return;
        try w.print(",\"extras\":{s}", .{w.pick([]const u8, &.{ "{\"a\":1}", "\"s\"", "[1,[2]]", "7", "{\"targetNames\":[\"x\"]}", "null" })});
    }

    fn unknownExtension(w: *Writer) !void {
        if (!w.chance(6)) return;
        try w.print(",\"extensions\":{{\"VENDOR_{d}\":{{\"k\":[{d}]}}}}", .{ w.random.int(u4), w.random.int(u8) });
    }

    fn textureView(w: *Writer, name: []const u8) !void {
        if (w.strict and w.counts.textures == 0) return;
        try w.print(",\"{s}\":{{\"index\":", .{name});
        try w.ref(w.counts.textures);
        if (w.chance(2)) try w.print(",\"texCoord\":{d}", .{w.random.uintLessThan(u8, 3)});
        if (w.chance(3)) {
            try w.print(",\"scale\":", .{});
            try w.float();
        }
        if (w.chance(3)) {
            try w.print(",\"extensions\":{{\"KHR_texture_transform\":{{\"offset\":", .{});
            try w.floats(2);
            try w.print(",\"rotation\":", .{});
            try w.float();
            try w.print(",\"scale\":", .{});
            try w.floats(2);
            if (w.chance(2)) try w.print(",\"texCoord\":1", .{});
            try w.print("}}}}", .{});
        }
        try w.print("}}", .{});
    }

    /// Attributes all of one accessor in a strict document, whose counts
    /// must agree.
    fn attributes(w: *Writer) !void {
        const names = [_][]const u8{ "POSITION", "NORMAL", "TANGENT", "TEXCOORD_0", "TEXCOORD_1", "COLOR_0", "JOINTS_0", "WEIGHTS_0", "_CUSTOM", "X_1" };
        const n = if (w.strict) 1 + w.random.uintLessThan(usize, 3) else w.random.uintLessThan(usize, 4);
        const shared = w.random.uintLessThan(u32, @max(w.counts.accessors, 1));
        try w.print("{{", .{});
        for (0..n) |i| {
            if (i > 0) try w.print(",", .{});
            try w.print("\"{s}\":", .{w.pick([]const u8, &names)});
            if (w.strict) try w.print("{d}", .{shared}) else try w.ref(w.counts.accessors);
        }
        try w.print("}}", .{});
    }

    fn material(w: *Writer) !void {
        try w.print("{{\"name\":\"m\"", .{});
        if (w.chance(2)) {
            try w.print(",\"pbrMetallicRoughness\":{{\"baseColorFactor\":", .{});
            try w.floats(4);
            try w.print(",\"metallicFactor\":", .{});
            try w.float();
            try w.textureView("baseColorTexture");
            try w.print("}}", .{});
        }
        if (w.chance(3)) try w.textureView("normalTexture");
        if (w.chance(3)) try w.textureView("occlusionTexture");
        if (w.chance(3)) try w.print(",\"alphaMode\":\"{s}\"", .{w.pick([]const u8, &.{ "OPAQUE", "MASK", "BLEND", "X" })});
        if (w.chance(2)) {
            const extensions = [_][]const u8{
                "\"KHR_materials_unlit\":{}",
                "\"KHR_materials_ior\":{\"ior\":1.2}",
                "\"KHR_materials_clearcoat\":{\"clearcoatFactor\":0.5}",
                "\"KHR_materials_specular\":{\"specularColorFactor\":[1,0,1]}",
                "\"KHR_materials_transmission\":{\"transmissionFactor\":0.2}",
                "\"KHR_materials_volume\":{\"attenuationColor\":[1,1,0]}",
                "\"KHR_materials_sheen\":{\"sheenRoughnessFactor\":0.3}",
                "\"KHR_materials_emissive_strength\":{}",
                "\"KHR_materials_iridescence\":{\"iridescenceThicknessMaximum\":9}",
                "\"KHR_materials_diffuse_transmission\":{\"diffuseTransmissionFactor\":0.5}",
                "\"KHR_materials_anisotropy\":{\"anisotropyStrength\":2}",
                "\"KHR_materials_dispersion\":{\"dispersion\":1}",
                "\"KHR_materials_pbrSpecularGlossiness\":{\"glossinessFactor\":0.1}",
                "\"VENDOR_m\":{}",
            };
            try w.print(",\"extensions\":{{{s}", .{w.pick([]const u8, &extensions)});
            if (w.chance(2)) try w.print(",{s}", .{w.pick([]const u8, &extensions)});
            if (w.wild(10)) try w.print(",\"KHR_materials_ior\":[]", .{});
            try w.print("}}", .{});
        }
        try w.extras();
        try w.print("}}", .{});
    }

    const Layout = struct { type: []const u8, component: u32, size: u32 };
    /// Every type with every component type, and its element size.
    const layouts = blk: {
        const types = [_]struct { []const u8, u32 }{ .{ "SCALAR", 1 }, .{ "VEC2", 2 }, .{ "VEC3", 3 }, .{ "VEC4", 4 }, .{ "MAT2", 4 }, .{ "MAT3", 9 }, .{ "MAT4", 16 } };
        const components = [_]struct { u32, u32 }{ .{ 5120, 1 }, .{ 5121, 1 }, .{ 5122, 2 }, .{ 5123, 2 }, .{ 5125, 4 }, .{ 5126, 4 } };
        var all: [types.len * components.len]Layout = undefined;
        for (types, 0..) |t, i| for (components, 0..) |ct, j| {
            var element = t[1] * ct[1];
            if (std.mem.eql(u8, t[0], "MAT2") and ct[1] == 1) element = 8;
            if (std.mem.eql(u8, t[0], "MAT3") and ct[1] <= 2) element = 12 * ct[1];
            all[i * components.len + j] = .{ .type = t[0], .component = ct[0], .size = element };
        };
        break :blk all;
    };

    fn accessor(w: *Writer, index: usize) !void {
        var layout = w.pick(Layout, &layouts);
        if (w.wild(10)) layout.component = 5124;
        const view = w.random.uintLessThan(u32, @max(w.counts.views, 1));
        // A strict accessor fits its view: offset + stride * (count - 1)
        // + element size.
        const stride = if (w.view_strides[view] != 0) w.view_strides[view] else layout.size;
        if (w.strict and layout.size > view_length) layout = layouts[0];
        const fits = (view_length - layout.size) / @max(stride, 1) + 1;
        const count: u32 = if (w.strict) 1 + w.random.uintLessThan(u32, @min(fits, 24)) else w.random.uintLessThan(u32, 24);
        w.accessor_counts[index] = count;
        try w.print("{{\"componentType\":{d},\"type\":\"{s}\",\"count\":", .{ layout.component, layout.type });
        if (w.wild(40)) try w.size(1000) else try w.print("{d}", .{count});
        if (w.strict or !w.chance(5)) {
            try w.print(",\"bufferView\":", .{});
            if (w.strict) try w.print("{d}", .{view}) else try w.ref(w.counts.views);
        }
        if (!w.strict and w.chance(3)) {
            try w.print(",\"byteOffset\":", .{});
            try w.size(16);
        }
        if (w.chance(3)) try w.print(",\"normalized\":true", .{});
        if (w.chance(3)) {
            try w.print(",\"min\":", .{});
            try w.floats(3);
        }
        if (w.chance(4)) {
            const index_type = if (w.strict) w.pick(u32, &.{ 5121, 5123, 5125 }) else w.pick(u32, &.{ 5121, 5123, 5125, 5126 });
            try w.print(",\"sparse\":{{\"count\":", .{});
            if (w.strict) try w.print("{d}", .{1 + w.random.uintLessThan(u32, 3)}) else try w.size(6);
            try w.print(",\"indices\":{{\"bufferView\":", .{});
            try w.ref(@max(w.counts.views, 1));
            try w.print(",\"byteOffset\":", .{});
            try w.size(8);
            try w.print(",\"componentType\":{d}}},\"values\":{{\"bufferView\":", .{index_type});
            try w.ref(@max(w.counts.views, 1));
            try w.print("}}}}", .{});
        }
        try w.extras();
        try w.unknownExtension();
        try w.print("}}", .{});
    }

    fn node(w: *Writer, index: usize) !void {
        try w.print("{{\"name\":\"n\"", .{});
        if (w.chance(2)) {
            try w.print(",\"children\":[", .{});
            const n = w.random.uintLessThan(usize, 3);
            var written: usize = 0;
            for (0..n) |_| {
                if (w.strict) {
                    // Children come after their parent, each once: a tree.
                    if (w.next_child >= w.counts.nodes or w.next_child <= index) break;
                    if (written > 0) try w.print(",", .{});
                    try w.print("{d}", .{w.next_child});
                    w.next_child += 1;
                } else {
                    if (written > 0) try w.print(",", .{});
                    try w.ref(w.counts.nodes);
                }
                written += 1;
            }
            try w.print("]", .{});
        }
        const has_mesh = w.chance(2) and (!w.strict or w.counts.meshes > 0);
        if (has_mesh) {
            try w.print(",\"mesh\":", .{});
            try w.ref(w.counts.meshes);
        }
        if (w.chance(5)) {
            try w.print(",\"skin\":", .{});
            try w.ref(w.counts.skins);
        }
        if (w.chance(5)) {
            try w.print(",\"camera\":", .{});
            try w.ref(w.counts.cameras);
        }
        if (w.chance(3)) {
            try w.print(",\"matrix\":", .{});
            try w.floats(16);
        } else {
            if (w.chance(2)) {
                try w.print(",\"translation\":", .{});
                try w.floats(3);
            }
            if (w.chance(2)) {
                try w.print(",\"rotation\":", .{});
                try w.floats(4);
            }
            if (w.chance(2)) {
                try w.print(",\"scale\":", .{});
                try w.floats(3);
            }
        }
        if (w.wild(4)) {
            try w.print(",\"weights\":", .{});
            try w.floats(w.random.uintLessThan(usize, 3));
        }
        if (w.chance(4)) {
            try w.print(",\"extensions\":{{\"KHR_lights_punctual\":{{\"light\":", .{});
            try w.ref(w.counts.lights);
            try w.print("}}", .{});
            if (w.chance(2) and (has_mesh or !w.strict)) {
                try w.print(",\"EXT_mesh_gpu_instancing\":{{\"attributes\":", .{});
                try w.attributes();
                try w.print("}}", .{});
            }
            try w.print("}}", .{});
        }
        try w.extras();
        try w.print("}}", .{});
    }

    fn array(w: *Writer, comptime key: []const u8, count: u32, comptime item: fn (*Writer, usize) anyerror!void) !void {
        try w.print(",\"" ++ key ++ "\":[", .{});
        for (0..count) |i| {
            if (i > 0) try w.print(",", .{});
            try item(w, i);
        }
        try w.print("]", .{});
    }

    fn buffer(w: *Writer, _: usize) !void {
        var bytes: [buffer_length]u8 = undefined;
        w.random.bytes(&bytes);
        const encoder = std.base64.standard.Encoder;
        var text: [encoder.calcSize(bytes.len)]u8 = undefined;
        const encoded = encoder.encode(&text, &bytes);
        const cut = if (w.wild(10)) w.random.uintLessThan(usize, encoded.len) else encoded.len;
        try w.print("{{\"byteLength\":", .{});
        if (w.strict) try w.print("{d}", .{buffer_length}) else try w.size(100);
        try w.print(",\"uri\":\"data:application/octet-stream;base64,{s}\"}}", .{encoded[0..cut]});
    }

    fn bufferView(w: *Writer, index: usize) !void {
        try w.print("{{\"buffer\":", .{});
        try w.ref(w.counts.buffers);
        try w.print(",\"byteOffset\":", .{});
        if (w.strict) try w.print("{d}", .{4 * w.random.uintLessThan(u32, 9)}) else try w.size(48);
        try w.print(",\"byteLength\":", .{});
        if (w.strict) try w.print("{d}", .{view_length}) else try w.size(64);
        if (w.chance(3)) {
            const stride = w.pick(u32, &.{ 4, 8, 16, 32, 64 });
            w.view_strides[index] = stride;
            try w.print(",\"byteStride\":", .{});
            if (w.strict) try w.print("{d}", .{stride}) else try w.size(20);
        }
        if (w.wild(8)) {
            try w.print(",\"extensions\":{{\"EXT_meshopt_compression\":{{\"buffer\":0,\"byteLength\":8,\"byteStride\":{d},\"count\":{d},\"mode\":\"{s}\",\"filter\":\"{s}\"}}}}", .{
                w.random.uintLessThan(u8, 9),
                w.random.uintLessThan(u8, 9),
                w.pick([]const u8, &.{ "ATTRIBUTES", "TRIANGLES", "INDICES", "X" }),
                w.pick([]const u8, &.{ "NONE", "OCTAHEDRAL", "QUATERNION", "EXPONENTIAL", "COLOR" }),
            });
        }
        try w.print("}}", .{});
    }

    fn image(w: *Writer, _: usize) !void {
        try w.print("{{\"bufferView\":", .{});
        try w.ref(w.counts.views);
        try w.print(",\"mimeType\":\"image/png\"}}", .{});
    }

    fn sampler(w: *Writer, _: usize) !void {
        try w.print("{{\"magFilter\":{d},\"wrapS\":{d}}}", .{ w.random.int(i16), w.random.int(i16) });
    }

    fn texture(w: *Writer, _: usize) !void {
        try w.print("{{\"source\":", .{});
        try w.ref(w.counts.images);
        try w.print(",\"sampler\":", .{});
        try w.ref(w.counts.samplers);
        if (w.chance(3)) {
            try w.print(",\"extensions\":{{\"KHR_texture_basisu\":{{\"source\":", .{});
            try w.ref(w.counts.images);
            try w.print("}},\"EXT_texture_webp\":{{\"source\":", .{});
            try w.ref(w.counts.images);
            try w.print("}}}}", .{});
        }
        try w.print("}}", .{});
    }

    fn mesh(w: *Writer, _: usize) !void {
        try w.print("{{\"primitives\":[", .{});
        const n = if (w.strict) 1 + w.random.uintLessThan(usize, 2) else w.random.uintLessThan(usize, 3);
        for (0..n) |i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"attributes\":", .{});
            try w.attributes();
            if (w.wild(2)) {
                try w.print(",\"indices\":", .{});
                try w.ref(w.counts.accessors);
            }
            if (w.chance(2)) {
                try w.print(",\"material\":", .{});
                try w.ref(w.counts.materials);
            }
            if (w.chance(3)) {
                const mode = if (w.strict) w.random.intRangeAtMost(i8, 0, 6) else w.random.intRangeAtMost(i8, -1, 7);
                try w.print(",\"mode\":{d}", .{mode});
            }
            if (w.wild(4)) {
                try w.print(",\"targets\":[", .{});
                try w.attributes();
                try w.print("]", .{});
            }
            if (w.chance(5) and (!w.strict or w.counts.variants > 0)) {
                try w.print(",\"extensions\":{{\"KHR_materials_variants\":{{\"mappings\":[{{\"material\":", .{});
                try w.print("{d}", .{if (w.strict) w.random.uintLessThan(u32, @max(w.counts.materials, 1)) else w.random.uintLessThan(u32, 4)});
                try w.print(",\"variants\":[", .{});
                try w.ref(w.counts.variants);
                try w.print("]}}]}},\"KHR_draco_mesh_compression\":{{\"bufferView\":", .{});
                try w.ref(@max(w.counts.views, 1));
                try w.print(",\"attributes\":", .{});
                try w.attributes();
                try w.print("}}}}", .{});
            }
            try w.extras();
            try w.print("}}", .{});
        }
        try w.print("]", .{});
        if (w.wild(3)) {
            try w.print(",\"weights\":", .{});
            try w.floats(w.random.uintLessThan(usize, 2));
        }
        try w.extras();
        try w.print("}}", .{});
    }

    fn scene(w: *Writer, _: usize) !void {
        if (w.strict) return w.print("{{\"nodes\":[0]}}", .{});
        try w.print("{{\"nodes\":[", .{});
        const n = w.random.uintLessThan(usize, 3);
        for (0..n) |i| {
            if (i > 0) try w.print(",", .{});
            try w.ref(w.counts.nodes);
        }
        try w.print("]}}", .{});
    }

    fn skin(w: *Writer, _: usize) !void {
        try w.print("{{\"joints\":[", .{});
        try w.ref(@max(w.counts.nodes, 1));
        try w.print("],\"skeleton\":", .{});
        try w.ref(w.counts.nodes);
        try w.print(",\"inverseBindMatrices\":", .{});
        try w.ref(w.counts.accessors);
        try w.print("}}", .{});
    }

    fn camera(w: *Writer, _: usize) !void {
        if (w.chance(2)) {
            try w.print("{{\"perspective\":{{\"yfov\":", .{});
            try w.float();
            try w.print(",\"znear\":0.1}}}}", .{});
        } else {
            try w.print("{{\"orthographic\":{{\"xmag\":1,\"ymag\":", .{});
            try w.float();
            try w.print("}}}}", .{});
        }
    }

    fn animation(w: *Writer) !void {
        // A strict channel's input and output are one accessor, whose
        // counts then agree.
        const input = w.random.uintLessThan(u32, w.counts.accessors);
        try w.print(",\"animations\":[{{\"samplers\":[{{\"input\":{d},\"output\":", .{input});
        if (w.strict) try w.print("{d}", .{input}) else try w.ref(w.counts.accessors);
        const interpolations: []const []const u8 = if (w.strict) &.{ "LINEAR", "STEP" } else &.{ "LINEAR", "STEP", "CUBICSPLINE" };
        try w.print(",\"interpolation\":\"{s}\"}}],\"channels\":[{{\"sampler\":", .{w.pick([]const u8, interpolations)});
        try w.ref(1);
        const paths: []const []const u8 = if (w.strict) &.{ "translation", "rotation", "scale" } else &.{ "translation", "rotation", "scale", "weights" };
        try w.print(",\"target\":{{\"node\":", .{});
        try w.ref(w.counts.nodes);
        try w.print(",\"path\":\"{s}\"}}}}]}}]", .{w.pick([]const u8, paths)});
    }

    fn document(w: *Writer) !void {
        const r = w.random;
        const at_least: u32 = if (w.strict) 1 else 0;
        w.counts = .{
            .buffers = @max(at_least, r.uintLessThan(u32, 3)),
            .views = @max(at_least, r.uintLessThan(u32, 5)),
            .accessors = @max(at_least, r.uintLessThan(u32, 7)),
            .meshes = r.uintLessThan(u32, 3),
            .materials = r.uintLessThan(u32, 4),
            .textures = r.uintLessThan(u32, 3),
            .images = r.uintLessThan(u32, 3),
            .samplers = r.uintLessThan(u32, 2),
            .nodes = @max(at_least, r.uintLessThan(u32, 6)),
            .scenes = r.uintLessThan(u32, 3),
            .skins = r.uintLessThan(u32, 2),
            .cameras = r.uintLessThan(u32, 3),
            .lights = r.uintLessThan(u32, 3),
            .variants = r.uintLessThan(u32, 3),
        };
        const version = if (w.wild(10)) w.pick([]const u8, &.{ "1.0", "2.1", "x" }) else "2.0";
        try w.print("{{\"asset\":{{\"version\":\"{s}\"", .{version});
        try w.extras();
        try w.print("}}", .{});
        try w.array("buffers", w.counts.buffers, buffer);
        try w.array("bufferViews", w.counts.views, bufferView);
        try w.array("accessors", w.counts.accessors, accessor);
        try w.array("materials", w.counts.materials, struct {
            fn item(x: *Writer, _: usize) !void {
                try x.material();
            }
        }.item);
        try w.array("images", w.counts.images, image);
        try w.array("samplers", w.counts.samplers, sampler);
        try w.array("textures", w.counts.textures, texture);
        try w.array("meshes", w.counts.meshes, mesh);
        try w.array("nodes", w.counts.nodes, node);
        try w.array("scenes", w.counts.scenes, scene);
        if (w.chance(2)) {
            try w.print(",\"scene\":", .{});
            try w.ref(w.counts.scenes);
        }
        try w.array("skins", w.counts.skins, skin);
        try w.array("cameras", w.counts.cameras, camera);
        if (w.counts.accessors > 0 and w.chance(2)) try w.animation();
        try w.print(",\"extensions\":{{\"KHR_lights_punctual\":{{\"lights\":[", .{});
        for (0..w.counts.lights) |i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"type\":\"{s}\",\"intensity\":", .{w.pick([]const u8, &.{ "point", "spot", "directional" })});
            try w.float();
            try w.print(",\"spot\":{{\"outerConeAngle\":0.3}}}}", .{});
        }
        try w.print("]}},\"KHR_materials_variants\":{{\"variants\":[", .{});
        for (0..w.counts.variants) |i| {
            if (i > 0) try w.print(",", .{});
            if (w.wild(6)) try w.print("{{}}", .{}) else try w.print("{{\"name\":\"v{d}\"}}", .{i});
        }
        try w.print("]}}}}", .{});
        try w.extras();
        try w.print("}}", .{});
    }
};

test "fuzz: random glTF documents give the original's results" {
    const Context = struct {
        var tally: oracle.Tally = .{};
    };
    Context.tally = .{};
    try fuzz.run("documents", 4000, struct {
        fn case(random: std.Random) !void {
            var w: Writer = .{ .gpa = testing.allocator, .random = random, .strict = random.boolean() };
            defer w.out.deinit(testing.allocator);
            try w.document();
            const source: oracle.Source = .{ .bytes = .{ .data = w.out.items } };
            Context.tally.add(try oracle.expectSame(testing.allocator, testing.io, source, .{}));
        }
    }.case);
    if (test_options.fuzz_replay == null) try Context.tally.expectReach("documents", 600);
}
