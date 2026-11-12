//! Hand-made inputs through both: the GLB container's every check, glTF
//! 1.0, broken and odd JSON, numbers in every form C reads, references
//! out of range, every extension, and accessors of every type, component
//! type, matrix padding, sparse layout and normalization.

const std = @import("std");
const cgltf = @import("cgltf");
const oracle = @import("oracle.zig");
const samples = @import("samples.zig");

const testing = std.testing;

/// A 256-byte buffer, byte i holding i * 37 + 11: every value appears, in
/// an order no index or float pattern repeats.
const buffer_bytes = blk: {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    break :blk bytes;
};

/// A glTF with `fragment` after the asset, where `@B` stands for a data
/// URI of `buffer_bytes`.
fn document(gpa: std.mem.Allocator, fragment: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    var uri: [encoder.calcSize(buffer_bytes.len)]u8 = undefined;
    _ = encoder.encode(&uri, &buffer_bytes);
    const with_uri = try std.mem.replaceOwned(u8, gpa, fragment, "@B", "data:application/octet-stream;base64," ++ uri);
    defer gpa.free(with_uri);
    return std.mem.concat(gpa, u8, &.{ "{\"asset\":{\"version\":\"2.0\"}", with_uri, "}" });
}

fn expectSameJson(fragment: []const u8) !void {
    const gpa = testing.allocator;
    const json = try document(gpa, fragment);
    defer gpa.free(json);
    _ = oracle.expectSame(gpa, testing.io, .{ .bytes = .{ .data = json } }, .{}) catch |err| {
        std.debug.print("case: {s}\n", .{fragment});
        return err;
    };
}

fn expectSameRaw(bytes: []const u8, options: oracle.Options) !void {
    _ = oracle.expectSame(testing.allocator, testing.io, .{ .bytes = .{ .data = bytes } }, options) catch |err| {
        std.debug.print("case: {x}\n", .{bytes});
        return err;
    };
}

/// A GLB from its parts: header fields and chunks exactly as given.
fn glb(gpa: std.mem.Allocator, version: u32, total: ?u32, chunks: []const struct { u32, u32, []const u8 }) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "glTF");
    try out.appendSlice(gpa, &std.mem.toBytes(version));
    try out.appendSlice(gpa, &std.mem.toBytes(@as(u32, 0)));
    for (chunks) |chunk| {
        try out.appendSlice(gpa, &std.mem.toBytes(chunk[0]));
        try out.appendSlice(gpa, &std.mem.toBytes(chunk[1]));
        try out.appendSlice(gpa, chunk[2]);
    }
    const length: u32 = total orelse @intCast(out.items.len);
    @memcpy(out.items[8..12], &std.mem.toBytes(length));
    return out.toOwnedSlice(gpa);
}

const json_magic: u32 = 0x4E4F534A;
const bin_magic: u32 = 0x004E4942;

test "edges: the GLB container's checks give the original's results" {
    const gpa = testing.allocator;
    const json = "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":8}]}";
    const bin = "01234567abc";
    const cases = [_]struct { u32, ?u32, []const struct { u32, u32, []const u8 } }{
        .{ 2, null, &.{.{ json.len, json_magic, json }} },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 8, bin_magic, bin[0..8] } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 11, bin_magic, bin } } },
        // A BIN chunk shorter than the buffer.
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 4, bin_magic, bin[0..4] } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 12, bin_magic, bin } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 8, 0x12345678, bin[0..8] } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 8, bin_magic, "" } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 0, bin_magic, "" } } },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 1, bin_magic, "" } } },
        .{ 2, null, &.{.{ json.len + 1, json_magic, json }} },
        .{ 2, null, &.{.{ json.len - 1, json_magic, json }} },
        .{ 2, null, &.{.{ json.len, 0x4E4F534B, json }} },
        .{ 2, null, &.{.{ 0, json_magic, "" }} },
        .{ 2, null, &.{} },
        .{ 2, 1000, &.{.{ json.len, json_magic, json }} },
        .{ 2, 0, &.{.{ json.len, json_magic, json }} },
        .{ 1, null, &.{.{ json.len, json_magic, json }} },
        .{ 0, null, &.{.{ json.len, json_magic, json }} },
        .{ 3, null, &.{.{ json.len, json_magic, json }} },
        .{ 0xFFFFFFFF, null, &.{.{ json.len, json_magic, json }} },
        .{ 2, null, &.{.{ 0xFFFFFFFF, json_magic, json }} },
        .{ 2, null, &.{ .{ json.len, json_magic, json }, .{ 0xFFFFFFFF, bin_magic, bin } } },
    };
    for (cases) |case| {
        const bytes = try glb(gpa, case[0], case[1], case[2]);
        defer gpa.free(bytes);
        for ([_]cgltf.FileType{ .invalid, .gltf, .glb }) |file_type| {
            try expectSameRaw(bytes, .{ .file_type = file_type });
        }
        // Every prefix: the checks of a cut file.
        for (0..bytes.len) |n| try expectSameRaw(bytes[0..n], .{});
    }
}

test "edges: forced file types, short input and token counts give the original's results" {
    const json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{},{}]}";
    for ([_]cgltf.FileType{ .invalid, .gltf, .glb }) |file_type| {
        try expectSameRaw(json, .{ .file_type = file_type });
        for (0..14) |tokens| try expectSameRaw(json, .{ .file_type = file_type, .json_token_count = tokens });
    }
    for ([_][]const u8{ "", "{", "{}", "{}         ", "{}          ", "glTF", "glTF\x02\x00\x00\x00\x0c\x00\x00" }) |bytes| {
        try expectSameRaw(bytes, .{});
    }
}

test "edges: JSON the tokenizer and the parser refuse, and glTF 1.0" {
    const cases = [_][]const u8{
        "{\"asset\":{\"version\":\"1.0\"}}",
        "{\"asset\":{\"version\":\"1.99\"}}",
        "{\"asset\":{\"version\":\" 2\"}}",
        "{\"asset\":{\"version\":\"x\"}}",
        "{\"asset\":{\"version\":\"0x2\"}}",
        "{\"asset\":{\"version\":\"inf\"}}",
        "{\"asset\":{\"version\":\"nan\"}}",
        "{\"asset\":{\"version\":2}}",
        "{\"asset\":[]}",
        "{\"meshes\":{}}",
        "{\"nodes\":{\"a\":{}}}",
        "{\"meshes\":[],\"meshes\":[]}",
        "{\"asset\":{\"version\":\"2.0\",\"version\":\"2.0\"}}",
        "[]",
        "[1,2]",
        "\"x\"           ",
        "{\"a\":}",
        "{\"a\" 1}",
        "{\"a\":1,}",
        "{\"a\":[1,]}",
        "{\"a\":[1 2]}",
        "{\"a\":{\"b\"}}",
        "{\"a\":\"\\q\"}",
        "{\"a\":\"\\u12\"}",
        "{\"a\":\"\\u12g4\"}",
        "{\"a\":\"\x01\"}",
        "{\"a\":tru}         ",
        "{\"a\":1}x",
        "{\"a\":1}\x00garbage after a NUL",
        "{\"a\":1\x00}",
        "{\"asset\":{\"version\":\"2.0\"}}}",
        "{\"asset\":{\"version\":\"2.0\"}]",
        "{\"asset\":{\"version\":\"2.0\"",
        "{{}}        ",
        "{\"a\":[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]}",
        "{\"nodes\":[1]}",
        "{\"nodes\":[\"x\"]}",
        "{\"nodes\":[{\"name\":1}]}",
        "{\"nodes\":[{\"name\":\"a\",\"name\":\"b\"}]}",
        "{\"nodes\":[{\"translation\":[1,2]}]}",
        "{\"nodes\":[{\"translation\":[1,2,3,4]}]}",
        "{\"nodes\":[{\"translation\":[1,\"2\",3]}]}",
        "{\"nodes\":[{\"matrix\":5}]}",
        "{\"nodes\":[{\"children\":[0]}]}",
        "{\"nodes\":[{\"children\":[1]},{\"children\":[0]}]}",
        "{\"nodes\":[{\"children\":[1]},{}, {\"children\":[1]}]}",
        "{\"nodes\":[{\"children\":[1]},{}],\"scenes\":[{\"nodes\":[1]}]}",
        "{\"nodes\":[{\"children\":[2]}]}",
        "{\"nodes\":[{\"children\":[-1]}]}",
        "{\"nodes\":[{\"mesh\":-1}]}",
        "{\"nodes\":[{\"mesh\":-2}]}",
        "{\"nodes\":[{\"mesh\":0}]}",
        "{\"nodes\":[{\"mesh\":\"0\"}]}",
        "{\"nodes\":[{\"mesh\":[0]}]}",
        "{\"nodes\":[{\"camera\":{}}]}",
        "{\"scene\":0}",
        "{\"scene\":-1,\"scenes\":[{}]}",
        "{\"scene\":4294967296,\"scenes\":[{}]}",
        "{\"scene\":\"0\",\"scenes\":[{}]}",
        "{\"extensionsUsed\":[\"A\",1]}",
        "{\"extensionsUsed\":[\"A\"],\"extensionsUsed\":[\"B\"]}",
        "{\"extensionsRequired\":{}}",
        "{\"extensions\":[]}",
        "{\"extensions\":{\"X\":1}}",
        "{\"extensions\":{\"X\":{}},\"extensions\":{}}",
        "{\"nodes\":[{\"extensions\":{\"X\":[]}}]}",
        "{\"extras\":1,\"extras\":2}",
        "{\"cameras\":[{\"perspective\":{},\"orthographic\":{}}]}",
        "{\"cameras\":[{\"perspective\":{},\"perspective\":{}}]}",
        "{\"cameras\":[{\"perspective\":1}]}",
        "{\"meshes\":[{\"primitives\":[{\"attributes\":[]}]}]}",
        "{\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0}}]}]}",
        "{\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":\"x\"}}]}],\"accessors\":[{}]}",
        "{\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"POSITION\":0}}]}],\"accessors\":[{}]}",
        "{\"meshes\":[{\"primitives\":[{\"attributes\":{},\"attributes\":{}}]}]}",
        "{\"meshes\":[{\"weights\":[1],\"weights\":[1]}]}",
        "{\"meshes\":[{\"extras\":{\"targetNames\":[\"a\"],\"targetNames\":[\"b\"]}}]}",
        "{\"meshes\":[{\"extras\":{\"targetNames\":[1]}}]}",
        "{\"meshes\":[{\"extras\":{\"targetNames\":\"a\"}}]}",
        "{\"meshes\":[{\"extras\":[1,2]}]}",
        "{\"meshes\":[{\"extras\":{\"a\":}}]}",
        "{\"accessors\":[{\"min\":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]}]}",
        "{\"accessors\":[{\"min\":[1,\"a\"]}]}",
        "{\"accessors\":[{\"sparse\":{\"count\":1}}]}",
        "{\"accessors\":[{\"sparse\":{\"indices\":[],\"values\":{}}}]}",
        "{\"animations\":[{\"channels\":[{\"sampler\":0}]}]}",
        "{\"animations\":[{\"samplers\":[{}]}]}",
        "{\"animations\":[{\"channels\":[{\"target\":[]}]}]}",
    };
    for (cases) |case| try expectSameRaw(case, .{});
}

test "edges: numbers read as C reads them" {
    const numbers = [_][]const u8{
        "0",     "-0",       "1",         "-1",         "2147483647",     "2147483648",
        "4294967295",        "4294967296", "-2147483649", "9223372036854775807", "9223372036854775808",
        "-9223372036854775809", "99999999999999999999999", "1.5", "1.9999999", "-1.5",
        "1e2",   "1E2",      "1e-2",      "1e+2",       "1e",             "1e+",
        "1.",    "-.5",      "-",         "--1",        "0x10",           "0x1p3",
        "0x",    "0x.8",     "nan",       "-nan",       "nan(123)",       "nan(0x7)",
        "nanx",  "inf",      "-infinity", "infinity",   "1e39",           "-1e39",
        "1e-46", "1e400",    "3.4028235e38", "3.4028236e38", "1.17549435e-38", "1.4e-45",
        "7e-46", "0.1",      "16777217",  "true",       "false",          "null",
        "tru",   "0001",     "1_000",     "1,5",        "12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890",
    };
    for (numbers) |n| {
        var buffer: [8192]u8 = undefined;
        const fragment = try std.fmt.bufPrint(&buffer,
            \\,"scene":{0s},"scenes":[{{}},{{}}],"nodes":[{{"mesh":{0s},"translation":[{0s},{0s},{0s}],
            \\"rotation":[{0s},0,0,{0s}],"scale":[{0s},1,1],"weights":[{0s}]}}],
            \\"accessors":[{{"count":{0s},"byteOffset":{0s},"componentType":{0s},"normalized":{0s},
            \\"min":[{0s}],"max":[{0s},{0s}]}}],"materials":[{{"alphaCutoff":{0s},"doubleSided":{0s},
            \\"emissiveFactor":[{0s},{0s},{0s}]}}],"samplers":[{{"magFilter":{0s},"wrapS":{0s}}}],
            \\"lights":[],"cameras":[{{"perspective":{{"yfov":{0s},"znear":{0s},"aspectRatio":{0s}}}}}]
        , .{n});
        try expectSameJson(fragment);
    }
}

test "edges: strings, escapes and extras of every kind" {
    const cases = [_][]const u8{
        \\,"nodes":[{"name":"a\"b\\c\/d\b\f\n\r\t\u00e9\u20ac\u0000\uFFFF\uD83D","extras":{"x":[1,{"y":null}]}}]
        ,
        \\,"nodes":[{"name":"","extras":"text"},{"extras":5},{"extras":[]},{"extras":null},{"extras":true}]
        ,
        \\,"extras":{"a":"\u0041"},"extensionsUsed":["KHR_x","\u0041"],"extensionsRequired":[]
        ,
        \\,"extensions":{"VENDOR_a":{"k":[1,2,{"z":{}}]},"VENDOR_b":{}},"meshes":[{"extras":{"targetNames":["a","b"],"z":1},"extensions":{"Q":{"q":1}}}]
        ,
        \\,"meshes":[{"extras":{"targetNames":[]}},{"extras":"x"},{"weights":[]},{"weights":[1,2]}]
        ,
        \\,"asset":{"copyright":"c","generator":"g","minVersion":"2.0","extras":{"k":1},"extensions":{"E":{}}}
        ,
        \\,"materials":[{"extras":{"a":[1,2,3]},"extensions":{"VENDOR_m":{"v":1},"KHR_materials_unlit":{}}}]
        ,
    };
    for (cases) |case| try expectSameJson(case);
}

test "edges: every extension cgltf reads, with its defaults and values" {
    try expectSameJson(
        \\,"extensionsUsed":["KHR_materials_variants"],
        \\"textures":[{"source":0,"sampler":0,"extensions":{"KHR_texture_basisu":{"source":1},"EXT_texture_webp":{"source":0},"X":{}}},
        \\{"extensions":{"KHR_texture_basisu":{"other":1}}}],
        \\"images":[{"uri":"a.png","mimeType":"image/png","name":"i"},{"bufferView":0}],
        \\"samplers":[{"magFilter":9729,"minFilter":9987,"wrapS":33071,"wrapT":33648,"name":"s"},{},{"wrapS":12345}],
        \\"buffers":[{"byteLength":256,"uri":"@B"}],
        \\"bufferViews":[{"buffer":0,"byteLength":64,"byteStride":8,"target":34962,
        \\"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":1,"byteLength":2,"byteStride":8,"count":8,"mode":"ATTRIBUTES","filter":"OCTAHEDRAL"}}},
        \\{"buffer":0,"byteLength":12,"target":34963,"extensions":{"KHR_meshopt_compression":{"buffer":0,"byteStride":4,"count":3,"mode":"TRIANGLES","filter":"NONE"}}},
        \\{"buffer":0,"extensions":{"EXT_meshopt_compression":{"buffer":0,"mode":"INDICES","filter":"QUATERNION"}}},
        \\{"buffer":0,"extensions":{"EXT_meshopt_compression":{"buffer":0,"mode":"X","filter":"EXPONENTIAL"}}},
        \\{"buffer":0,"extensions":{"EXT_meshopt_compression":{"buffer":0,"filter":"COLOR"}}}],
        \\"materials":[{"name":"m","alphaMode":"MASK","alphaCutoff":0.25,"doubleSided":true,
        \\"pbrMetallicRoughness":{"baseColorFactor":[0.1,0.2,0.3,0.4],"metallicFactor":0.5,"roughnessFactor":0.6,
        \\"baseColorTexture":{"index":0,"texCoord":1,"extensions":{"KHR_texture_transform":{"offset":[0.5,0.25],"rotation":1.5,"scale":[2,3],"texCoord":2}}},
        \\"metallicRoughnessTexture":{"index":1}},
        \\"normalTexture":{"index":0,"scale":0.5},"occlusionTexture":{"index":0,"strength":0.25},"emissiveTexture":{"index":1},"emissiveFactor":[1,1,0],
        \\"extensions":{"KHR_materials_pbrSpecularGlossiness":{"diffuseFactor":[1,0,0,1],"specularFactor":[0,1,0],"glossinessFactor":0.5,"diffuseTexture":{"index":0},"specularGlossinessTexture":{"index":1}},
        \\"KHR_materials_clearcoat":{"clearcoatFactor":0.5,"clearcoatRoughnessFactor":0.25,"clearcoatTexture":{"index":0},"clearcoatRoughnessTexture":{"index":1},"clearcoatNormalTexture":{"index":0,"scale":2}},
        \\"KHR_materials_ior":{"ior":1.4},"KHR_materials_specular":{"specularFactor":0.3,"specularColorFactor":[1,0.5,0.25],"specularTexture":{"index":0},"specularColorTexture":{"index":1}},
        \\"KHR_materials_transmission":{"transmissionFactor":0.9,"transmissionTexture":{"index":0}},
        \\"KHR_materials_volume":{"thicknessFactor":2,"thicknessTexture":{"index":1},"attenuationColor":[0.5,0.5,0.5],"attenuationDistance":3},
        \\"KHR_materials_sheen":{"sheenColorFactor":[1,0,1],"sheenColorTexture":{"index":0},"sheenRoughnessFactor":0.7,"sheenRoughnessTexture":{"index":1}},
        \\"KHR_materials_emissive_strength":{"emissiveStrength":5},
        \\"KHR_materials_iridescence":{"iridescenceFactor":1,"iridescenceTexture":{"index":0},"iridescenceIor":1.8,"iridescenceThicknessMinimum":50,"iridescenceThicknessMaximum":500,"iridescenceThicknessTexture":{"index":1}},
        \\"KHR_materials_diffuse_transmission":{"diffuseTransmissionFactor":0.4,"diffuseTransmissionTexture":{"index":0},"diffuseTransmissionColorFactor":[0.1,0.2,0.3],"diffuseTransmissionColorTexture":{"index":1}},
        \\"KHR_materials_anisotropy":{"anisotropyStrength":0.6,"anisotropyRotation":1.2,"anisotropyTexture":{"index":0}},
        \\"KHR_materials_dispersion":{"dispersion":0.1},"KHR_materials_unlit":{},"VENDOR_x":{"a":1}}},
        \\{"extensions":{"KHR_materials_ior":{},"KHR_materials_specular":{},"KHR_materials_emissive_strength":{},"KHR_materials_iridescence":{},"KHR_materials_diffuse_transmission":{},"KHR_materials_volume":{}}},
        \\{"alphaMode":"BLEND"},{"alphaMode":"OPAQUE"},{"alphaMode":"other"},{}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":8,"type":"VEC2"},{"bufferView":1,"componentType":5125,"count":3,"type":"SCALAR"}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_1":0,"_CUSTOM":0,"COLOR_x":0,"JOINTS_-1":0,"WEIGHTS_0":0,"NORMAL":0,"TANGENT":0,"OTHER_1":0,"POSITION_":0},
        \\"indices":1,"material":0,"mode":4,
        \\"extensions":{"KHR_draco_mesh_compression":{"bufferView":0,"attributes":{"POSITION":0,"NORMAL":0}},
        \\"KHR_materials_variants":{"mappings":[{"material":1,"variants":[0,1],"extras":{"m":1}},{"material":2,"variants":[1]}]},"X":{"y":2}}},
        \\{"attributes":{"POSITION":0},"mode":0},{"attributes":{"POSITION":0},"mode":7},{"attributes":{"POSITION":0},"mode":-1}]}],
        \\"extensions":{"KHR_lights_punctual":{"lights":[{"type":"spot","color":[1,0,0],"intensity":3,"range":10,"spot":{"innerConeAngle":0.1,"outerConeAngle":0.5},"name":"l","extras":{"q":1}},
        \\{"type":"point"},{"type":"directional"},{"type":"other"}]},
        \\"KHR_materials_variants":{"variants":[{"name":"v0","extras":1},{"name":"v1"}]},"VENDOR_y":{"z":[]}},
        \\"nodes":[{"extensions":{"KHR_lights_punctual":{"light":2},"EXT_mesh_gpu_instancing":{"attributes":{"TRANSLATION":0,"SCALE":0}},"Q":{}},"mesh":0},
        \\{"extensions":{"KHR_lights_punctual":{"light":-1}}}],
        \\"cameras":[{"perspective":{"aspectRatio":1.5,"yfov":0.8,"zfar":100,"znear":0.1,"extras":{"p":1}},"name":"c","extras":2},
        \\{"orthographic":{"xmag":1,"ymag":2,"zfar":3,"znear":0.5,"extras":[1]}},{"type":"perspective"},{"perspective":{"znear":1}}]
    );
}

test "edges: material variant mappings with odd variants and materials" {
    const cases = [_][]const u8{
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[-2]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[-3]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[-1]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[-7]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":[5]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":-1,"variants":[0]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":3,"variants":[0]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"variants":[0]}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[{"material":0,"variants":{}}]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[]},"KHR_materials_variants":{"mappings":[]}}}]}]
        ,
        \\,"materials":[{}],"meshes":[{"primitives":[{"attributes":{},"extensions":{"KHR_materials_variants":{"mappings":[1]}}}]}]
        ,
        \\,"extensions":{"KHR_materials_variants":{"variants":[{}]}}
        ,
    };
    for (cases) |case| try expectSameJson(case);
}

test "edges: accessors of every type, component type and layout read as the original's" {
    const gpa = testing.allocator;
    const types = [_][]const u8{ "SCALAR", "VEC2", "VEC3", "VEC4", "MAT2", "MAT3", "MAT4", "VEC5" };
    const components = [_][]const u8{ "5120", "5121", "5122", "5123", "5125", "5126", "5124", "0" };
    const layouts = [_][]const u8{
        \\"byteOffset":0
        ,
        \\"byteOffset":3
        ,
        \\"byteOffset":1,"normalized":true
        ,
        \\"byteOffset":0,"normalized":true
        ,
    };
    const strides = [_][]const u8{ "", ",\"byteStride\":4", ",\"byteStride\":36", ",\"byteStride\":64" };
    for (types) |t| for (components) |component| for (layouts) |layout| for (strides) |stride| {
        for ([_][]const u8{ "1", "3", "0", "200" }) |count| {
            const fragment = try std.fmt.allocPrint(gpa,
                \\,"buffers":[{{"byteLength":256,"uri":"@B"}}],"bufferViews":[{{"buffer":0,"byteOffset":8,"byteLength":248{s}}}],
                \\"accessors":[{{"bufferView":0,"componentType":{s},"type":"{s}","count":{s},{s}}}],
                \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":0}}]}}]
            , .{ stride, component, t, count, layout });
            defer gpa.free(fragment);
            try expectSameJson(fragment);
        }
    };
}

test "edges: sparse accessors, with and without a base view, read as the original's" {
    const gpa = testing.allocator;
    const index_types = [_][]const u8{ "5121", "5123", "5125", "5122", "5126" };
    // Index offsets that give sorted, unsorted, repeated and too large
    // indices from the buffer's bytes.
    const offsets = [_][]const u8{ "0", "1", "16", "100", "250" };
    const bases = [_][]const u8{ "\"bufferView\":0,", "" };
    for (index_types) |index_type| for (offsets) |offset| for (bases) |base| {
        for ([_][]const u8{ "1", "2", "5", "40" }) |sparse_count| {
            const fragment = try std.fmt.allocPrint(gpa,
                \\,"buffers":[{{"byteLength":256,"uri":"@B"}}],"bufferViews":[{{"buffer":0,"byteLength":256}}],
                \\"accessors":[{{{s}"componentType":5121,"type":"VEC2","count":250,
                \\"sparse":{{"count":{s},"indices":{{"bufferView":0,"byteOffset":{s},"componentType":{s}}},
                \\"values":{{"bufferView":0,"byteOffset":7}}}}}}]
            , .{ base, sparse_count, offset, index_type });
            defer gpa.free(fragment);
            try expectSameJson(fragment);
        }
    };
    // A sparse index past the accessor's elements.
    try expectSameJson(
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":256}],
        \\"accessors":[{"componentType":5126,"type":"SCALAR","count":2,
        \\"sparse":{"count":1,"indices":{"bufferView":0,"byteOffset":255,"componentType":5121},
        \\"values":{"bufferView":0}}}]
    );
}

test "edges: validation of views, meshes, nodes and animations gives the original's results" {
    const cases = [_][]const u8{
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteOffset":200,"byteLength":100}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteOffset":18446744073709551615,"byteLength":2}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":16}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"type":"VEC4","count":2}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":16}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"type":"VEC4","count":0}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":256}],
        \\"accessors":[{"bufferView":0,"componentType":5121,"type":"SCALAR","count":4},{"bufferView":0,"componentType":5126,"type":"VEC3","count":2}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":1},"indices":0}]}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":256,"byteStride":2}],
        \\"accessors":[{"bufferView":0,"componentType":5121,"type":"SCALAR","count":4},{"bufferView":0,"componentType":5126,"type":"VEC3","count":200}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":1},"indices":0}]}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],"bufferViews":[{"buffer":0,"byteLength":256}],
        \\"accessors":[{"bufferView":0,"componentType":5121,"type":"SCALAR","count":4},{"bufferView":0,"componentType":5126,"type":"VEC3","count":200}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":1},"indices":0}]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"VEC3","count":3},{"componentType":5126,"type":"VEC3","count":4}],
        \\"meshes":[{"weights":[1],"primitives":[{"attributes":{"POSITION":0},"targets":[{"POSITION":1}]}]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"VEC3","count":3}],
        \\"meshes":[{"weights":[1],"extras":{"targetNames":["a","b"]},"primitives":[{"attributes":{"POSITION":0},"targets":[{"POSITION":0}]}]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"VEC3","count":3}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0},"targets":[{}]},{"attributes":{"POSITION":0}}]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"VEC3","count":3}],
        \\"meshes":[{"weights":[],"primitives":[{"attributes":{"POSITION":0}}]}],"nodes":[{"mesh":0,"weights":[1]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"VEC3","count":3},{"componentType":5126,"type":"VEC3","count":2}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"nodes":[{"mesh":0,"extensions":{"EXT_mesh_gpu_instancing":{"attributes":{"A":0,"B":1}}}},
        \\{"extensions":{"EXT_mesh_gpu_instancing":{"attributes":{}}}}]
        ,
        \\,"nodes":[{"children":[1]},{"children":[2]},{"children":[0]}]
        ,
        \\,"nodes":[{"children":[1]},{"children":[2]},{"children":[3]},{"children":[1]}]
        ,
        \\,"nodes":[{"children":[1],"translation":[1,2,3],"rotation":[0.5,0.5,0.5,0.5],"scale":[2,3,4]},{"children":[2],"matrix":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]},{"rotation":[0.1,0.2,0.3,0.9]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"SCALAR","count":2},{"componentType":5126,"type":"VEC3","count":6},{"componentType":5126,"type":"SCALAR","count":4}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":1},"targets":[{},{}]}]}],"nodes":[{"mesh":0},{}],
        \\"animations":[{"samplers":[{"input":0,"output":1,"interpolation":"CUBICSPLINE"},{"input":0,"output":2,"interpolation":"STEP"},{"input":0,"output":1}],
        \\"channels":[{"sampler":0,"target":{"node":0,"path":"translation"}},{"sampler":1,"target":{"node":0,"path":"weights"}},
        \\{"sampler":2,"target":{"node":1,"path":"rotation"}},{"sampler":2,"target":{"path":"scale"}},{"sampler":1,"target":{"node":1,"path":"weights"}}]}]
        ,
        \\,"accessors":[{"componentType":5126,"type":"SCALAR","count":2}],
        \\"animations":[{"samplers":[{"input":0,"output":0}],"channels":[{"sampler":1,"target":{"node":0}}]}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],
        \\"bufferViews":[{"buffer":0,"byteLength":24,"byteStride":8,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteLength":300,"byteStride":8,"count":3,"mode":"ATTRIBUTES"}}}]
        ,
        \\,"buffers":[{"byteLength":256,"uri":"@B"}],
        \\"bufferViews":[{"buffer":0,"byteLength":24,"byteStride":4,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteStride":8,"count":3,"mode":"ATTRIBUTES"}}},
        \\{"buffer":0,"byteLength":24,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteStride":6,"count":4,"mode":"ATTRIBUTES"}}},
        \\{"buffer":0,"byteLength":8,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteStride":2,"count":4,"mode":"TRIANGLES"}}},
        \\{"buffer":0,"byteLength":12,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteStride":4,"count":3,"mode":"INDICES","filter":"OCTAHEDRAL"}}},
        \\{"buffer":0,"byteLength":24,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteStride":8,"count":3,"mode":"ATTRIBUTES","filter":"QUATERNION"}}}]
        ,
        \\,"extensions":{"KHR_materials_variants":{"variants":[{"name":"a"},{"extras":1}]}}
        ,
    };
    for (cases) |case| try expectSameJson(case);
}

test "edges: buffers from data URIs, files and the BIN chunk load as the original's" {
    const cases = [_][]const u8{
        \\,"buffers":[{"byteLength":4,"uri":"data:;base64,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:;base64,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":2,"uri":"data:;base64,AA=="}]
        ,
        \\,"buffers":[{"byteLength":1,"uri":"data:;base64,AA=="}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:;base64,A A="}]
        ,
        \\,"buffers":[{"byteLength":0,"uri":"data:;base64,"}]
        ,
        // Sizes no allocator can give.
        \\,"buffers":[{"byteLength":9223372036854775807,"uri":"data:;base64,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":18446744073709551615,"uri":"data:;base64,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:application/gltf-buffer,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:base64,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:;base64"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:x;base64,AAEC,AAEC"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"http://example.com/a.bin"}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"a.bin"}]
        ,
        \\,"buffers":[{"byteLength":3}]
        ,
        \\,"buffers":[{"byteLength":3,"uri":"data:;base64,AAEC"},{"byteLength":3,"uri":"data:;base64,!!!!"}]
        ,
    };
    for (cases) |case| try expectSameJson(case);
}

test "edges: files beside the glTF load as the original's" {
    const gpa = testing.allocator;
    const io = testing.io;
    // A file name with escapes, beside a model's own .bin.
    const paths = try samples.modelPaths(gpa, io);
    defer samples.freePaths(gpa, paths);
    const box = for (paths) |path| {
        if (std.mem.endsWith(u8, path, "/Box/glTF/Box.gltf")) break path;
    } else return error.NoBox;
    const cases = [_][]const u8{
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"Box0.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"Box%30.bin\"}]}",
        // A `%00` ends the file name.
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"Box0.bin%00x\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":0,\"uri\":\"Box0.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":10,\"uri\":\"Box0.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":649,\"uri\":\"Box0.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"Missing.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"Box%3.bin\"}]}",
        "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":648,\"uri\":\"../Box/glTF/Box0.bin\"}]}",
    };
    for (cases) |case| {
        _ = oracle.expectSame(gpa, io, .{ .bytes = .{ .data = case, .gltf_path = box } }, .{}) catch |err| {
            std.debug.print("case: {s}\n", .{case});
            return err;
        };
    }
}
