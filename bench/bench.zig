//! `zig build bench`: zig-cgltf against the original, one feature per row,
//! on one thread, over the Khronos sample models.
//!
//! Both sides work on the same bytes: every `.gltf` and `.glb` file of the
//! sample models, read into memory once. The original comes from
//! reference/, built at -O3 for the same CPU as the Zig, which is
//! ReleaseFast, and both allocate with the C library's malloc. Each sample
//! times enough passes to last at least `sample_ns_min`, after warm-up
//! samples, and the two sides' samples alternate so both see the same
//! load. Time is the benchmark thread's CPU time. Every pass folds its
//! output into a checksum kept behind a compiler barrier, so no pass can
//! be optimized away, and the two sides' checksums are compared: a row
//! whose outputs differ says so.
//!
//!   zig build bench [-- --samples N --rounds N --filter TEXT]
//!
//! `--rounds` runs every row that many times, spread over the whole run,
//! and keeps each side's best median.

const std = @import("std");
const builtin = @import("builtin");
const cgltf = @import("cgltf");
const c = @import("c");
const samples = @import("samples");

const sample_ns_min = 50 * std.time.ns_per_ms;
const warm_up_samples = 2;
const gpa = std.heap.c_allocator;

const Model = struct {
    path: [:0]const u8,
    bytes: []const u8,
    glb: bool,
    /// Both sides, parsed from `bytes` with their buffers loaded, for the
    /// rows that read them; null when either side refuses the file.
    original: ?*c.cgltf_data = null,
    port: ?*cgltf.Gltf = null,
};

const Uri = struct { text: [:0]const u8, size: usize };

const Inputs = struct {
    io: std.Io,
    models: []Model,
    /// The base64 text and size of every data URI of every buffer.
    uris: []const Uri,
    floats: []f32,
    indices: []u32,
};

const Side = *const fn (in: *const Inputs) u64;

const Case = struct {
    name: []const u8,
    /// What one pass covers, for the table.
    unit: []const u8,
    zig: Side,
    original: Side,
};

fn mix(hash: u64, value: u64) u64 {
    return (hash ^ value) *% 0x100000001B3;
}

fn mixFloats(hash: u64, floats: []const f32) u64 {
    var h = hash;
    for (floats) |f| h = mix(h, @as(u32, @bitCast(f)));
    return h;
}

// --- Rows -----------------------------------------------------------------

fn parseZig(in: *const Inputs, glb: bool) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        if (model.glb != glb) continue;
        var gltf = cgltf.parse(gpa, model.bytes, .{}) catch {
            hash = mix(hash, 1);
            continue;
        };
        hash = mix(hash, gltf.accessors.len +% gltf.nodes.len);
        gltf.deinit();
    }
    return hash;
}

fn parseOriginal(in: *const Inputs, glb: bool) u64 {
    var hash: u64 = 0;
    var options = std.mem.zeroes(c.cgltf_options);
    for (in.models) |model| {
        if (model.glb != glb) continue;
        var data: [*c]c.cgltf_data = null;
        if (c.cgltf_parse(&options, model.bytes.ptr, model.bytes.len, &data) != c.cgltf_result_success) {
            hash = mix(hash, 1);
            continue;
        }
        hash = mix(hash, data.*.accessors_count +% data.*.nodes_count);
        c.cgltf_free(data);
    }
    return hash;
}

fn parseGltfZig(in: *const Inputs) u64 {
    return parseZig(in, false);
}

fn parseGltfOriginal(in: *const Inputs) u64 {
    return parseOriginal(in, false);
}

fn parseGlbZig(in: *const Inputs) u64 {
    return parseZig(in, true);
}

fn parseGlbOriginal(in: *const Inputs) u64 {
    return parseOriginal(in, true);
}

fn base64Zig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.uris) |uri| {
        const data = cgltf.loadBufferBase64(gpa, uri.size, uri.text) catch continue;
        std.mem.doNotOptimizeAway(data.ptr);
        if (data.len > 0) hash = mix(hash, data[data.len / 2]);
        gpa.free(data);
    }
    return hash;
}

fn base64Original(in: *const Inputs) u64 {
    var hash: u64 = 0;
    var options = std.mem.zeroes(c.cgltf_options);
    for (in.uris) |uri| {
        var out: ?*anyopaque = null;
        if (c.cgltf_load_buffer_base64(&options, uri.size, uri.text.ptr, &out) != c.cgltf_result_success) continue;
        const data: [*]const u8 = @ptrCast(out.?);
        std.mem.doNotOptimizeAway(data);
        if (uri.size > 0) hash = mix(hash, data[uri.size / 2]);
        std.c.free(out);
    }
    return hash;
}

fn validateZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        hash = mix(hash, if (cgltf.validate(gltf)) |_| 0 else |_| 1);
    }
    return hash;
}

fn validateOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        hash = mix(hash, @intFromBool(c.cgltf_validate(data) != c.cgltf_result_success));
    }
    return hash;
}

fn unpackFloatsZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        for (gltf.accessors) |*accessor| {
            const n = cgltf.unpackFloatsCount(accessor);
            if (n > in.floats.len) continue;
            const written = cgltf.unpackFloats(gltf, accessor, in.floats[0..n]) catch continue;
            hash = mixFloats(hash, in.floats[0..@min(written, 8)]);
            hash = mix(hash, written);
        }
    }
    return hash;
}

fn unpackFloatsOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        for (data.accessors[0..data.accessors_count]) |*accessor| {
            const n = c.cgltf_accessor_unpack_floats(accessor, null, 0);
            if (n > in.floats.len) continue;
            const written = c.cgltf_accessor_unpack_floats(accessor, in.floats.ptr, n);
            hash = mixFloats(hash, in.floats[0..@min(written, 8)]);
            hash = mix(hash, written);
        }
    }
    return hash;
}

fn readFloatZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        for (gltf.accessors) |*accessor| {
            for (0..accessor.count) |e| {
                var out: [16]f32 = undefined;
                const ok = cgltf.readFloat(gltf, accessor, e, &out) catch break;
                std.mem.doNotOptimizeAway(&out);
                if (ok) hash = mix(hash, @as(u32, @bitCast(out[0])));
            }
        }
    }
    return hash;
}

fn readFloatOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        for (data.accessors[0..data.accessors_count]) |*accessor| {
            for (0..accessor.count) |e| {
                var out: [16]f32 = undefined;
                const ok = c.cgltf_accessor_read_float(accessor, e, &out, 16) != 0;
                std.mem.doNotOptimizeAway(&out);
                if (ok) {
                    hash = mix(hash, @as(u32, @bitCast(out[0])));
                }
            }
        }
    }
    return hash;
}

/// The accessors the index rows read: scalar, unsigned and not sparse.
fn isIndexAccessor(accessor: *const cgltf.Accessor) bool {
    const t = accessor.component_type;
    return accessor.type == .scalar and !accessor.is_sparse and
        (t == .r_8u or t == .r_16u or t == .r_32u);
}

fn unpackIndicesZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        for (gltf.accessors) |*accessor| {
            if (!isIndexAccessor(accessor)) continue;
            const n = @min(accessor.count, in.indices.len);
            const written = cgltf.unpackIndices(u32, gltf, accessor, in.indices[0..n]) catch continue;
            hash = mix(hash, written);
            if (written > 0) hash = mix(hash, in.indices[written - 1]);
        }
    }
    return hash;
}

fn unpackIndicesOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        for (data.accessors[0..data.accessors_count], model.port.?.accessors) |*accessor, *port| {
            if (!isIndexAccessor(port)) continue;
            const n = @min(accessor.count, in.indices.len);
            const written = c.cgltf_accessor_unpack_indices(accessor, in.indices.ptr, 4, n);
            hash = mix(hash, written);
            if (written > 0) hash = mix(hash, in.indices[written - 1]);
        }
    }
    return hash;
}

fn readIndexZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        for (gltf.accessors) |*accessor| {
            if (!isIndexAccessor(accessor)) continue;
            for (0..accessor.count) |e| {
                hash +%= cgltf.readIndex(gltf, accessor, e) catch break;
            }
        }
    }
    return hash;
}

fn readIndexOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        for (data.accessors[0..data.accessors_count], model.port.?.accessors) |*accessor, *port| {
            if (!isIndexAccessor(port)) continue;
            for (0..accessor.count) |e| hash +%= c.cgltf_accessor_read_index(accessor, e);
        }
    }
    return hash;
}

fn transformsZig(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const gltf = model.port orelse continue;
        for (0..gltf.nodes.len) |n| {
            const world = cgltf.transformWorld(gltf, @intCast(n)) catch continue;
            std.mem.doNotOptimizeAway(&world);
            hash = mix(hash, @as(u32, @bitCast(world[12])));
        }
    }
    return hash;
}

fn transformsOriginal(in: *const Inputs) u64 {
    var hash: u64 = 0;
    for (in.models) |model| {
        const data = model.original orelse continue;
        for (data.nodes[0..data.nodes_count]) |*node| {
            var world: [16]f32 = undefined;
            c.cgltf_node_transform_world(node, &world);
            std.mem.doNotOptimizeAway(&world);
            hash = mix(hash, @as(u32, @bitCast(world[12])));
        }
    }
    return hash;
}

const cases = [_]Case{
    .{ .name = "parse glTF", .unit = "every .gltf file", .zig = parseGltfZig, .original = parseGltfOriginal },
    .{ .name = "parse GLB", .unit = "every .glb file", .zig = parseGlbZig, .original = parseGlbOriginal },
    .{ .name = "decode base64", .unit = "every data URI", .zig = base64Zig, .original = base64Original },
    .{ .name = "validate", .unit = "every model", .zig = validateZig, .original = validateOriginal },
    .{ .name = "unpack floats", .unit = "every accessor", .zig = unpackFloatsZig, .original = unpackFloatsOriginal },
    .{ .name = "read float", .unit = "every element", .zig = readFloatZig, .original = readFloatOriginal },
    .{ .name = "unpack indices", .unit = "every index accessor", .zig = unpackIndicesZig, .original = unpackIndicesOriginal },
    .{ .name = "read index", .unit = "every index", .zig = readIndexZig, .original = readIndexOriginal },
    .{ .name = "world transforms", .unit = "every node", .zig = transformsZig, .original = transformsOriginal },
};

// --- Measurement ------------------------------------------------------------

/// Nanoseconds of thread CPU time for `reps` passes, and the last
/// pass's checksum.
fn timePasses(in: *const Inputs, side: Side, reps: u32) struct { ns: u64, hash: u64 } {
    const start = std.Io.Clock.cpu_thread.now(in.io);
    var hash: u64 = 0;
    for (0..reps) |_| {
        std.mem.doNotOptimizeAway(in);
        hash = side(in);
        std.mem.doNotOptimizeAway(hash);
    }
    const end = std.Io.Clock.cpu_thread.now(in.io);
    return .{ .ns = @intCast(start.durationTo(end).nanoseconds), .hash = hash };
}

fn passesPerSample(in: *const Inputs, side: Side) u32 {
    const once = @max(timePasses(in, side, 1).ns, 1);
    return @intCast(@max(1, std.math.divCeil(u64, sample_ns_min, once) catch unreachable));
}

const Timing = struct {
    /// Median nanoseconds per pass.
    median_ns: f64,
    /// (slowest - fastest) / median, over the samples.
    range: f64,

    fn of(pass_ns: []f64) Timing {
        std.mem.sort(f64, pass_ns, {}, std.sort.asc(f64));
        const mid = pass_ns.len / 2;
        const median = if (pass_ns.len % 2 == 1) pass_ns[mid] else (pass_ns[mid - 1] + pass_ns[mid]) / 2;
        return .{ .median_ns = median, .range = (pass_ns[pass_ns.len - 1] - pass_ns[0]) / median };
    }

    fn better(a: ?Timing, b: Timing) Timing {
        const old = a orelse return b;
        return if (b.median_ns < old.median_ns) b else old;
    }
};

const Result = struct {
    zig: ?Timing = null,
    original: ?Timing = null,
    same_output: bool = true,
};

fn measure(in: *const Inputs, case: *const Case, sample_count: u32, scratch: []f64) Result {
    const zig_reps = passesPerSample(in, case.zig);
    const original_reps = passesPerSample(in, case.original);
    const zig_ns = scratch[0..sample_count];
    const original_ns = scratch[sample_count..][0..sample_count];
    var zig_hash: u64 = 0;
    var original_hash: u64 = 0;
    for (0..warm_up_samples + sample_count) |k| {
        // Alternating which side goes first evens out any advantage of
        // running second, such as caches the other side warmed.
        for (0..2) |turn| {
            const zig_turn = (turn == 0) == (k % 2 == 0);
            const reps = if (zig_turn) zig_reps else original_reps;
            const t = timePasses(in, if (zig_turn) case.zig else case.original, reps);
            const per_pass = @as(f64, @floatFromInt(t.ns)) / @as(f64, @floatFromInt(reps));
            if (zig_turn) zig_hash = t.hash else original_hash = t.hash;
            if (k >= warm_up_samples) {
                const slot = k - warm_up_samples;
                if (zig_turn) zig_ns[slot] = per_pass else original_ns[slot] = per_pass;
            }
        }
    }
    return .{
        .zig = Timing.of(zig_ns),
        .original = Timing.of(original_ns),
        .same_output = zig_hash == original_hash,
    };
}

// --- Setup --------------------------------------------------------------------

fn prepare(io: std.Io) !Inputs {
    const paths = try samples.modelPaths(gpa, io);
    const models = try gpa.alloc(Model, paths.len);
    var uris: std.ArrayList(Uri) = .empty;
    var floats_max: usize = 0;
    var indices_max: usize = 0;
    for (paths, models) |path, *model| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        model.* = .{ .path = path, .bytes = bytes, .glb = std.mem.endsWith(u8, path, ".glb") };

        var options = std.mem.zeroes(c.cgltf_options);
        var data: [*c]c.cgltf_data = null;
        if (c.cgltf_parse(&options, bytes.ptr, bytes.len, &data) != c.cgltf_result_success) continue;
        if (c.cgltf_load_buffers(&options, data, path) != c.cgltf_result_success) {
            c.cgltf_free(data);
            continue;
        }
        const port = try gpa.create(cgltf.Gltf);
        port.* = cgltf.parse(gpa, bytes, .{}) catch {
            c.cgltf_free(data);
            gpa.destroy(port);
            continue;
        };
        cgltf.loadBuffers(port, io, path) catch {
            c.cgltf_free(data);
            port.deinit();
            gpa.destroy(port);
            continue;
        };
        model.original = data;
        model.port = port;
        for (port.buffers) |buffer| {
            const uri = buffer.uri orelse continue;
            if (!std.mem.startsWith(u8, uri, "data:")) continue;
            const comma = std.mem.indexOfScalar(u8, uri, ',') orelse continue;
            try uris.append(gpa, .{ .text = uri[comma + 1 ..], .size = buffer.size });
        }
        for (port.accessors) |*accessor| {
            floats_max = @max(floats_max, cgltf.unpackFloatsCount(accessor));
            indices_max = @max(indices_max, accessor.count);
        }
    }
    return .{
        .io = io,
        .models = models,
        .uris = try uris.toOwnedSlice(gpa),
        .floats = try gpa.alloc(f32, @min(floats_max, 1 << 26)),
        .indices = try gpa.alloc(u32, @min(indices_max, 1 << 26)),
    };
}

const Options = struct {
    samples: u32 = 11,
    rounds: u32 = 1,
    filter: ?[]const u8 = null,
};

fn parseOptions(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 >= args.len) return error.MissingValue;
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--samples")) {
            options.samples = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            options.rounds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            options.filter = value;
        } else {
            return error.UnknownOption;
        }
        i += 1;
    }
    if (options.samples == 0 or options.rounds == 0) return error.ZeroCount;
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    const in = try prepare(io);
    var loaded: usize = 0;
    for (in.models) |model| loaded += @intFromBool(model.port != null);
    const scratch = try gpa.alloc(f64, 2 * options.samples);

    var results: [cases.len]Result = @splat(.{});
    for (0..options.rounds) |_| {
        for (&cases, &results) |*case, *result| {
            if (options.filter) |f| if (std.mem.indexOf(u8, case.name, f) == null) continue;
            const m = measure(&in, case, options.samples, scratch);
            result.zig = Timing.better(result.zig, m.zig.?);
            result.original = Timing.better(result.original, m.original.?);
            result.same_output = result.same_output and m.same_output;
        }
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    try w.print(
        \\zig-cgltf benchmark: {s} {s}, {s}, Zig {s}, one thread
        \\{d} sample models ({d} loaded, {d} data URIs); median of {d} samples of at least {d} ms
        \\after {d} warm-ups, best of {d} round(s); thread CPU time
        \\
        \\| feature | pass | zig-cgltf ms | range | original ms | range | original / zig-cgltf |
        \\| --- | --- | ---: | ---: | ---: | ---: | ---: |
        \\
    , .{
        @tagName(builtin.cpu.arch), builtin.cpu.model.name, @tagName(builtin.os.tag),
        builtin.zig_version_string, in.models.len,          loaded,
        in.uris.len,                options.samples,        sample_ns_min / std.time.ns_per_ms,
        warm_up_samples,            options.rounds,
    });
    for (&cases, &results) |*case, result| {
        const zig = result.zig orelse continue;
        const o = result.original.?;
        try w.print("| {s} | {s} | {d:.3} | {d:.1}% | {d:.3} | {d:.1}% | {d:.2} |", .{
            case.name,
            case.unit,
            zig.median_ns / 1e6,
            zig.range * 100,
            o.median_ns / 1e6,
            o.range * 100,
            o.median_ns / zig.median_ns,
        });
        if (!result.same_output) try w.print(" OUTPUT DIFFERS", .{});
        try w.print("\n", .{});
    }
    try w.flush();
}
