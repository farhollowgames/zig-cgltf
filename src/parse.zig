//! glTF JSON to a `Gltf`: cgltf's parser, one function for each of its
//! `cgltf_parse_json_*` functions, reading jsmn's tokens in order. Each
//! returns the index of the token after what it read. References are read
//! as raw indices and checked against the arrays once everything is read,
//! as cgltf's `cgltf_fixup_pointers` does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const jsmn = @import("jsmn.zig");
const number = @import("number.zig");
const types = @import("types.zig");
const cgltf = @import("cgltf.zig");

const Token = jsmn.Token;
const Gltf = cgltf.Gltf;
const invalid_index = types.invalid_index;

/// cgltf's three parse failures: `CGLTF_ERROR_JSON`, which becomes
/// `invalid_gltf`; `CGLTF_ERROR_NOMEM`; and `CGLTF_ERROR_LEGACY`.
const Fail = error{ Json, Legacy, OutOfMemory };

/// Parses `json_chunk` into `gltf`, whose arena holds what it allocates.
/// The tokens are allocated with `gpa` and freed before it returns.
pub fn parseJson(
    gltf: *Gltf,
    gpa: Allocator,
    json_chunk: []const u8,
    json_token_count: usize,
) cgltf.Error!void {
    var token_count_max = json_token_count;
    if (token_count_max == 0) {
        var counter: jsmn.Parser = .{ .toksuper = 0 };
        const counted = jsmn.parse(&counter, json_chunk, null) catch return error.InvalidJson;
        // cgltf keeps the count in an int.
        if (counted == 0 or counted > std.math.maxInt(i32)) return error.InvalidJson;
        token_count_max = counted;
    }
    const capacity = std.math.add(usize, token_count_max, 1) catch return error.OutOfMemory;
    const tokens = try gpa.alloc(Token, capacity);
    defer gpa.free(tokens);

    var parser: jsmn.Parser = .{};
    const token_count = jsmn.parse(&parser, json_chunk, tokens[0..token_count_max]) catch
        return error.InvalidJson;
    if (token_count == 0 or token_count > std.math.maxInt(i32)) return error.InvalidJson;
    // The UNDEFINED token after the last stops every read of a truncated
    // structure, as in cgltf.
    tokens[token_count] = .{ .type = .undefined, .start = 0, .end = 0, .size = 0, .parent = -1 };

    const p: Parser = .{
        .gpa = gltf.arena.allocator(),
        .tokens = tokens[0 .. token_count + 1],
        .json = json_chunk,
    };
    _ = p.root(0, gltf) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Legacy => error.LegacyGltf,
        error.Json => error.InvalidGltf,
    };
    fixup(gltf) catch return error.InvalidGltf;
    gltf.json = json_chunk;
}

const Parser = struct {
    gpa: Allocator,
    tokens: []const Token,
    json: []const u8,

    fn text(p: Parser, i: usize) []const u8 {
        const token = p.tokens[i];
        return p.json[@intCast(token.start)..@intCast(token.end)];
    }

    /// The text cgltf converts to a number: at most 127 bytes.
    fn numberText(p: Parser, i: usize) []const u8 {
        const all = p.text(i);
        return all[0..@min(all.len, 127)];
    }

    /// `CGLTF_CHECK_KEY`: a string with a value after it.
    fn checkKey(p: Parser, i: usize) Fail!void {
        const token = p.tokens[i];
        if (token.type != .string or token.size == 0) return error.Json;
    }

    fn checkType(p: Parser, i: usize, token_type: jsmn.TokenType) Fail!void {
        if (p.tokens[i].type != token_type) return error.Json;
    }

    /// `cgltf_json_strcmp(...) == 0`.
    fn is(p: Parser, i: usize, name: []const u8) bool {
        return p.tokens[i].type == .string and std.mem.eql(u8, p.text(i), name);
    }

    /// `cgltf_json_to_int`: -1 for anything but a primitive.
    fn toInt(p: Parser, i: usize) i32 {
        if (p.tokens[i].type != .primitive) return -1;
        return number.atoi(p.numberText(i));
    }

    /// `cgltf_json_to_size`: 0 for anything but a primitive, and for a
    /// negative number.
    fn toSize(p: Parser, i: usize) usize {
        if (p.tokens[i].type != .primitive) return 0;
        const value = number.atoll(p.numberText(i));
        return if (value < 0) 0 else @intCast(value);
    }

    /// `cgltf_json_to_float`: -1 for anything but a primitive.
    fn toFloat(p: Parser, i: usize) f32 {
        if (p.tokens[i].type != .primitive) return -1.0;
        return number.toFloat(number.atof(p.numberText(i)));
    }

    /// `cgltf_json_to_bool`: true for the text `true` of any token.
    fn toBool(p: Parser, i: usize) bool {
        return std.mem.eql(u8, p.text(i), "true");
    }

    /// A reference's raw index, as cgltf's `CGLTF_PTRINDEX`: -1 is none.
    fn ref(p: Parser, i: usize) ?u32 {
        const index = p.toInt(i);
        if (index == -1) return null;
        if (index < 0) return invalid_index;
        return @intCast(index);
    }

    /// A required reference's raw index: any missing one is invalid.
    fn refRequired(p: Parser, i: usize) u32 {
        return p.ref(i) orelse invalid_index;
    }

    /// `cgltf_skip_json`: the index after the value at `i`.
    fn skip(p: Parser, start: usize) Fail!usize {
        var i = start;
        var end = start + 1;
        while (i < end) : (i += 1) {
            const token = p.tokens[i];
            switch (token.type) {
                .object => end += @as(usize, @intCast(token.size)) * 2,
                .array => end += @intCast(token.size),
                .primitive, .string => {},
                .undefined => return error.Json,
            }
        }
        return i;
    }

    fn floatArray(p: Parser, start: usize, out: []f32) Fail!usize {
        try p.checkType(start, .array);
        if (p.tokens[start].size != out.len) return error.Json;
        var i = start + 1;
        for (out) |*value| {
            try p.checkType(i, .primitive);
            value.* = p.toFloat(i);
            i += 1;
        }
        return i;
    }

    fn string(p: Parser, i: usize, out: *?[:0]u8) Fail!usize {
        try p.checkType(i, .string);
        if (out.* != null) return error.Json;
        out.* = try p.gpa.dupeSentinel(u8, p.text(i), 0);
        return i + 1;
    }

    /// `cgltf_parse_json_array`: allocates the elements, which start as
    /// cgltf's zeroed memory. An object where an array belongs is a glTF
    /// 1.0 file.
    fn array(p: Parser, i: usize, comptime T: type, out: *[]T, seen: *bool) Fail!usize {
        const token = p.tokens[i];
        if (token.type != .array) return if (token.type == .object) error.Legacy else error.Json;
        if (seen.*) return error.Json;
        seen.* = true;
        out.* = try p.gpa.alloc(T, @intCast(token.size));
        for (out.*) |*item| item.* = zeroed(T);
        return i + 1;
    }

    /// `array` for the arrays whose absence the result keeps.
    fn optionalArray(p: Parser, i: usize, comptime T: type, out: *?[]T) Fail!usize {
        var seen = out.* != null;
        var items: []T = &.{};
        const next = try p.array(i, T, &items, &seen);
        out.* = items;
        return next;
    }

    fn stringArray(p: Parser, start: usize, out: *[][:0]u8, seen: *bool) Fail!usize {
        try p.checkType(start, .array);
        var names: []?[:0]u8 = &.{};
        var i = try p.array(start, ?[:0]u8, &names, seen);
        for (names) |*name| i = try p.string(i, name);
        out.* = @ptrCast(names);
        return i;
    }

    fn attributeList(p: Parser, start: usize, out: *[]types.Attribute, seen: *bool) Fail!usize {
        try p.checkType(start, .object);
        if (seen.*) return error.Json;
        seen.* = true;
        const count: usize = @intCast(p.tokens[start].size);
        out.* = try p.gpa.alloc(types.Attribute, count);
        for (out.*) |*attribute| attribute.* = .{ .name = undefined };
        var i = start + 1;
        for (out.*) |*attribute| {
            try p.checkKey(i);
            var name: ?[:0]u8 = null;
            // cgltf reports any failure to copy the name as invalid JSON.
            i = p.string(i, &name) catch return error.Json;
            attribute.name = name.?;
            parseAttributeType(attribute.name, &attribute.type, &attribute.index);
            attribute.data = p.refRequired(i);
            i += 1;
        }
        return i;
    }

    fn extras(p: Parser, i: usize, out: *types.Extras) Fail!usize {
        if (out.data != null) return error.Json;
        const token = p.tokens[i];
        out.start_offset = @bitCast(token.start);
        out.end_offset = @bitCast(token.end);
        out.data = try p.gpa.dupeSentinel(u8, p.text(i), 0);
        return p.skip(i);
    }

    fn unprocessedExtension(p: Parser, start: usize, out: *types.Extension) Fail!usize {
        try p.checkType(start, .string);
        try p.checkType(start + 1, .object);
        out.name = try p.gpa.dupeSentinel(u8, p.text(start), 0);
        const i = start + 1;
        out.data = try p.gpa.dupeSentinel(u8, p.text(i), 0);
        return p.skip(i);
    }

    /// Starts an `extensions` object whose known extensions the caller
    /// reads: allocates room for all of them as unknown ones.
    fn extensionsObject(p: Parser, i: usize, out: *[]types.Extension, seen: *bool) Fail!usize {
        try p.checkType(i, .object);
        if (seen.*) return error.Json;
        seen.* = true;
        out.* = try p.gpa.alloc(types.Extension, @intCast(p.tokens[i].size));
        out.len = 0;
        return i + 1;
    }

    /// Keeps the extension at `i` in `out`, which `extensionsObject` sized.
    fn keepExtension(p: Parser, i: usize, out: *[]types.Extension) Fail!usize {
        out.len += 1;
        return p.unprocessedExtension(i, &out.*[out.len - 1]);
    }

    /// `cgltf_parse_json_unprocessed_extensions`, from the `extensions` key.
    fn unprocessedExtensions(p: Parser, key: usize, out: *[]types.Extension, seen: *bool) Fail!usize {
        var i = try p.extensionsObject(key + 1, out, seen);
        const size = p.tokens[key + 1].size;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            i = try p.keepExtension(i, out);
        }
        return i;
    }

    fn dracoMeshCompression(
        p: Parser,
        start: usize,
        out: *types.DracoMeshCompression,
        seen_attributes: *bool,
    ) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "attributes")) {
                i = try p.attributeList(i + 1, &out.attributes, seen_attributes);
            } else if (p.is(i, "bufferView")) {
                i += 1;
                out.buffer_view = p.ref(i);
                i += 1;
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn meshGpuInstancing(
        p: Parser,
        start: usize,
        out: *types.MeshGpuInstancing,
        seen_attributes: *bool,
    ) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "attributes")) {
                i = try p.attributeList(i + 1, &out.attributes, seen_attributes);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    /// `cgltf_parse_json_material_mapping_data`: with no `out`, only
    /// counts the mappings into `offset`.
    fn materialMappingData(
        p: Parser,
        start: usize,
        out: ?[]types.MaterialMapping,
        offset: *usize,
    ) Fail!usize {
        try p.checkType(start, .array);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkType(i, .object);
            const obj_size = p.tokens[i].size;
            i += 1;
            var material_index: i32 = -1;
            var variants_tok: ?usize = null;
            var extras_tok: ?usize = null;
            var k: i32 = 0;
            while (k < obj_size) : (k += 1) {
                try p.checkKey(i);
                if (p.is(i, "material")) {
                    i += 1;
                    material_index = p.toInt(i);
                    i += 1;
                } else if (p.is(i, "variants")) {
                    variants_tok = i + 1;
                    try p.checkType(i + 1, .array);
                    i = try p.skip(i + 1);
                } else if (p.is(i, "extras")) {
                    extras_tok = i + 1;
                    i = try p.skip(i + 1);
                } else {
                    i = try p.skip(i + 1);
                }
            }
            const variants = variants_tok orelse return error.Json;
            if (material_index < 0) return error.Json;
            const variant_count: usize = @intCast(p.tokens[variants].size);
            if (out) |mappings| {
                for (0..variant_count) |v| {
                    const variant = p.toInt(variants + 1 + v);
                    // cgltf returns a negative variant as its own error code.
                    if (variant < 0) return switch (variant) {
                        -2 => error.OutOfMemory,
                        -3 => error.Legacy,
                        else => error.Json,
                    };
                    const mapping = &mappings[offset.*];
                    mapping.material = @intCast(material_index);
                    mapping.variant = @intCast(variant);
                    if (extras_tok) |e| _ = try p.extras(e, &mapping.extras);
                    offset.* += 1;
                }
            } else {
                offset.* += variant_count;
            }
        }
        return i;
    }

    fn materialMappings(p: Parser, start: usize, out: *types.Primitive, seen: *bool) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "mappings")) {
                if (seen.*) return error.Json;
                var count: usize = 0;
                _ = try p.materialMappingData(i + 1, null, &count);
                seen.* = true;
                out.mappings = try p.gpa.alloc(types.MaterialMapping, count);
                for (out.mappings) |*mapping| mapping.* = .{};
                var filled: usize = 0;
                i = try p.materialMappingData(i + 1, out.mappings, &filled);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn primitive(p: Parser, start: usize, out: *types.Primitive) Fail!usize {
        try p.checkType(start, .object);
        out.type = .triangles;
        var seen: struct {
            attributes: bool = false,
            targets: bool = false,
            extensions: bool = false,
            draco_attributes: bool = false,
            mappings: bool = false,
        } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "mode")) {
                i += 1;
                out.type = switch (p.toInt(i)) {
                    0 => .points,
                    1 => .lines,
                    2 => .line_loop,
                    3 => .line_strip,
                    4 => .triangles,
                    5 => .triangle_strip,
                    6 => .triangle_fan,
                    else => .invalid,
                };
                i += 1;
            } else if (p.is(i, "indices")) {
                i += 1;
                out.indices = p.ref(i);
                i += 1;
            } else if (p.is(i, "material")) {
                i += 1;
                out.material = p.ref(i);
                i += 1;
            } else if (p.is(i, "attributes")) {
                i = try p.attributeList(i + 1, &out.attributes, &seen.attributes);
            } else if (p.is(i, "targets")) {
                i = try p.array(i + 1, types.MorphTarget, &out.targets, &seen.targets);
                for (out.targets) |*target| {
                    var seen_target = false;
                    i = try p.attributeList(i, &target.attributes, &seen_target);
                }
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.extensions, &seen.extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "KHR_draco_mesh_compression")) {
                        out.has_draco_mesh_compression = true;
                        i = try p.dracoMeshCompression(
                            i + 1,
                            &out.draco_mesh_compression,
                            &seen.draco_attributes,
                        );
                    } else if (p.is(i, "KHR_materials_variants")) {
                        i = try p.materialMappings(i + 1, out, &seen.mappings);
                    } else {
                        i = try p.keepExtension(i, &out.extensions);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn mesh(p: Parser, start: usize, out: *types.Mesh) Fail!usize {
        try p.checkType(start, .object);
        var seen: struct { primitives: bool = false, extensions: bool = false } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "primitives")) {
                i = try p.array(i + 1, types.Primitive, &out.primitives, &seen.primitives);
                for (out.primitives) |*prim| i = try p.primitive(i, prim);
            } else if (p.is(i, "weights")) {
                i = try p.optionalArray(i + 1, f32, &out.weights);
                i = try p.floatArray(i - 1, out.weights.?);
            } else if (p.is(i, "extras")) {
                i += 1;
                const token = p.tokens[i];
                out.extras.start_offset = @bitCast(token.start);
                out.extras.end_offset = @bitCast(token.end);
                if (token.type == .object) {
                    const extras_size = token.size;
                    i += 1;
                    var k: i32 = 0;
                    while (k < extras_size) : (k += 1) {
                        try p.checkKey(i);
                        if (p.is(i, "targetNames") and p.tokens[i + 1].type == .array) {
                            var seen_names = out.target_names != null;
                            var names: [][:0]u8 = &.{};
                            i = try p.stringArray(i + 1, &names, &seen_names);
                            out.target_names = names;
                        } else {
                            i = try p.skip(i + 1);
                        }
                    }
                } else {
                    i = try p.skip(i);
                }
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen.extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn accessorSparse(p: Parser, start: usize, out: *types.AccessorSparse) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "count")) {
                i += 1;
                out.count = p.toSize(i);
                i += 1;
            } else if (p.is(i, "indices")) {
                i += 1;
                try p.checkType(i, .object);
                const indices_size = p.tokens[i].size;
                i += 1;
                var k: i32 = 0;
                while (k < indices_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "bufferView")) {
                        i += 1;
                        out.indices_buffer_view = p.ref(i);
                        i += 1;
                    } else if (p.is(i, "byteOffset")) {
                        i += 1;
                        out.indices_byte_offset = p.toSize(i);
                        i += 1;
                    } else if (p.is(i, "componentType")) {
                        i += 1;
                        out.indices_component_type = componentType(p.toInt(i));
                        i += 1;
                    } else {
                        i = try p.skip(i + 1);
                    }
                }
            } else if (p.is(i, "values")) {
                i += 1;
                try p.checkType(i, .object);
                const values_size = p.tokens[i].size;
                i += 1;
                var k: i32 = 0;
                while (k < values_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "bufferView")) {
                        i += 1;
                        out.values_buffer_view = p.ref(i);
                        i += 1;
                    } else if (p.is(i, "byteOffset")) {
                        i += 1;
                        out.values_byte_offset = p.toSize(i);
                        i += 1;
                    } else {
                        i = try p.skip(i + 1);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn accessor(p: Parser, start: usize, out: *types.Accessor) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "bufferView")) {
                i += 1;
                out.buffer_view = p.ref(i);
                i += 1;
            } else if (p.is(i, "byteOffset")) {
                i += 1;
                out.offset = p.toSize(i);
                i += 1;
            } else if (p.is(i, "componentType")) {
                i += 1;
                out.component_type = componentType(p.toInt(i));
                i += 1;
            } else if (p.is(i, "normalized")) {
                i += 1;
                out.normalized = p.toBool(i);
                i += 1;
            } else if (p.is(i, "count")) {
                i += 1;
                out.count = p.toSize(i);
                i += 1;
            } else if (p.is(i, "type")) {
                i += 1;
                if (p.is(i, "SCALAR")) {
                    out.type = .scalar;
                } else if (p.is(i, "VEC2")) {
                    out.type = .vec2;
                } else if (p.is(i, "VEC3")) {
                    out.type = .vec3;
                } else if (p.is(i, "VEC4")) {
                    out.type = .vec4;
                } else if (p.is(i, "MAT2")) {
                    out.type = .mat2;
                } else if (p.is(i, "MAT3")) {
                    out.type = .mat3;
                } else if (p.is(i, "MAT4")) {
                    out.type = .mat4;
                }
                i += 1;
            } else if (p.is(i, "min")) {
                i += 1;
                out.has_min = true;
                // The type may come later, so the size is the array's.
                const min_size: usize = @intCast(@min(p.tokens[i].size, 16));
                i = try p.floatArray(i, out.min[0..min_size]);
            } else if (p.is(i, "max")) {
                i += 1;
                out.has_max = true;
                const max_size: usize = @intCast(@min(p.tokens[i].size, 16));
                i = try p.floatArray(i, out.max[0..max_size]);
            } else if (p.is(i, "sparse")) {
                out.is_sparse = true;
                i = try p.accessorSparse(i + 1, &out.sparse);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn textureTransform(p: Parser, start: usize, out: *types.TextureTransform) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "offset")) {
                i = try p.floatArray(i + 1, &out.offset);
            } else if (p.is(i, "rotation")) {
                i += 1;
                out.rotation = p.toFloat(i);
                i += 1;
            } else if (p.is(i, "scale")) {
                i = try p.floatArray(i + 1, &out.scale);
            } else if (p.is(i, "texCoord")) {
                i += 1;
                out.has_texcoord = true;
                out.texcoord = p.toInt(i);
                i += 1;
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn textureView(p: Parser, start: usize, out: *types.TextureView) Fail!usize {
        try p.checkType(start, .object);
        out.scale = 1.0;
        out.transform.scale = @splat(1.0);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "index")) {
                i += 1;
                out.texture = p.ref(i);
                i += 1;
            } else if (p.is(i, "texCoord")) {
                i += 1;
                out.texcoord = p.toInt(i);
                i += 1;
            } else if (p.is(i, "scale") or p.is(i, "strength")) {
                i += 1;
                out.scale = p.toFloat(i);
                i += 1;
            } else if (p.is(i, "extensions")) {
                i += 1;
                try p.checkType(i, .object);
                const extensions_size = p.tokens[i].size;
                i += 1;
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "KHR_texture_transform")) {
                        out.has_transform = true;
                        i = try p.textureTransform(i + 1, &out.transform);
                    } else {
                        i = try p.skip(i + 1);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    /// The object at `start` read by `field`, which names one of its keys
    /// and reads that key's value, or returns null for keys it ignores.
    fn object(
        p: Parser,
        start: usize,
        out: anytype,
        comptime field: fn (Parser, usize, @TypeOf(out)) Fail!?usize,
    ) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            i = try field(p, i, out) orelse try p.skip(i + 1);
        }
        return i;
    }

    fn floatField(p: Parser, i: usize, out: *f32) usize {
        out.* = p.toFloat(i + 1);
        return i + 2;
    }

    fn pbrMetallicRoughnessField(p: Parser, i: usize, out: *types.PbrMetallicRoughness) Fail!?usize {
        if (p.is(i, "metallicFactor")) return p.floatField(i, &out.metallic_factor);
        if (p.is(i, "roughnessFactor")) return p.floatField(i, &out.roughness_factor);
        if (p.is(i, "baseColorFactor")) return try p.floatArray(i + 1, &out.base_color_factor);
        if (p.is(i, "baseColorTexture")) return try p.textureView(i + 1, &out.base_color_texture);
        if (p.is(i, "metallicRoughnessTexture")) {
            return try p.textureView(i + 1, &out.metallic_roughness_texture);
        }
        return null;
    }

    fn pbrSpecularGlossinessField(p: Parser, i: usize, out: *types.PbrSpecularGlossiness) Fail!?usize {
        if (p.is(i, "diffuseFactor")) return try p.floatArray(i + 1, &out.diffuse_factor);
        if (p.is(i, "specularFactor")) return try p.floatArray(i + 1, &out.specular_factor);
        if (p.is(i, "glossinessFactor")) return p.floatField(i, &out.glossiness_factor);
        if (p.is(i, "diffuseTexture")) return try p.textureView(i + 1, &out.diffuse_texture);
        if (p.is(i, "specularGlossinessTexture")) {
            return try p.textureView(i + 1, &out.specular_glossiness_texture);
        }
        return null;
    }

    fn clearcoatField(p: Parser, i: usize, out: *types.Clearcoat) Fail!?usize {
        if (p.is(i, "clearcoatFactor")) return p.floatField(i, &out.clearcoat_factor);
        if (p.is(i, "clearcoatRoughnessFactor")) {
            return p.floatField(i, &out.clearcoat_roughness_factor);
        }
        if (p.is(i, "clearcoatTexture")) return try p.textureView(i + 1, &out.clearcoat_texture);
        if (p.is(i, "clearcoatRoughnessTexture")) {
            return try p.textureView(i + 1, &out.clearcoat_roughness_texture);
        }
        if (p.is(i, "clearcoatNormalTexture")) {
            return try p.textureView(i + 1, &out.clearcoat_normal_texture);
        }
        return null;
    }

    fn iorField(p: Parser, i: usize, out: *types.Ior) Fail!?usize {
        if (p.is(i, "ior")) return p.floatField(i, &out.ior);
        return null;
    }

    fn specularField(p: Parser, i: usize, out: *types.Specular) Fail!?usize {
        if (p.is(i, "specularFactor")) return p.floatField(i, &out.specular_factor);
        if (p.is(i, "specularColorFactor")) return try p.floatArray(i + 1, &out.specular_color_factor);
        if (p.is(i, "specularTexture")) return try p.textureView(i + 1, &out.specular_texture);
        if (p.is(i, "specularColorTexture")) {
            return try p.textureView(i + 1, &out.specular_color_texture);
        }
        return null;
    }

    fn transmissionField(p: Parser, i: usize, out: *types.Transmission) Fail!?usize {
        if (p.is(i, "transmissionFactor")) return p.floatField(i, &out.transmission_factor);
        if (p.is(i, "transmissionTexture")) {
            return try p.textureView(i + 1, &out.transmission_texture);
        }
        return null;
    }

    fn volumeField(p: Parser, i: usize, out: *types.Volume) Fail!?usize {
        if (p.is(i, "thicknessFactor")) return p.floatField(i, &out.thickness_factor);
        if (p.is(i, "thicknessTexture")) return try p.textureView(i + 1, &out.thickness_texture);
        if (p.is(i, "attenuationColor")) return try p.floatArray(i + 1, &out.attenuation_color);
        if (p.is(i, "attenuationDistance")) return p.floatField(i, &out.attenuation_distance);
        return null;
    }

    fn sheenField(p: Parser, i: usize, out: *types.Sheen) Fail!?usize {
        if (p.is(i, "sheenColorFactor")) return try p.floatArray(i + 1, &out.sheen_color_factor);
        if (p.is(i, "sheenColorTexture")) return try p.textureView(i + 1, &out.sheen_color_texture);
        if (p.is(i, "sheenRoughnessFactor")) return p.floatField(i, &out.sheen_roughness_factor);
        if (p.is(i, "sheenRoughnessTexture")) {
            return try p.textureView(i + 1, &out.sheen_roughness_texture);
        }
        return null;
    }

    fn emissiveStrengthField(p: Parser, i: usize, out: *types.EmissiveStrength) Fail!?usize {
        if (p.is(i, "emissiveStrength")) return p.floatField(i, &out.emissive_strength);
        return null;
    }

    fn iridescenceField(p: Parser, i: usize, out: *types.Iridescence) Fail!?usize {
        if (p.is(i, "iridescenceFactor")) return p.floatField(i, &out.iridescence_factor);
        if (p.is(i, "iridescenceTexture")) return try p.textureView(i + 1, &out.iridescence_texture);
        if (p.is(i, "iridescenceIor")) return p.floatField(i, &out.iridescence_ior);
        if (p.is(i, "iridescenceThicknessMinimum")) {
            return p.floatField(i, &out.iridescence_thickness_min);
        }
        if (p.is(i, "iridescenceThicknessMaximum")) {
            return p.floatField(i, &out.iridescence_thickness_max);
        }
        if (p.is(i, "iridescenceThicknessTexture")) {
            return try p.textureView(i + 1, &out.iridescence_thickness_texture);
        }
        return null;
    }

    fn diffuseTransmissionField(p: Parser, i: usize, out: *types.DiffuseTransmission) Fail!?usize {
        if (p.is(i, "diffuseTransmissionFactor")) {
            return p.floatField(i, &out.diffuse_transmission_factor);
        }
        if (p.is(i, "diffuseTransmissionTexture")) {
            return try p.textureView(i + 1, &out.diffuse_transmission_texture);
        }
        if (p.is(i, "diffuseTransmissionColorFactor")) {
            return try p.floatArray(i + 1, &out.diffuse_transmission_color_factor);
        }
        if (p.is(i, "diffuseTransmissionColorTexture")) {
            return try p.textureView(i + 1, &out.diffuse_transmission_color_texture);
        }
        return null;
    }

    fn anisotropyField(p: Parser, i: usize, out: *types.Anisotropy) Fail!?usize {
        if (p.is(i, "anisotropyStrength")) return p.floatField(i, &out.anisotropy_strength);
        if (p.is(i, "anisotropyRotation")) return p.floatField(i, &out.anisotropy_rotation);
        if (p.is(i, "anisotropyTexture")) return try p.textureView(i + 1, &out.anisotropy_texture);
        return null;
    }

    fn dispersionField(p: Parser, i: usize, out: *types.Dispersion) Fail!?usize {
        if (p.is(i, "dispersion")) return p.floatField(i, &out.dispersion);
        return null;
    }

    fn image(p: Parser, start: usize, out: *types.Image) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "uri")) {
                i = try p.string(i + 1, &out.uri);
            } else if (p.is(i, "bufferView")) {
                i += 1;
                out.buffer_view = p.ref(i);
                i += 1;
            } else if (p.is(i, "mimeType")) {
                i = try p.string(i + 1, &out.mime_type);
            } else if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn sampler(p: Parser, start: usize, out: *types.Sampler) Fail!usize {
        try p.checkType(start, .object);
        out.wrap_s = .repeat;
        out.wrap_t = .repeat;
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "magFilter")) {
                out.mag_filter = @fromBackingInt(p.toInt(i + 1));
                i += 2;
            } else if (p.is(i, "minFilter")) {
                out.min_filter = @fromBackingInt(p.toInt(i + 1));
                i += 2;
            } else if (p.is(i, "wrapS")) {
                out.wrap_s = @fromBackingInt(p.toInt(i + 1));
                i += 2;
            } else if (p.is(i, "wrapT")) {
                out.wrap_t = @fromBackingInt(p.toInt(i + 1));
                i += 2;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    /// The `source` of a texture extension such as `KHR_texture_basisu`.
    fn textureSource(p: Parser, start: usize, out: *?u32) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var t: i32 = 0;
        while (t < size) : (t += 1) {
            try p.checkKey(i);
            if (p.is(i, "source")) {
                out.* = p.ref(i + 1);
                i += 2;
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn texture(p: Parser, start: usize, out: *types.Texture) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "sampler")) {
                out.sampler = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "source")) {
                out.image = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.extensions, &seen_extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "KHR_texture_basisu")) {
                        out.has_basisu = true;
                        i = try p.textureSource(i + 1, &out.basisu_image);
                    } else if (p.is(i, "EXT_texture_webp")) {
                        out.has_webp = true;
                        i = try p.textureSource(i + 1, &out.webp_image);
                    } else {
                        i = try p.keepExtension(i, &out.extensions);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn material(p: Parser, start: usize, out: *types.Material) Fail!usize {
        try p.checkType(start, .object);
        out.pbr_metallic_roughness.base_color_factor = @splat(1.0);
        out.pbr_metallic_roughness.metallic_factor = 1.0;
        out.pbr_metallic_roughness.roughness_factor = 1.0;
        out.pbr_specular_glossiness.diffuse_factor = @splat(1.0);
        out.pbr_specular_glossiness.specular_factor = @splat(1.0);
        out.pbr_specular_glossiness.glossiness_factor = 1.0;
        out.volume.attenuation_color = @splat(1.0);
        out.volume.attenuation_distance = std.math.floatMax(f32);
        out.alpha_cutoff = 0.5;

        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "pbrMetallicRoughness")) {
                out.has_pbr_metallic_roughness = true;
                i = try p.object(i + 1, &out.pbr_metallic_roughness, pbrMetallicRoughnessField);
            } else if (p.is(i, "emissiveFactor")) {
                i = try p.floatArray(i + 1, &out.emissive_factor);
            } else if (p.is(i, "normalTexture")) {
                i = try p.textureView(i + 1, &out.normal_texture);
            } else if (p.is(i, "occlusionTexture")) {
                i = try p.textureView(i + 1, &out.occlusion_texture);
            } else if (p.is(i, "emissiveTexture")) {
                i = try p.textureView(i + 1, &out.emissive_texture);
            } else if (p.is(i, "alphaMode")) {
                i += 1;
                if (p.is(i, "OPAQUE")) {
                    out.alpha_mode = .@"opaque";
                } else if (p.is(i, "MASK")) {
                    out.alpha_mode = .mask;
                } else if (p.is(i, "BLEND")) {
                    out.alpha_mode = .blend;
                }
                i += 1;
            } else if (p.is(i, "alphaCutoff")) {
                i = p.floatField(i, &out.alpha_cutoff);
            } else if (p.is(i, "doubleSided")) {
                out.double_sided = p.toBool(i + 1);
                i += 2;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.extensions, &seen_extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    i = try p.materialExtension(i, out);
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn materialExtension(p: Parser, i: usize, out: *types.Material) Fail!usize {
        if (p.is(i, "KHR_materials_pbrSpecularGlossiness")) {
            out.has_pbr_specular_glossiness = true;
            return p.object(i + 1, &out.pbr_specular_glossiness, pbrSpecularGlossinessField);
        }
        if (p.is(i, "KHR_materials_unlit")) {
            out.unlit = true;
            return p.skip(i + 1);
        }
        if (p.is(i, "KHR_materials_clearcoat")) {
            out.has_clearcoat = true;
            return p.object(i + 1, &out.clearcoat, clearcoatField);
        }
        if (p.is(i, "KHR_materials_ior")) {
            out.has_ior = true;
            try p.checkType(i + 1, .object);
            out.ior.ior = 1.5;
            return p.object(i + 1, &out.ior, iorField);
        }
        if (p.is(i, "KHR_materials_specular")) {
            out.has_specular = true;
            try p.checkType(i + 1, .object);
            out.specular.specular_factor = 1.0;
            out.specular.specular_color_factor = @splat(1.0);
            return p.object(i + 1, &out.specular, specularField);
        }
        if (p.is(i, "KHR_materials_transmission")) {
            out.has_transmission = true;
            return p.object(i + 1, &out.transmission, transmissionField);
        }
        if (p.is(i, "KHR_materials_volume")) {
            out.has_volume = true;
            return p.object(i + 1, &out.volume, volumeField);
        }
        if (p.is(i, "KHR_materials_sheen")) {
            out.has_sheen = true;
            return p.object(i + 1, &out.sheen, sheenField);
        }
        if (p.is(i, "KHR_materials_emissive_strength")) {
            out.has_emissive_strength = true;
            try p.checkType(i + 1, .object);
            out.emissive_strength.emissive_strength = 1.0;
            return p.object(i + 1, &out.emissive_strength, emissiveStrengthField);
        }
        if (p.is(i, "KHR_materials_iridescence")) {
            out.has_iridescence = true;
            try p.checkType(i + 1, .object);
            out.iridescence.iridescence_ior = 1.3;
            out.iridescence.iridescence_thickness_min = 100.0;
            out.iridescence.iridescence_thickness_max = 400.0;
            return p.object(i + 1, &out.iridescence, iridescenceField);
        }
        if (p.is(i, "KHR_materials_diffuse_transmission")) {
            out.has_diffuse_transmission = true;
            try p.checkType(i + 1, .object);
            out.diffuse_transmission.diffuse_transmission_color_factor = @splat(1.0);
            out.diffuse_transmission.diffuse_transmission_factor = 0.0;
            return p.object(i + 1, &out.diffuse_transmission, diffuseTransmissionField);
        }
        if (p.is(i, "KHR_materials_anisotropy")) {
            out.has_anisotropy = true;
            return p.object(i + 1, &out.anisotropy, anisotropyField);
        }
        if (p.is(i, "KHR_materials_dispersion")) {
            out.has_dispersion = true;
            return p.object(i + 1, &out.dispersion, dispersionField);
        }
        return p.keepExtension(i, &out.extensions);
    }

    fn meshoptCompression(p: Parser, start: usize, out: *types.MeshoptCompression) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "buffer")) {
                out.buffer = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "byteOffset")) {
                out.offset = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "byteLength")) {
                out.size = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "byteStride")) {
                out.stride = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "count")) {
                out.count = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "mode")) {
                i += 1;
                if (p.is(i, "ATTRIBUTES")) {
                    out.mode = .attributes;
                } else if (p.is(i, "TRIANGLES")) {
                    out.mode = .triangles;
                } else if (p.is(i, "INDICES")) {
                    out.mode = .indices;
                }
                i += 1;
            } else if (p.is(i, "filter")) {
                i += 1;
                if (p.is(i, "NONE")) {
                    out.filter = .none;
                } else if (p.is(i, "OCTAHEDRAL")) {
                    out.filter = .octahedral;
                } else if (p.is(i, "QUATERNION")) {
                    out.filter = .quaternion;
                } else if (p.is(i, "EXPONENTIAL")) {
                    out.filter = .exponential;
                } else if (p.is(i, "COLOR")) {
                    out.filter = .color;
                }
                i += 1;
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn bufferView(p: Parser, start: usize, out: *types.BufferView) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "buffer")) {
                out.buffer = p.refRequired(i + 1);
                i += 2;
            } else if (p.is(i, "byteOffset")) {
                out.offset = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "byteLength")) {
                out.size = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "byteStride")) {
                out.stride = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "target")) {
                out.type = switch (p.toInt(i + 1)) {
                    34962 => .vertices,
                    34963 => .indices,
                    else => .invalid,
                };
                i += 2;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.extensions, &seen_extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "EXT_meshopt_compression")) {
                        out.has_meshopt_compression = true;
                        i = try p.meshoptCompression(i + 1, &out.meshopt_compression);
                    } else if (p.is(i, "KHR_meshopt_compression")) {
                        out.has_meshopt_compression = true;
                        out.meshopt_compression.is_khr = true;
                        i = try p.meshoptCompression(i + 1, &out.meshopt_compression);
                    } else {
                        i = try p.keepExtension(i, &out.extensions);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn buffer(p: Parser, start: usize, out: *types.Buffer) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "byteLength")) {
                out.size = p.toSize(i + 1);
                i += 2;
            } else if (p.is(i, "uri")) {
                i = try p.string(i + 1, &out.uri);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    /// The elements of a JSON array of references.
    fn refs(p: Parser, start: usize, out: []u32) usize {
        var i = start;
        for (out) |*item| {
            item.* = p.refRequired(i);
            i += 1;
        }
        return i;
    }

    fn skin(p: Parser, start: usize, out: *types.Skin) Fail!usize {
        try p.checkType(start, .object);
        var seen: struct { joints: bool = false, extensions: bool = false } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "joints")) {
                i = try p.array(i + 1, u32, &out.joints, &seen.joints);
                i = p.refs(i, out.joints);
            } else if (p.is(i, "skeleton")) {
                try p.checkType(i + 1, .primitive);
                out.skeleton = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "inverseBindMatrices")) {
                try p.checkType(i + 1, .primitive);
                out.inverse_bind_matrices = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen.extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn perspectiveField(p: Parser, i: usize, out: *types.CameraPerspective) Fail!?usize {
        if (p.is(i, "aspectRatio")) {
            out.has_aspect_ratio = true;
            return p.floatField(i, &out.aspect_ratio);
        }
        if (p.is(i, "yfov")) return p.floatField(i, &out.yfov);
        if (p.is(i, "zfar")) {
            out.has_zfar = true;
            return p.floatField(i, &out.zfar);
        }
        if (p.is(i, "znear")) return p.floatField(i, &out.znear);
        if (p.is(i, "extras")) return try p.extras(i + 1, &out.extras);
        return null;
    }

    fn orthographicField(p: Parser, i: usize, out: *types.CameraOrthographic) Fail!?usize {
        if (p.is(i, "xmag")) return p.floatField(i, &out.xmag);
        if (p.is(i, "ymag")) return p.floatField(i, &out.ymag);
        if (p.is(i, "zfar")) return p.floatField(i, &out.zfar);
        if (p.is(i, "znear")) return p.floatField(i, &out.znear);
        if (p.is(i, "extras")) return try p.extras(i + 1, &out.extras);
        return null;
    }

    fn camera(p: Parser, start: usize, out: *types.Camera) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "perspective")) {
                try p.checkType(i + 1, .object);
                if (out.data != .invalid) return error.Json;
                out.data = .{ .perspective = .{} };
                i = try p.object(i + 1, &out.data.perspective, perspectiveField);
            } else if (p.is(i, "orthographic")) {
                try p.checkType(i + 1, .object);
                if (out.data != .invalid) return error.Json;
                out.data = .{ .orthographic = .{} };
                i = try p.object(i + 1, &out.data.orthographic, orthographicField);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn spotField(p: Parser, i: usize, out: *types.Light) Fail!?usize {
        if (p.is(i, "innerConeAngle")) return p.floatField(i, &out.spot_inner_cone_angle);
        if (p.is(i, "outerConeAngle")) return p.floatField(i, &out.spot_outer_cone_angle);
        return null;
    }

    fn light(p: Parser, start: usize, out: *types.Light) Fail!usize {
        try p.checkType(start, .object);
        out.color = @splat(1.0);
        out.intensity = 1.0;
        out.spot_inner_cone_angle = 0.0;
        out.spot_outer_cone_angle = 3.1415926535 / 4.0;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "color")) {
                i = try p.floatArray(i + 1, &out.color);
            } else if (p.is(i, "intensity")) {
                i = p.floatField(i, &out.intensity);
            } else if (p.is(i, "type")) {
                i += 1;
                if (p.is(i, "directional")) {
                    out.type = .directional;
                } else if (p.is(i, "point")) {
                    out.type = .point;
                } else if (p.is(i, "spot")) {
                    out.type = .spot;
                }
                i += 1;
            } else if (p.is(i, "range")) {
                i = p.floatField(i, &out.range);
            } else if (p.is(i, "spot")) {
                i = try p.object(i + 1, out, spotField);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn lightsPunctualField(p: Parser, i: usize, out: *types.Node) Fail!?usize {
        if (p.is(i, "light")) {
            try p.checkType(i + 1, .primitive);
            out.light = p.ref(i + 1);
            return i + 2;
        }
        return null;
    }

    fn node(p: Parser, start: usize, out: *types.Node) Fail!usize {
        try p.checkType(start, .object);
        out.rotation[3] = 1.0;
        out.scale = @splat(1.0);
        out.matrix[0] = 1.0;
        out.matrix[5] = 1.0;
        out.matrix[10] = 1.0;
        out.matrix[15] = 1.0;
        var seen: struct {
            children: bool = false,
            extensions: bool = false,
            instancing_attributes: bool = false,
        } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "children")) {
                i = try p.array(i + 1, u32, &out.children, &seen.children);
                i = p.refs(i, out.children);
            } else if (p.is(i, "mesh")) {
                try p.checkType(i + 1, .primitive);
                out.mesh = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "skin")) {
                try p.checkType(i + 1, .primitive);
                out.skin = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "camera")) {
                try p.checkType(i + 1, .primitive);
                out.camera = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "translation")) {
                out.has_translation = true;
                i = try p.floatArray(i + 1, &out.translation);
            } else if (p.is(i, "rotation")) {
                out.has_rotation = true;
                i = try p.floatArray(i + 1, &out.rotation);
            } else if (p.is(i, "scale")) {
                out.has_scale = true;
                i = try p.floatArray(i + 1, &out.scale);
            } else if (p.is(i, "matrix")) {
                out.has_matrix = true;
                i = try p.floatArray(i + 1, &out.matrix);
            } else if (p.is(i, "weights")) {
                i = try p.optionalArray(i + 1, f32, &out.weights);
                i = try p.floatArray(i - 1, out.weights.?);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.extensions, &seen.extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "KHR_lights_punctual")) {
                        i = try p.object(i + 1, out, lightsPunctualField);
                    } else if (p.is(i, "EXT_mesh_gpu_instancing")) {
                        out.has_mesh_gpu_instancing = true;
                        i = try p.meshGpuInstancing(
                            i + 1,
                            &out.mesh_gpu_instancing,
                            &seen.instancing_attributes,
                        );
                    } else {
                        i = try p.keepExtension(i, &out.extensions);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn scene(p: Parser, start: usize, out: *types.Scene) Fail!usize {
        try p.checkType(start, .object);
        var seen: struct { nodes: bool = false, extensions: bool = false } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "nodes")) {
                i = try p.array(i + 1, u32, &out.nodes, &seen.nodes);
                i = p.refs(i, out.nodes);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen.extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn animationSampler(p: Parser, start: usize, out: *types.AnimationSampler) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "input")) {
                out.input = p.refRequired(i + 1);
                i += 2;
            } else if (p.is(i, "output")) {
                out.output = p.refRequired(i + 1);
                i += 2;
            } else if (p.is(i, "interpolation")) {
                i += 1;
                if (p.is(i, "LINEAR")) {
                    out.interpolation = .linear;
                } else if (p.is(i, "STEP")) {
                    out.interpolation = .step;
                } else if (p.is(i, "CUBICSPLINE")) {
                    out.interpolation = .cubic_spline;
                }
                i += 1;
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn animationChannel(p: Parser, start: usize, out: *types.AnimationChannel) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "sampler")) {
                out.sampler = p.refRequired(i + 1);
                i += 2;
            } else if (p.is(i, "target")) {
                i += 1;
                try p.checkType(i, .object);
                const target_size = p.tokens[i].size;
                i += 1;
                var k: i32 = 0;
                while (k < target_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "node")) {
                        out.target_node = p.ref(i + 1);
                        i += 2;
                    } else if (p.is(i, "path")) {
                        i += 1;
                        if (p.is(i, "translation")) {
                            out.target_path = .translation;
                        } else if (p.is(i, "rotation")) {
                            out.target_path = .rotation;
                        } else if (p.is(i, "scale")) {
                            out.target_path = .scale;
                        } else if (p.is(i, "weights")) {
                            out.target_path = .weights;
                        }
                        i += 1;
                    } else if (p.is(i, "extras")) {
                        i = try p.extras(i + 1, &out.extras);
                    } else if (p.is(i, "extensions")) {
                        i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
                    } else {
                        i = try p.skip(i + 1);
                    }
                }
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn animation(p: Parser, start: usize, out: *types.Animation) Fail!usize {
        try p.checkType(start, .object);
        var seen: struct {
            samplers: bool = false,
            channels: bool = false,
            extensions: bool = false,
        } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "name")) {
                i = try p.string(i + 1, &out.name);
            } else if (p.is(i, "samplers")) {
                i = try p.array(i + 1, types.AnimationSampler, &out.samplers, &seen.samplers);
                for (out.samplers) |*item| i = try p.animationSampler(i, item);
            } else if (p.is(i, "channels")) {
                i = try p.array(i + 1, types.AnimationChannel, &out.channels, &seen.channels);
                for (out.channels) |*item| i = try p.animationChannel(i, item);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen.extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    fn variantField(p: Parser, i: usize, out: *types.MaterialVariant) Fail!?usize {
        if (p.is(i, "name")) return try p.string(i + 1, &out.name);
        if (p.is(i, "extras")) return try p.extras(i + 1, &out.extras);
        return null;
    }

    fn asset(p: Parser, start: usize, out: *types.Asset) Fail!usize {
        try p.checkType(start, .object);
        var seen_extensions = false;
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "copyright")) {
                i = try p.string(i + 1, &out.copyright);
            } else if (p.is(i, "generator")) {
                i = try p.string(i + 1, &out.generator);
            } else if (p.is(i, "version")) {
                i = try p.string(i + 1, &out.version);
            } else if (p.is(i, "minVersion")) {
                i = try p.string(i + 1, &out.min_version);
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i = try p.unprocessedExtensions(i, &out.extensions, &seen_extensions);
            } else {
                i = try p.skip(i + 1);
            }
        }
        if (out.version) |version| {
            if (number.atof(version) < 2) return error.Legacy;
        }
        return i;
    }

    /// A top-level array of objects, each read by `item`.
    fn objects(
        p: Parser,
        i: usize,
        comptime T: type,
        out: *[]T,
        seen: *bool,
        comptime item: fn (Parser, usize, *T) Fail!usize,
    ) Fail!usize {
        var next = try p.array(i, T, out, seen);
        for (out.*) |*element| next = try item(p, next, element);
        return next;
    }

    fn variantObject(p: Parser, i: usize, out: *types.MaterialVariant) Fail!usize {
        return p.object(i, out, variantField);
    }

    fn root(p: Parser, start: usize, out: *Gltf) Fail!usize {
        try p.checkType(start, .object);
        var seen: struct {
            meshes: bool = false,
            accessors: bool = false,
            buffer_views: bool = false,
            buffers: bool = false,
            materials: bool = false,
            images: bool = false,
            textures: bool = false,
            samplers: bool = false,
            skins: bool = false,
            cameras: bool = false,
            nodes: bool = false,
            scenes: bool = false,
            animations: bool = false,
            lights: bool = false,
            variants: bool = false,
            extensions: bool = false,
            extensions_used: bool = false,
            extensions_required: bool = false,
        } = .{};
        const size = p.tokens[start].size;
        var i = start + 1;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            try p.checkKey(i);
            if (p.is(i, "asset")) {
                i = try p.asset(i + 1, &out.asset);
            } else if (p.is(i, "meshes")) {
                i = try p.objects(i + 1, types.Mesh, &out.meshes, &seen.meshes, mesh);
            } else if (p.is(i, "accessors")) {
                i = try p.objects(i + 1, types.Accessor, &out.accessors, &seen.accessors, accessor);
            } else if (p.is(i, "bufferViews")) {
                i = try p.objects(
                    i + 1,
                    types.BufferView,
                    &out.buffer_views,
                    &seen.buffer_views,
                    bufferView,
                );
            } else if (p.is(i, "buffers")) {
                i = try p.objects(i + 1, types.Buffer, &out.buffers, &seen.buffers, buffer);
            } else if (p.is(i, "materials")) {
                i = try p.objects(i + 1, types.Material, &out.materials, &seen.materials, material);
            } else if (p.is(i, "images")) {
                i = try p.objects(i + 1, types.Image, &out.images, &seen.images, image);
            } else if (p.is(i, "textures")) {
                i = try p.objects(i + 1, types.Texture, &out.textures, &seen.textures, texture);
            } else if (p.is(i, "samplers")) {
                i = try p.objects(i + 1, types.Sampler, &out.samplers, &seen.samplers, sampler);
            } else if (p.is(i, "skins")) {
                i = try p.objects(i + 1, types.Skin, &out.skins, &seen.skins, skin);
            } else if (p.is(i, "cameras")) {
                i = try p.objects(i + 1, types.Camera, &out.cameras, &seen.cameras, camera);
            } else if (p.is(i, "nodes")) {
                i = try p.objects(i + 1, types.Node, &out.nodes, &seen.nodes, node);
            } else if (p.is(i, "scenes")) {
                i = try p.objects(i + 1, types.Scene, &out.scenes, &seen.scenes, scene);
            } else if (p.is(i, "scene")) {
                out.scene = p.ref(i + 1);
                i += 2;
            } else if (p.is(i, "animations")) {
                i = try p.objects(
                    i + 1,
                    types.Animation,
                    &out.animations,
                    &seen.animations,
                    animation,
                );
            } else if (p.is(i, "extras")) {
                i = try p.extras(i + 1, &out.extras);
            } else if (p.is(i, "extensions")) {
                i += 1;
                const extensions_size = p.tokens[i].size;
                i = try p.extensionsObject(i, &out.data_extensions, &seen.extensions);
                var k: i32 = 0;
                while (k < extensions_size) : (k += 1) {
                    try p.checkKey(i);
                    if (p.is(i, "KHR_lights_punctual")) {
                        i = try p.namedArray(i + 1, "lights", types.Light, &out.lights, &seen.lights, light);
                    } else if (p.is(i, "KHR_materials_variants")) {
                        i = try p.namedArray(
                            i + 1,
                            "variants",
                            types.MaterialVariant,
                            &out.variants,
                            &seen.variants,
                            variantObject,
                        );
                    } else {
                        i = try p.keepExtension(i, &out.data_extensions);
                    }
                }
            } else if (p.is(i, "extensionsUsed")) {
                i = try p.stringArray(i + 1, &out.extensions_used, &seen.extensions_used);
            } else if (p.is(i, "extensionsRequired")) {
                i = try p.stringArray(i + 1, &out.extensions_required, &seen.extensions_required);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }

    /// An extension object whose key `name` holds an array of objects, as
    /// `KHR_lights_punctual`'s `lights`.
    fn namedArray(
        p: Parser,
        start: usize,
        comptime name: []const u8,
        comptime T: type,
        out: *[]T,
        seen: *bool,
        comptime item: fn (Parser, usize, *T) Fail!usize,
    ) Fail!usize {
        try p.checkType(start, .object);
        const size = p.tokens[start].size;
        var i = start + 1;
        var m: i32 = 0;
        while (m < size) : (m += 1) {
            try p.checkKey(i);
            if (p.is(i, name)) {
                i = try p.objects(i + 1, T, out, seen, item);
            } else {
                i = try p.skip(i + 1);
            }
        }
        return i;
    }
};

/// cgltf's calloc: every field zero, every reference absent.
fn zeroed(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => .{},
        .float => 0,
        .int => invalid_index,
        .optional => null,
        else => @compileError("no zero value for " ++ @typeName(T)),
    };
}

fn componentType(value: i32) types.ComponentType {
    return switch (value) {
        5120 => .r_8,
        5121 => .r_8u,
        5122 => .r_16,
        5123 => .r_16u,
        5125 => .r_32u,
        5126 => .r_32f,
        else => .invalid,
    };
}

/// `cgltf_parse_attribute_type`: the semantic before the underscore and
/// the set number after it.
fn parseAttributeType(name: []const u8, out_type: *types.AttributeType, out_index: *i32) void {
    if (name.len > 0 and name[0] == '_') {
        out_type.* = .custom;
        return;
    }
    const underscore = std.mem.indexOfScalar(u8, name, '_');
    const semantic = name[0 .. underscore orelse name.len];
    const table = [_]struct { []const u8, types.AttributeType }{
        .{ "POSITION", .position },
        .{ "NORMAL", .normal },
        .{ "TANGENT", .tangent },
        .{ "TEXCOORD", .texcoord },
        .{ "COLOR", .color },
        .{ "JOINTS", .joints },
        .{ "WEIGHTS", .weights },
    };
    out_type.* = .invalid;
    for (table) |entry| {
        if (std.mem.eql(u8, semantic, entry[0])) out_type.* = entry[1];
    }
    if (underscore) |at| {
        if (out_type.* != .invalid) {
            out_index.* = number.atoi(name[at + 1 ..]);
            if (out_index.* < 0) {
                out_type.* = .invalid;
                out_index.* = 0;
            }
        }
    }
}

const FixupError = error{Invalid};

fn check(index: ?u32, count: usize) FixupError!void {
    if (index) |value| {
        if (value >= count) return error.Invalid;
    }
}

/// `cgltf_fixup_pointers`: every reference within its array, each node a
/// child of at most one parent and no scene root a child, and each
/// accessor's stride.
fn fixup(gltf: *Gltf) FixupError!void {
    const accessors = gltf.accessors.len;
    const materials = gltf.materials.len;
    const buffer_views = gltf.buffer_views.len;
    for (gltf.meshes) |*mesh| {
        for (mesh.primitives) |*prim| {
            try check(prim.indices, accessors);
            try check(prim.material, materials);
            for (prim.attributes) |attribute| try check(attribute.data, accessors);
            for (prim.targets) |target| {
                for (target.attributes) |attribute| try check(attribute.data, accessors);
            }
            if (prim.has_draco_mesh_compression) {
                const draco = prim.draco_mesh_compression;
                try check(draco.buffer_view orelse invalid_index, buffer_views);
                for (draco.attributes) |attribute| try check(attribute.data, accessors);
            }
            for (prim.mappings) |mapping| try check(mapping.material, materials);
        }
    }
    for (gltf.accessors) |*accessor| {
        try check(accessor.buffer_view, buffer_views);
        if (accessor.is_sparse) {
            try check(accessor.sparse.indices_buffer_view orelse invalid_index, buffer_views);
            try check(accessor.sparse.values_buffer_view orelse invalid_index, buffer_views);
        }
        if (accessor.buffer_view) |view| accessor.stride = gltf.buffer_views[view].stride;
        if (accessor.stride == 0) accessor.stride = cgltf.calcSize(accessor.type, accessor.component_type);
    }
    const images = gltf.images.len;
    for (gltf.textures) |texture| {
        try check(texture.image, images);
        try check(texture.basisu_image, images);
        try check(texture.webp_image, images);
        try check(texture.sampler, gltf.samplers.len);
    }
    for (gltf.images) |image| try check(image.buffer_view, buffer_views);
    const textures = gltf.textures.len;
    for (gltf.materials) |material| {
        const views = [_]types.TextureView{
            material.normal_texture,
            material.emissive_texture,
            material.occlusion_texture,
            material.pbr_metallic_roughness.base_color_texture,
            material.pbr_metallic_roughness.metallic_roughness_texture,
            material.pbr_specular_glossiness.diffuse_texture,
            material.pbr_specular_glossiness.specular_glossiness_texture,
            material.clearcoat.clearcoat_texture,
            material.clearcoat.clearcoat_roughness_texture,
            material.clearcoat.clearcoat_normal_texture,
            material.specular.specular_texture,
            material.specular.specular_color_texture,
            material.transmission.transmission_texture,
            material.volume.thickness_texture,
            material.sheen.sheen_color_texture,
            material.sheen.sheen_roughness_texture,
            material.iridescence.iridescence_texture,
            material.iridescence.iridescence_thickness_texture,
            material.diffuse_transmission.diffuse_transmission_texture,
            material.diffuse_transmission.diffuse_transmission_color_texture,
            material.anisotropy.anisotropy_texture,
        };
        for (views) |view| try check(view.texture, textures);
    }
    const buffers = gltf.buffers.len;
    for (gltf.buffer_views) |view| {
        try check(view.buffer, buffers);
        if (view.has_meshopt_compression) {
            try check(view.meshopt_compression.buffer orelse invalid_index, buffers);
        }
    }
    const nodes = gltf.nodes.len;
    for (gltf.skins) |skin| {
        for (skin.joints) |joint| try check(joint, nodes);
        try check(skin.skeleton, nodes);
        try check(skin.inverse_bind_matrices, accessors);
    }
    for (gltf.nodes, 0..) |*node, n| {
        for (node.children) |child| {
            try check(child, nodes);
            const child_node = &gltf.nodes[child];
            if (child_node.parent != null) return error.Invalid;
            child_node.parent = @intCast(n);
        }
        try check(node.mesh, gltf.meshes.len);
        try check(node.skin, gltf.skins.len);
        try check(node.camera, gltf.cameras.len);
        try check(node.light, gltf.lights.len);
        if (node.has_mesh_gpu_instancing) {
            for (node.mesh_gpu_instancing.attributes) |attribute| try check(attribute.data, accessors);
        }
    }
    for (gltf.scenes) |scene| {
        for (scene.nodes) |root_node| {
            try check(root_node, nodes);
            if (gltf.nodes[root_node].parent != null) return error.Invalid;
        }
    }
    try check(gltf.scene, gltf.scenes.len);
    for (gltf.animations) |animation| {
        for (animation.samplers) |sampler| {
            try check(sampler.input, accessors);
            try check(sampler.output, accessors);
        }
        for (animation.channels) |channel| {
            try check(channel.sampler, animation.samplers.len);
            try check(channel.target_node, nodes);
        }
    }
}
