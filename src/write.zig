//! cgltf's writer, `cgltf_write.h`: a `Gltf` as glTF JSON text, laid out
//! as cgltf lays it out, two spaces to a level, with the extensions it
//! knows and the extras' JSON as it was read; and that text in a `.gltf`
//! or a GLB file.

const std = @import("std");
const Io = std.Io;

const cgltf = @import("cgltf.zig");
const number = @import("number.zig");
const types = @import("types.zig");
const Gltf = cgltf.Gltf;
const invalid_index = types.invalid_index;

/// A failed write, or extras whose offsets lie outside the JSON text,
/// which cgltf would read past.
pub const WriteError = Io.Writer.Error || error{OutOfBounds};

/// cgltf's `cgltf_write`: the glTF JSON text of `gltf` to `out`, without
/// the NUL cgltf adds. cgltf's size query, with no buffer, is the byte
/// count a `std.Io.Writer.Discarding` takes, plus one for that NUL.
pub fn write(gltf: *const Gltf, out: *Io.Writer) WriteError!void {
    var context: Context = .{ .out = out, .gltf = gltf };
    const c = &context;
    try out.writeAll("{");

    if (gltf.accessors.len > 0) {
        try c.line("\"accessors\": [");
        for (gltf.accessors) |*accessor| try c.writeAccessor(accessor);
        try c.line("]");
    }
    try c.writeAsset(&gltf.asset);
    if (gltf.buffer_views.len > 0) {
        try c.line("\"bufferViews\": [");
        for (gltf.buffer_views) |*view| try c.writeBufferView(view);
        try c.line("]");
    }
    if (gltf.buffers.len > 0) {
        try c.line("\"buffers\": [");
        for (gltf.buffers) |*buffer| try c.writeBuffer(buffer);
        try c.line("]");
    }
    if (gltf.images.len > 0) {
        try c.line("\"images\": [");
        for (gltf.images) |*image| try c.writeImage(image);
        try c.line("]");
    }
    if (gltf.meshes.len > 0) {
        try c.line("\"meshes\": [");
        for (gltf.meshes) |*mesh| try c.writeMesh(mesh);
        try c.line("]");
    }
    if (gltf.materials.len > 0) {
        try c.line("\"materials\": [");
        for (gltf.materials) |*material| try c.writeMaterial(material);
        try c.line("]");
    }
    if (gltf.nodes.len > 0) {
        try c.line("\"nodes\": [");
        for (gltf.nodes) |*node| try c.writeNode(node);
        try c.line("]");
    }
    if (gltf.samplers.len > 0) {
        try c.line("\"samplers\": [");
        for (gltf.samplers) |*sampler| try c.writeSampler(sampler);
        try c.line("]");
    }
    try c.indexProp("scene", gltf.scene);
    if (gltf.scenes.len > 0) {
        try c.line("\"scenes\": [");
        for (gltf.scenes) |*scene| try c.writeScene(scene);
        try c.line("]");
    }
    if (gltf.textures.len > 0) {
        try c.line("\"textures\": [");
        for (gltf.textures) |*texture| try c.writeTexture(texture);
        try c.line("]");
    }
    if (gltf.skins.len > 0) {
        try c.line("\"skins\": [");
        for (gltf.skins) |*skin| try c.writeSkin(skin);
        try c.line("]");
    }
    if (gltf.animations.len > 0) {
        try c.line("\"animations\": [");
        for (gltf.animations) |*animation| try c.writeAnimation(animation);
        try c.line("]");
    }
    if (gltf.cameras.len > 0) {
        try c.line("\"cameras\": [");
        for (gltf.cameras) |*camera| try c.writeCamera(camera);
        try c.line("]");
    }
    if (gltf.lights.len > 0 or gltf.variants.len > 0) {
        try c.line("\"extensions\": {");
        if (gltf.lights.len > 0) {
            try c.line("\"KHR_lights_punctual\": {");
            try c.line("\"lights\": [");
            for (gltf.lights) |*light| try c.writeLight(light);
            try c.line("]");
            try c.line("}");
        }
        if (gltf.variants.len > 0) {
            try c.line("\"KHR_materials_variants\": {");
            try c.line("\"variants\": [");
            for (gltf.variants) |*variant| try c.writeVariant(variant);
            try c.line("]");
            try c.line("}");
        }
        try c.line("}");
    }
    if (c.extensions_used.count() != 0) {
        try c.line("\"extensionsUsed\": [");
        try c.writeExtensions(c.extensions_used);
        try c.line("]");
    }
    if (c.extensions_required.count() != 0) {
        try c.line("\"extensionsRequired\": [");
        try c.writeExtensions(c.extensions_required);
        try c.line("]");
    }
    try c.writeExtras(&gltf.extras);
    try out.writeAll("\n}\n");
}

/// cgltf's `cgltf_write_file`: writes `gltf` to the file at `path`, as
/// glTF JSON or, for `.glb`, as a GLB with the JSON and `gltf.bin` as its
/// chunks. The JSON is written twice, once to count its bytes for the GLB
/// header and once to the file, as cgltf writes it.
pub fn writeFile(
    gltf: *const Gltf,
    io: Io,
    path: []const u8,
    file_type: types.FileType,
) cgltf.Error!void {
    const file = Io.Dir.cwd().createFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;
    writeFileTo(gltf, out, file_type) catch |err| return switch (err) {
        error.OutOfBounds => error.OutOfBounds,
        error.WriteFailed => error.IoError,
    };
    out.flush() catch return error.IoError;
}

fn writeFileTo(gltf: *const Gltf, out: *Io.Writer, file_type: types.FileType) WriteError!void {
    if (file_type != .glb) return write(gltf, out);

    var counter: Io.Writer.Discarding = .init(&.{});
    try write(gltf, &counter.writer);
    const json_size: usize = @intCast(counter.fullCount());
    const bin = gltf.bin orelse &.{};
    const json_pad = (4 - json_size % 4) % 4;
    const bin_pad = (4 - bin.len % 4) % 4;
    var total = glb_header_size + glb_chunk_header_size + json_size + json_pad;
    if (bin.len > 0) total += glb_chunk_header_size + bin.len + bin_pad;

    // cgltf copies the low four bytes of each size, in the machine's order.
    try out.writeInt(u32, glb_magic, .native);
    try out.writeInt(u32, glb_version, .native);
    try out.writeInt(u32, @truncate(total), .native);
    try out.writeInt(u32, @truncate(json_size + json_pad), .native);
    try out.writeInt(u32, glb_magic_json_chunk, .native);
    try write(gltf, out);
    try out.splatByteAll(' ', json_pad);
    if (bin.len > 0) {
        try out.writeInt(u32, @truncate(bin.len + bin_pad), .native);
        try out.writeInt(u32, glb_magic_bin_chunk, .native);
        try out.writeAll(bin);
        try out.splatByteAll(0, bin_pad);
    }
}

const glb_header_size = 12;
const glb_chunk_header_size = 8;
const glb_version: u32 = 2;
const glb_magic: u32 = 0x46546C67;
const glb_magic_json_chunk: u32 = 0x4E4F534A;
const glb_magic_bin_chunk: u32 = 0x004E4942;

/// The extensions a write met, in the order cgltf lists them.
const Extension = enum {
    texture_transform,
    materials_unlit,
    specular_glossiness,
    lights_punctual,
    draco_mesh_compression,
    materials_clearcoat,
    materials_ior,
    materials_specular,
    materials_transmission,
    materials_sheen,
    materials_variants,
    materials_volume,
    texture_basisu,
    texture_webp,
    materials_emissive_strength,
    materials_iridescence,
    materials_diffuse_transmission,
    materials_anisotropy,
    mesh_gpu_instancing,
    materials_dispersion,

    fn name(extension: Extension) []const u8 {
        return switch (extension) {
            .texture_transform => "KHR_texture_transform",
            .materials_unlit => "KHR_materials_unlit",
            .specular_glossiness => "KHR_materials_pbrSpecularGlossiness",
            .lights_punctual => "KHR_lights_punctual",
            .draco_mesh_compression => "KHR_draco_mesh_compression",
            .materials_clearcoat => "KHR_materials_clearcoat",
            .materials_ior => "KHR_materials_ior",
            .materials_specular => "KHR_materials_specular",
            .materials_transmission => "KHR_materials_transmission",
            .materials_sheen => "KHR_materials_sheen",
            .materials_variants => "KHR_materials_variants",
            .materials_volume => "KHR_materials_volume",
            .texture_basisu => "KHR_texture_basisu",
            .texture_webp => "EXT_texture_webp",
            .materials_emissive_strength => "KHR_materials_emissive_strength",
            .materials_iridescence => "KHR_materials_iridescence",
            .materials_diffuse_transmission => "KHR_materials_diffuse_transmission",
            .materials_anisotropy => "KHR_materials_anisotropy",
            .mesh_gpu_instancing => "EXT_mesh_gpu_instancing",
            .materials_dispersion => "KHR_materials_dispersion",
        };
    }
};

const ExtensionSet = std.EnumSet(Extension);

/// C's `int` from a value cgltf casts to one: its low 32 bits.
fn cInt(value: usize) i32 {
    return @bitCast(@as(u32, @truncate(value)));
}

/// The text of a C string: up to its first NUL.
fn cString(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, 0) orelse text.len];
}

const indent_levels = 32;
/// A comma, a new line and the spaces of `indent_levels` levels, and one
/// space more, so that a block of `indent_text.len - 1` bytes can start at
/// the comma or at the new line.
const indent_text = ",\n" ++ @as([2 * indent_levels + 1]u8, @splat(' '));

const Context = struct {
    out: *Io.Writer,
    gltf: *const Gltf,
    depth: i32 = 1,
    needs_comma: bool = false,
    extensions_used: ExtensionSet = .empty,
    extensions_required: ExtensionSet = .empty,

    /// A comma when one is due, a new line, and two spaces a level. Up to
    /// `indent_levels` levels, with room in the writer's buffer, it copies
    /// a fixed-size block and keeps the part that counts.
    fn indent(c: *Context) WriteError!void {
        const levels: usize = @intCast(@max(c.depth, 0));
        const start: usize = if (c.needs_comma) 0 else 1;
        c.needs_comma = false;
        const block = indent_text.len - 1;
        const unused = c.out.unusedCapacitySlice();
        if (levels <= indent_levels and unused.len >= block) {
            unused[0..block].* = indent_text[start..][0..block].*;
            c.out.advance(2 + 2 * levels - start);
            return;
        }
        const shown = @min(levels, indent_levels);
        try c.out.writeAll(indent_text[start .. 2 + 2 * shown]);
        if (levels > shown) try c.out.splatBytesAll("  ", levels - shown);
    }

    /// A line of its own: one that starts with a closing bracket ends a
    /// level, and one that ends with an opening bracket starts one.
    fn line(c: *Context, comptime text: []const u8) WriteError!void {
        const closes = text[0] == ']' or text[0] == '}';
        if (closes) {
            c.depth -= 1;
            c.needs_comma = false;
        }
        try c.indent();
        try c.out.writeAll(text);
        if (closes) c.needs_comma = true;
        const last = text[text.len - 1];
        if (last == '[' or last == '{') {
            c.depth += 1;
            c.needs_comma = false;
        }
    }

    /// Opens a property: a new line, then the label in quotes.
    fn label(c: *Context, name: []const u8) WriteError!void {
        try c.indent();
        try c.out.print("\"{s}\": ", .{cString(name)});
    }

    fn strProp(c: *Context, name: []const u8, value: ?[]const u8) WriteError!void {
        const text = value orelse return;
        try c.label(name);
        try c.out.print("\"{s}\"", .{cString(text)});
        c.needs_comma = true;
    }

    fn strItem(c: *Context, item: []const u8) WriteError!void {
        try c.indent();
        try c.out.print("\"{s}\"", .{item});
        c.needs_comma = true;
    }

    fn intProp(c: *Context, name: []const u8, value: i32, default: i32) WriteError!void {
        if (value == default) return;
        try c.label(name);
        try c.out.print("{d}", .{value});
        c.needs_comma = true;
    }

    fn sizeProp(c: *Context, name: []const u8, value: usize, default: usize) WriteError!void {
        if (value == default) return;
        try c.label(name);
        try c.out.print("{d}", .{value});
        c.needs_comma = true;
    }

    /// A `size_t` property cgltf passes through an `int` first.
    fn sizePropFromInt(
        c: *Context,
        name: []const u8,
        value: usize,
        default: usize,
    ) WriteError!void {
        const sign_extended: usize = @bitCast(@as(isize, cInt(value)));
        try c.sizeProp(name, sign_extended, default);
    }

    fn boolProp(c: *Context, name: []const u8, value: bool, default: bool) WriteError!void {
        if (value == default) return;
        try c.label(name);
        try c.out.writeAll(if (value) "true" else "false");
        c.needs_comma = true;
    }

    fn float(c: *Context, value: f32) WriteError!void {
        var buffer: [number.float_text_max]u8 = undefined;
        try c.out.writeAll(number.formatFloat(&buffer, value));
    }

    fn floatProp(c: *Context, name: []const u8, value: f32, default: f32) WriteError!void {
        if (value == default) return;
        try c.label(name);
        try c.float(value);
        c.needs_comma = true;
    }

    fn floatArrayProp(c: *Context, name: []const u8, values: []const f32) WriteError!void {
        try c.label(name);
        try c.out.writeAll("[");
        for (values, 0..) |value, i| {
            if (i != 0) try c.out.writeAll(", ");
            try c.float(value);
        }
        try c.out.writeAll("]");
        c.needs_comma = true;
    }

    /// cgltf's `cgltf_check_floatarray`: whether any value differs from
    /// `default`, so that the array is written.
    fn differs(values: []const f32, default: f32) bool {
        for (values) |value| {
            if (value != default) return true;
        }
        return false;
    }

    fn indexProp(c: *Context, name: []const u8, index: ?u32) WriteError!void {
        const i = index orelse return;
        if (i == invalid_index) return;
        try c.label(name);
        try c.out.print("{d}", .{cInt(i)});
        c.needs_comma = true;
    }

    fn indexArrayProp(c: *Context, name: []const u8, indices: ?[]const u32) WriteError!void {
        const items = indices orelse return;
        try c.label(name);
        try c.out.writeAll("[");
        // cgltf counts in an `int`.
        const count: usize = @intCast(@max(cInt(items.len), 0));
        for (items[0..count], 0..) |index, i| {
            if (i != 0) try c.out.writeAll(",");
            try c.out.print(" {d}", .{cInt(index)});
        }
        try c.out.writeAll(" ]");
        c.needs_comma = true;
    }

    fn writeExtras(c: *Context, extras: *const types.Extras) WriteError!void {
        if (extras.data) |data| {
            try c.label("extras");
            try c.out.writeAll(cString(data));
            c.needs_comma = true;
            return;
        }
        const json = c.gltf.json;
        if (extras.end_offset == extras.start_offset or json.len == 0) return;
        if (extras.end_offset < extras.start_offset or extras.end_offset > json.len) {
            return error.OutOfBounds;
        }
        try c.label("extras");
        try c.out.writeAll(cString(json[extras.start_offset..extras.end_offset]));
        c.needs_comma = true;
    }

    fn writeExtensions(c: *Context, set: ExtensionSet) WriteError!void {
        for (std.enums.values(Extension)) |extension| {
            if (set.contains(extension)) try c.strItem(extension.name());
        }
    }

    fn textureView(
        c: *Context,
        comptime name: []const u8,
        comptime scale: ?[]const u8,
        view: *const types.TextureView,
    ) WriteError!void {
        if (view.texture == null) return;
        try c.line("\"" ++ name ++ "\": {");
        try c.indexProp("index", view.texture);
        try c.intProp("texCoord", view.texcoord, 0);
        if (scale) |scale_name| try c.floatProp(scale_name, view.scale, 1.0);
        if (view.has_transform) {
            c.extensions_used.insert(.texture_transform);
            try c.writeTextureTransform(&view.transform);
        }
        try c.line("}");
    }

    fn writeTextureTransform(
        c: *Context,
        transform: *const types.TextureTransform,
    ) WriteError!void {
        try c.line("\"extensions\": {");
        try c.line("\"KHR_texture_transform\": {");
        if (differs(&transform.offset, 0.0)) try c.floatArrayProp("offset", &transform.offset);
        try c.floatProp("rotation", transform.rotation, 0.0);
        if (differs(&transform.scale, 1.0)) try c.floatArrayProp("scale", &transform.scale);
        if (transform.has_texcoord) try c.intProp("texCoord", transform.texcoord, -1);
        try c.line("}");
        try c.line("}");
    }

    fn writeAsset(c: *Context, asset: *const types.Asset) WriteError!void {
        try c.line("\"asset\": {");
        try c.strProp("copyright", asset.copyright);
        try c.strProp("generator", asset.generator);
        try c.strProp("version", asset.version);
        try c.strProp("min_version", asset.min_version);
        try c.writeExtras(&asset.extras);
        try c.line("}");
    }

    fn attributes(c: *Context, items: []const types.Attribute) WriteError!void {
        for (items) |attribute| try c.indexProp(attribute.name, attribute.data);
    }

    fn writePrimitive(c: *Context, primitive: *const types.Primitive) WriteError!void {
        const mode: i32 = switch (primitive.type) {
            .points => 0,
            .lines => 1,
            .line_loop => 2,
            .line_strip => 3,
            .triangles => 4,
            .triangle_strip => 5,
            .triangle_fan => 6,
            .invalid => -1,
        };
        try c.intProp("mode", mode, 4);
        try c.indexProp("indices", primitive.indices);
        try c.indexProp("material", primitive.material);
        try c.line("\"attributes\": {");
        try c.attributes(primitive.attributes);
        try c.line("}");
        if (primitive.targets.len > 0) {
            try c.line("\"targets\": [");
            for (primitive.targets) |target| {
                try c.line("{");
                try c.attributes(target.attributes);
                try c.line("}");
            }
            try c.line("]");
        }
        try c.writeExtras(&primitive.extras);

        if (!primitive.has_draco_mesh_compression and primitive.mappings.len == 0) return;
        try c.line("\"extensions\": {");
        if (primitive.has_draco_mesh_compression) {
            c.extensions_used.insert(.draco_mesh_compression);
            if (primitive.attributes.len == 0 or primitive.indices == null) {
                c.extensions_required.insert(.draco_mesh_compression);
            }
            try c.line("\"KHR_draco_mesh_compression\": {");
            try c.indexProp("bufferView", primitive.draco_mesh_compression.buffer_view);
            try c.line("\"attributes\": {");
            try c.attributes(primitive.draco_mesh_compression.attributes);
            try c.line("}");
            try c.line("}");
        }
        if (primitive.mappings.len > 0) {
            c.extensions_used.insert(.materials_variants);
            try c.line("\"KHR_materials_variants\": {");
            try c.line("\"mappings\": [");
            for (primitive.mappings) |*mapping| {
                try c.line("{");
                try c.indexProp("material", mapping.material);
                try c.indent();
                try c.out.print("\"variants\": [{d}]", .{cInt(mapping.variant)});
                c.needs_comma = true;
                try c.writeExtras(&mapping.extras);
                try c.line("}");
            }
            try c.line("]");
            try c.line("}");
        }
        try c.line("}");
    }

    fn writeMesh(c: *Context, mesh: *const types.Mesh) WriteError!void {
        try c.line("{");
        try c.strProp("name", mesh.name);
        try c.line("\"primitives\": [");
        for (mesh.primitives) |*primitive| {
            try c.line("{");
            try c.writePrimitive(primitive);
            try c.line("}");
        }
        try c.line("]");
        if (mesh.weights) |weights| {
            if (weights.len > 0) try c.floatArrayProp("weights", weights);
        }
        try c.writeExtras(&mesh.extras);
        try c.line("}");
    }

    fn writeBufferView(c: *Context, view: *const types.BufferView) WriteError!void {
        try c.line("{");
        try c.strProp("name", view.name);
        try c.indexProp("buffer", view.buffer);
        try c.sizeProp("byteLength", view.size, std.math.maxInt(usize));
        try c.sizeProp("byteOffset", view.offset, 0);
        try c.sizeProp("byteStride", view.stride, 0);
        // cgltf leaves out `target`: glTF lets a reader infer it.
        try c.writeExtras(&view.extras);
        try c.line("}");
    }

    fn writeBuffer(c: *Context, buffer: *const types.Buffer) WriteError!void {
        try c.line("{");
        try c.strProp("name", buffer.name);
        try c.strProp("uri", buffer.uri);
        try c.sizeProp("byteLength", buffer.size, std.math.maxInt(usize));
        try c.writeExtras(&buffer.extras);
        try c.line("}");
    }

    fn writeMaterial(c: *Context, material: *const types.Material) WriteError!void {
        try c.line("{");
        try c.strProp("name", material.name);
        if (material.alpha_mode == .mask) {
            try c.floatProp("alphaCutoff", material.alpha_cutoff, 0.5);
        }
        try c.boolProp("doubleSided", material.double_sided, false);

        const flags = [_]struct { bool, Extension }{
            .{ material.unlit, .materials_unlit },
            .{ material.has_pbr_specular_glossiness, .specular_glossiness },
            .{ material.has_clearcoat, .materials_clearcoat },
            .{ material.has_transmission, .materials_transmission },
            .{ material.has_volume, .materials_volume },
            .{ material.has_ior, .materials_ior },
            .{ material.has_specular, .materials_specular },
            .{ material.has_sheen, .materials_sheen },
            .{ material.has_emissive_strength, .materials_emissive_strength },
            .{ material.has_iridescence, .materials_iridescence },
            .{ material.has_diffuse_transmission, .materials_diffuse_transmission },
            .{ material.has_anisotropy, .materials_anisotropy },
            .{ material.has_dispersion, .materials_dispersion },
        };
        var any_extension = false;
        for (flags) |flag| {
            if (flag[0]) {
                c.extensions_used.insert(flag[1]);
                any_extension = true;
            }
        }

        if (material.has_pbr_metallic_roughness) {
            const params = &material.pbr_metallic_roughness;
            try c.line("\"pbrMetallicRoughness\": {");
            try c.textureView("baseColorTexture", null, &params.base_color_texture);
            try c.textureView("metallicRoughnessTexture", null, &params.metallic_roughness_texture);
            try c.floatProp("metallicFactor", params.metallic_factor, 1.0);
            try c.floatProp("roughnessFactor", params.roughness_factor, 1.0);
            if (differs(&params.base_color_factor, 1.0)) {
                try c.floatArrayProp("baseColorFactor", &params.base_color_factor);
            }
            try c.line("}");
        }

        if (any_extension) {
            try c.line("\"extensions\": {");
            if (material.has_clearcoat) {
                const params = &material.clearcoat;
                try c.line("\"KHR_materials_clearcoat\": {");
                try c.textureView("clearcoatTexture", null, &params.clearcoat_texture);
                try c.textureView(
                    "clearcoatRoughnessTexture",
                    null,
                    &params.clearcoat_roughness_texture,
                );
                try c.textureView(
                    "clearcoatNormalTexture",
                    "scale",
                    &params.clearcoat_normal_texture,
                );
                try c.floatProp("clearcoatFactor", params.clearcoat_factor, 0.0);
                try c.floatProp("clearcoatRoughnessFactor", params.clearcoat_roughness_factor, 0.0);
                try c.line("}");
            }
            if (material.has_ior) {
                try c.line("\"KHR_materials_ior\": {");
                try c.floatProp("ior", material.ior.ior, 1.5);
                try c.line("}");
            }
            if (material.has_specular) {
                const params = &material.specular;
                try c.line("\"KHR_materials_specular\": {");
                try c.textureView("specularTexture", null, &params.specular_texture);
                try c.textureView("specularColorTexture", null, &params.specular_color_texture);
                try c.floatProp("specularFactor", params.specular_factor, 1.0);
                if (differs(&params.specular_color_factor, 1.0)) {
                    try c.floatArrayProp("specularColorFactor", &params.specular_color_factor);
                }
                try c.line("}");
            }
            if (material.has_transmission) {
                const params = &material.transmission;
                try c.line("\"KHR_materials_transmission\": {");
                try c.textureView("transmissionTexture", null, &params.transmission_texture);
                try c.floatProp("transmissionFactor", params.transmission_factor, 0.0);
                try c.line("}");
            }
            if (material.has_volume) {
                const params = &material.volume;
                try c.line("\"KHR_materials_volume\": {");
                try c.textureView("thicknessTexture", null, &params.thickness_texture);
                try c.floatProp("thicknessFactor", params.thickness_factor, 0.0);
                if (differs(&params.attenuation_color, 1.0)) {
                    try c.floatArrayProp("attenuationColor", &params.attenuation_color);
                }
                const max = std.math.floatMax(f32);
                if (params.attenuation_distance < max) {
                    try c.floatProp("attenuationDistance", params.attenuation_distance, max);
                }
                try c.line("}");
            }
            if (material.has_sheen) {
                const params = &material.sheen;
                try c.line("\"KHR_materials_sheen\": {");
                try c.textureView("sheenColorTexture", null, &params.sheen_color_texture);
                try c.textureView("sheenRoughnessTexture", null, &params.sheen_roughness_texture);
                if (differs(&params.sheen_color_factor, 0.0)) {
                    try c.floatArrayProp("sheenColorFactor", &params.sheen_color_factor);
                }
                try c.floatProp("sheenRoughnessFactor", params.sheen_roughness_factor, 0.0);
                try c.line("}");
            }
            if (material.has_pbr_specular_glossiness) {
                const params = &material.pbr_specular_glossiness;
                try c.line("\"KHR_materials_pbrSpecularGlossiness\": {");
                try c.textureView("diffuseTexture", null, &params.diffuse_texture);
                try c.textureView(
                    "specularGlossinessTexture",
                    null,
                    &params.specular_glossiness_texture,
                );
                if (differs(&params.diffuse_factor, 1.0)) {
                    try c.floatArrayProp("diffuseFactor", &params.diffuse_factor);
                }
                if (differs(&params.specular_factor, 1.0)) {
                    try c.floatArrayProp("specularFactor", &params.specular_factor);
                }
                try c.floatProp("glossinessFactor", params.glossiness_factor, 1.0);
                try c.line("}");
            }
            if (material.unlit) try c.line("\"KHR_materials_unlit\": {}");
            if (material.has_emissive_strength) {
                try c.line("\"KHR_materials_emissive_strength\": {");
                try c.floatProp(
                    "emissiveStrength",
                    material.emissive_strength.emissive_strength,
                    1.0,
                );
                try c.line("}");
            }
            if (material.has_iridescence) {
                const params = &material.iridescence;
                try c.line("\"KHR_materials_iridescence\": {");
                try c.floatProp("iridescenceFactor", params.iridescence_factor, 0.0);
                try c.textureView("iridescenceTexture", null, &params.iridescence_texture);
                try c.floatProp("iridescenceIor", params.iridescence_ior, 1.3);
                try c.floatProp(
                    "iridescenceThicknessMinimum",
                    params.iridescence_thickness_min,
                    100.0,
                );
                try c.floatProp(
                    "iridescenceThicknessMaximum",
                    params.iridescence_thickness_max,
                    400.0,
                );
                try c.textureView(
                    "iridescenceThicknessTexture",
                    null,
                    &params.iridescence_thickness_texture,
                );
                try c.line("}");
            }
            if (material.has_diffuse_transmission) {
                const params = &material.diffuse_transmission;
                try c.line("\"KHR_materials_diffuse_transmission\": {");
                try c.textureView(
                    "diffuseTransmissionTexture",
                    null,
                    &params.diffuse_transmission_texture,
                );
                try c.floatProp(
                    "diffuseTransmissionFactor",
                    params.diffuse_transmission_factor,
                    0.0,
                );
                if (differs(&params.diffuse_transmission_color_factor, 1.0)) {
                    try c.floatArrayProp(
                        "diffuseTransmissionColorFactor",
                        &params.diffuse_transmission_color_factor,
                    );
                }
                try c.textureView(
                    "diffuseTransmissionColorTexture",
                    null,
                    &params.diffuse_transmission_color_texture,
                );
                try c.line("}");
            }
            if (material.has_anisotropy) {
                const params = &material.anisotropy;
                try c.line("\"KHR_materials_anisotropy\": {");
                try c.floatProp("anisotropyStrength", params.anisotropy_strength, 0.0);
                try c.floatProp("anisotropyRotation", params.anisotropy_rotation, 0.0);
                try c.textureView("anisotropyTexture", null, &params.anisotropy_texture);
                try c.line("}");
            }
            if (material.has_dispersion) {
                try c.line("\"KHR_materials_dispersion\": {");
                try c.floatProp("dispersion", material.dispersion.dispersion, 0.0);
                try c.line("}");
            }
            try c.line("}");
        }

        try c.textureView("normalTexture", "scale", &material.normal_texture);
        try c.textureView("occlusionTexture", "strength", &material.occlusion_texture);
        try c.textureView("emissiveTexture", null, &material.emissive_texture);
        if (differs(&material.emissive_factor, 0.0)) {
            try c.floatArrayProp("emissiveFactor", &material.emissive_factor);
        }
        try c.strProp("alphaMode", switch (material.alpha_mode) {
            .mask => "MASK",
            .blend => "BLEND",
            .@"opaque" => null,
        });
        try c.writeExtras(&material.extras);
        try c.line("}");
    }

    fn writeImage(c: *Context, image: *const types.Image) WriteError!void {
        try c.line("{");
        try c.strProp("name", image.name);
        try c.strProp("uri", image.uri);
        try c.indexProp("bufferView", image.buffer_view);
        try c.strProp("mimeType", image.mime_type);
        try c.writeExtras(&image.extras);
        try c.line("}");
    }

    fn writeTexture(c: *Context, texture: *const types.Texture) WriteError!void {
        try c.line("{");
        try c.strProp("name", texture.name);
        try c.indexProp("source", texture.image);
        try c.indexProp("sampler", texture.sampler);
        if (texture.has_basisu or texture.has_webp) {
            try c.line("\"extensions\": {");
            if (texture.has_basisu) {
                c.extensions_used.insert(.texture_basisu);
                try c.line("\"KHR_texture_basisu\": {");
                try c.indexProp("source", texture.basisu_image);
                try c.line("}");
            }
            if (texture.has_webp) {
                c.extensions_used.insert(.texture_webp);
                try c.line("\"EXT_texture_webp\": {");
                try c.indexProp("source", texture.webp_image);
                try c.line("}");
            }
            try c.line("}");
        }
        try c.writeExtras(&texture.extras);
        try c.line("}");
    }

    fn writeSkin(c: *Context, skin: *const types.Skin) WriteError!void {
        try c.line("{");
        try c.indexProp("skeleton", skin.skeleton);
        try c.indexProp("inverseBindMatrices", skin.inverse_bind_matrices);
        try c.indexArrayProp("joints", skin.joints);
        try c.strProp("name", skin.name);
        try c.writeExtras(&skin.extras);
        try c.line("}");
    }

    fn writeAnimation(c: *Context, animation: *const types.Animation) WriteError!void {
        try c.line("{");
        try c.strProp("name", animation.name);
        if (animation.samplers.len > 0) {
            try c.line("\"samplers\": [");
            for (animation.samplers) |*sampler| {
                try c.line("{");
                try c.strProp("interpolation", switch (sampler.interpolation) {
                    .linear => "LINEAR",
                    .step => "STEP",
                    .cubic_spline => "CUBICSPLINE",
                });
                try c.indexProp("input", sampler.input);
                try c.indexProp("output", sampler.output);
                try c.writeExtras(&sampler.extras);
                try c.line("}");
            }
            try c.line("]");
        }
        if (animation.channels.len > 0) {
            try c.line("\"channels\": [");
            for (animation.channels) |*channel| {
                try c.line("{");
                try c.indexProp("sampler", channel.sampler);
                try c.line("\"target\": {");
                try c.indexProp("node", channel.target_node);
                try c.strProp("path", switch (channel.target_path) {
                    .translation => "translation",
                    .rotation => "rotation",
                    .scale => "scale",
                    .weights => "weights",
                    .invalid => "invalid",
                });
                try c.line("}");
                try c.writeExtras(&channel.extras);
                try c.line("}");
            }
            try c.line("]");
        }
        try c.writeExtras(&animation.extras);
        try c.line("}");
    }

    fn writeSampler(c: *Context, sampler: *const types.Sampler) WriteError!void {
        try c.line("{");
        try c.strProp("name", sampler.name);
        try c.intProp("magFilter", @backingInt(sampler.mag_filter), 0);
        try c.intProp("minFilter", @backingInt(sampler.min_filter), 0);
        try c.intProp("wrapS", @backingInt(sampler.wrap_s), 10497);
        try c.intProp("wrapT", @backingInt(sampler.wrap_t), 10497);
        try c.writeExtras(&sampler.extras);
        try c.line("}");
    }

    fn writeNode(c: *Context, node: *const types.Node) WriteError!void {
        try c.line("{");
        try c.indexArrayProp("children", node.children);
        try c.indexProp("mesh", node.mesh);
        try c.strProp("name", node.name);
        if (node.has_matrix) try c.floatArrayProp("matrix", &node.matrix);
        if (node.has_translation) try c.floatArrayProp("translation", &node.translation);
        if (node.has_rotation) try c.floatArrayProp("rotation", &node.rotation);
        if (node.has_scale) try c.floatArrayProp("scale", &node.scale);
        try c.indexProp("skin", node.skin);

        const instancing = node.has_mesh_gpu_instancing and
            node.mesh_gpu_instancing.attributes.len > 0;
        const has_extension = node.light != null or instancing;
        if (has_extension) try c.line("\"extensions\": {");
        if (node.light != null) {
            c.extensions_used.insert(.lights_punctual);
            try c.line("\"KHR_lights_punctual\": {");
            try c.indexProp("light", node.light);
            try c.line("}");
        }
        if (instancing) {
            c.extensions_used.insert(.mesh_gpu_instancing);
            c.extensions_required.insert(.mesh_gpu_instancing);
            try c.line("\"EXT_mesh_gpu_instancing\": {");
            try c.line("\"attributes\": {");
            try c.attributes(node.mesh_gpu_instancing.attributes);
            try c.line("}");
            try c.line("}");
        }
        if (has_extension) try c.line("}");

        if (node.weights) |weights| {
            if (weights.len > 0) try c.floatArrayProp("weights", weights);
        }
        try c.indexProp("camera", node.camera);
        try c.writeExtras(&node.extras);
        try c.line("}");
    }

    fn writeScene(c: *Context, scene: *const types.Scene) WriteError!void {
        try c.line("{");
        try c.strProp("name", scene.name);
        try c.indexArrayProp("nodes", scene.nodes);
        try c.writeExtras(&scene.extras);
        try c.line("}");
    }

    fn writeAccessor(c: *Context, accessor: *const types.Accessor) WriteError!void {
        try c.line("{");
        try c.strProp("name", accessor.name);
        try c.indexProp("bufferView", accessor.buffer_view);
        try c.intProp("componentType", componentTypeNumber(accessor.component_type), 0);
        try c.strProp("type", switch (accessor.type) {
            .scalar => "SCALAR",
            .vec2 => "VEC2",
            .vec3 => "VEC3",
            .vec4 => "VEC4",
            .mat2 => "MAT2",
            .mat3 => "MAT3",
            .mat4 => "MAT4",
            .invalid => null,
        });
        const components: usize = switch (accessor.type) {
            .invalid => 0,
            else => cgltf.numComponents(accessor.type),
        };
        try c.boolProp("normalized", accessor.normalized, false);
        try c.sizePropFromInt("byteOffset", accessor.offset, 0);
        try c.intProp("count", cInt(accessor.count), -1);
        if (accessor.has_min) try c.floatArrayProp("min", accessor.min[0..components]);
        if (accessor.has_max) try c.floatArrayProp("max", accessor.max[0..components]);
        if (accessor.is_sparse) {
            const sparse = &accessor.sparse;
            try c.line("\"sparse\": {");
            try c.intProp("count", cInt(sparse.count), 0);
            try c.line("\"indices\": {");
            try c.sizePropFromInt("byteOffset", sparse.indices_byte_offset, 0);
            try c.indexProp("bufferView", sparse.indices_buffer_view);
            try c.intProp("componentType", componentTypeNumber(sparse.indices_component_type), 0);
            try c.line("}");
            try c.line("\"values\": {");
            try c.sizePropFromInt("byteOffset", sparse.values_byte_offset, 0);
            try c.indexProp("bufferView", sparse.values_buffer_view);
            try c.line("}");
            try c.line("}");
        }
        try c.writeExtras(&accessor.extras);
        try c.line("}");
    }

    fn componentTypeNumber(component_type: types.ComponentType) i32 {
        return switch (component_type) {
            .r_8 => 5120,
            .r_8u => 5121,
            .r_16 => 5122,
            .r_16u => 5123,
            .r_32u => 5125,
            .r_32f => 5126,
            .invalid => 0,
        };
    }

    fn writeCamera(c: *Context, camera: *const types.Camera) WriteError!void {
        try c.line("{");
        try c.strProp("type", switch (camera.data) {
            .perspective => "perspective",
            .orthographic => "orthographic",
            .invalid => null,
        });
        try c.strProp("name", camera.name);
        switch (camera.data) {
            .orthographic => |*orthographic| {
                try c.line("\"orthographic\": {");
                try c.floatProp("xmag", orthographic.xmag, -1.0);
                try c.floatProp("ymag", orthographic.ymag, -1.0);
                try c.floatProp("zfar", orthographic.zfar, -1.0);
                try c.floatProp("znear", orthographic.znear, -1.0);
                try c.writeExtras(&orthographic.extras);
                try c.line("}");
            },
            .perspective => |*perspective| {
                try c.line("\"perspective\": {");
                if (perspective.has_aspect_ratio) {
                    try c.floatProp("aspectRatio", perspective.aspect_ratio, -1.0);
                }
                try c.floatProp("yfov", perspective.yfov, -1.0);
                if (perspective.has_zfar) try c.floatProp("zfar", perspective.zfar, -1.0);
                try c.floatProp("znear", perspective.znear, -1.0);
                try c.writeExtras(&perspective.extras);
                try c.line("}");
            },
            .invalid => {},
        }
        try c.writeExtras(&camera.extras);
        try c.line("}");
    }

    fn writeLight(c: *Context, light: *const types.Light) WriteError!void {
        c.extensions_used.insert(.lights_punctual);
        try c.line("{");
        try c.strProp("type", switch (light.type) {
            .directional => "directional",
            .point => "point",
            .spot => "spot",
            .invalid => null,
        });
        try c.strProp("name", light.name);
        if (differs(&light.color, 1.0)) try c.floatArrayProp("color", &light.color);
        try c.floatProp("intensity", light.intensity, 1.0);
        try c.floatProp("range", light.range, 0.0);
        if (light.type == .spot) {
            try c.line("\"spot\": {");
            try c.floatProp("innerConeAngle", light.spot_inner_cone_angle, 0.0);
            try c.floatProp("outerConeAngle", light.spot_outer_cone_angle, std.math.pi / 4.0);
            try c.line("}");
        }
        try c.writeExtras(&light.extras);
        try c.line("}");
    }

    fn writeVariant(c: *Context, variant: *const types.MaterialVariant) WriteError!void {
        c.extensions_used.insert(.materials_variants);
        try c.line("{");
        try c.strProp("name", variant.name);
        try c.writeExtras(&variant.extras);
        try c.line("}");
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a parsed glTF writes as cgltf lays it out, and parses again" {
    const json =
        \\{"asset":{"version":"2.0","extras":{"a":1}},"scene":0,"scenes":[{"nodes":[0]}],
        \\"nodes":[{"children":[],"translation":[1,0.1,3]}]}
    ;
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    defer gltf.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&gltf, &out.writer);
    try testing.expectEqualStrings(
        \\{
        \\  "asset": {
        \\    "version": "2.0",
        \\    "extras": {"a":1}
        \\  },
        \\  "nodes": [
        \\    {
        \\      "children": [ ],
        \\      "translation": [1, 0.100000001, 3]
        \\    }
        \\  ],
        \\  "scene": 0,
        \\  "scenes": [
        \\    {
        \\      "nodes": [ 0 ]
        \\    }
        \\  ]
        \\}
        \\
    , out.written());
    var again = try cgltf.parse(testing.allocator, out.written(), .{});
    defer again.deinit();
    try testing.expectEqual(@as(f32, 0.1), again.nodes[0].translation[1]);
}

test "a short output is a failed write" {
    var gltf = try cgltf.parse(testing.allocator, "{\"asset\":{\"version\":\"2.0\"}}", .{});
    defer gltf.deinit();
    var buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, write(&gltf, &out));
}

test "extras without data or JSON text are not written" {
    const json = "{\"asset\":{\"version\":\"2.0\"},\"extras\":[1]}";
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    defer gltf.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    gltf.extras.data = null;
    try write(&gltf, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"extras\": [1]") != null);
    out.clearRetainingCapacity();
    gltf.json = &.{};
    try write(&gltf, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "extras") == null);
}
