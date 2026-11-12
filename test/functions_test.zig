//! The free functions against the original's and the C library's: string
//! and URI decoding, base64, the size helpers, and the number conversions
//! cgltf reads JSON with.

const std = @import("std");
const cgltf = @import("cgltf");
const number = cgltf.number;
const c = @import("c");
const fuzz = @import("fuzz.zig");

const testing = std.testing;

extern fn atoi(s: [*:0]const u8) c_int;
extern fn atoll(s: [*:0]const u8) c_longlong;
extern fn atof(s: [*:0]const u8) f64;

fn expectSameNumber(text: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&buffer, "{s}", .{text}, 0);
    if (number.atoi(text) != atoi(z)) {
        std.debug.print("atoi(\"{s}\"): libc {d}, port {d}\n", .{ text, atoi(z), number.atoi(text) });
        return error.Mismatch;
    }
    if (number.atoll(text) != atoll(z)) {
        std.debug.print("atoll(\"{s}\"): libc {d}, port {d}\n", .{ text, atoll(z), number.atoll(text) });
        return error.Mismatch;
    }
    const expected: u64 = @bitCast(atof(z));
    const actual: u64 = @bitCast(number.atof(text));
    if (expected != actual) {
        std.debug.print("atof(\"{s}\"): libc {x}, port {x}\n", .{ text, expected, actual });
        return error.Mismatch;
    }
    const expected_f: u32 = @bitCast(@as(f32, @floatCast(atof(z))));
    const actual_f: u32 = @bitCast(number.toFloat(number.atof(text)));
    if (expected_f != actual_f) {
        std.debug.print("(float)atof(\"{s}\"): C {x}, port {x}\n", .{ text, expected_f, actual_f });
        return error.Mismatch;
    }
}

test "numbers: hand-picked texts convert as the C library converts them" {
    const texts = [_][]const u8{
        "",               "0",              "-0",              "+0",             " 1",            "\t\n\x0b\x0c\r 7",
        "1x",             "x1",             "2147483647",      "2147483648",     "-2147483648",   "-2147483649",
        "4294967295",     "4294967296",     "9223372036854775807", "9223372036854775808", "-9223372036854775808",
        "-9223372036854775809", "18446744073709551616", "1.5", ".5",            "-.5",           ".",
        "-.",             "+.",             "5.",              "1e5",            "1e+5",          "1e-5",
        "1e",             "1e+",            "1E5",             "1.5e3x",         "0x1A",          "0X1a",
        "-0x10",          "0x",             "0x.",             "0x.8",           "0x1p4",         "0x1P-4",
        "0x1p",           "0x1.8p1",        "0x1.fffffffffffff8p0", "nan",       "NaN",           "-nan",
        "nan(",           "nan()",          "nan(1)",          "nan(0x10)",      "nan(010)",      "nan(z)",
        "nan(12_3)",      "nan(0xfffffffffffffffff)", "nan(99999999999999999999)", "inf", "-inf", "INFINITY",
        "infinit",        "infinityx",      "1e308",           "1e309",          "-1e309",        "1e-308",
        "1e-324",         "2.4703282292062327e-324", "2.4703282292062328e-324", "4.9406564584124654e-324",
        "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308",
        "3.4028235e38",   "3.40282357e38",  "3.4028236e38",    "1.4e-45",        "7.006e-46",     "7.0064923e-46",
        "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001",
        "100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000001", "1_000", "١", "1\x00 2", "\x00",
    };
    for (texts) |text| try expectSameNumber(text);
}

test "numbers: fuzz: random texts convert as the C library converts them" {
    const alphabet = "0123456789.eE+-xXpPaAfFnNiItTyY() \t_z";
    try fuzz.run("numbers", 20000, struct {
        fn case(random: std.Random) !void {
            var buffer: [40]u8 = undefined;
            const len = random.uintLessThan(usize, buffer.len);
            for (buffer[0..len]) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            try expectSameNumber(buffer[0..len]);
        }
    }.case);
}

test "numbers: fuzz: random floats print and read back as the C library reads them" {
    try fuzz.run("float texts", 20000, struct {
        fn case(random: std.Random) !void {
            const bits = random.int(u64);
            const value: f64 = @bitCast(bits);
            var buffer: [64]u8 = undefined;
            const text = switch (random.uintLessThan(u8, 3)) {
                0 => try std.fmt.bufPrint(&buffer, "{e}", .{value}),
                1 => try std.fmt.bufPrint(&buffer, "{d}", .{@as(f32, @floatCast(value))}),
                else => try std.fmt.bufPrint(&buffer, "{x}", .{value}),
            };
            try expectSameNumber(text);
        }
    }.case);
}

fn expectSameFloatText(value: f32) !void {
    var expected: [64]u8 = undefined;
    const n = c.snprintf(&expected, expected.len, "%.9g", @as(f64, value));
    var buffer: [cgltf.number.float_text_max]u8 = undefined;
    const actual = cgltf.number.formatFloat(&buffer, value);
    if (!std.mem.eql(u8, expected[0..@intCast(n)], actual)) {
        std.debug.print("%.9g of 0x{x:0>8}: original {s}, port {s}\n", .{
            @as(u32, @bitCast(value)), expected[0..@intCast(n)], actual,
        });
        return error.Mismatch;
    }
}

test "numbers: floats print as the C library prints them with %.9g" {
    // Ties at the tenth digit, which round to even.
    for ([_]f32{ 1234567.625, 1234567.875, 2097151.125, 0.5, 1.5, 2.5 }) |value| {
        try expectSameFloatText(value);
        try expectSameFloatText(-value);
    }
    // Every power of two and ten, and the floats beside them.
    var exponent: i32 = -149;
    while (exponent <= 127) : (exponent += 1) {
        const power = std.math.ldexp(@as(f32, 1), exponent);
        for ([_]f32{ power, std.math.nextAfter(f32, power, 0), std.math.nextAfter(f32, power, std.math.inf(f32)) }) |value| {
            try expectSameFloatText(value);
        }
    }
    var decimal: i32 = -45;
    while (decimal <= 38) : (decimal += 1) {
        const power: f32 = @floatCast(std.math.pow(f64, 10, @floatFromInt(decimal)));
        for ([_]f32{ power, std.math.nextAfter(f32, power, 0), std.math.nextAfter(f32, power, std.math.inf(f32)) }) |value| {
            try expectSameFloatText(value);
            try expectSameFloatText(-value);
        }
    }
    for ([_]f32{ 0, -0.0, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), -std.math.nan(f32) }) |value| {
        try expectSameFloatText(value);
    }
    try expectSameFloatText(@bitCast(@as(u32, 0x7FC1_2345)));
    try expectSameFloatText(@bitCast(@as(u32, 0xFF80_0001)));
}

test "numbers: fuzz: random floats print as the C library prints them with %.9g" {
    try fuzz.run("float printing", 20000, struct {
        fn case(random: std.Random) !void {
            // Any bits, and floats with few digits, as files hold.
            for (0..10) |_| try expectSameFloatText(@bitCast(random.int(u32)));
            const digits: f32 = @floatFromInt(random.intRangeAtMost(i32, -100_000, 100_000));
            try expectSameFloatText(digits / 1000);
        }
    }.case);
}

fn expectSameDecodeString(text: []const u8) !void {
    var original: [128:0]u8 = undefined;
    var port: [128:0]u8 = undefined;
    @memcpy(original[0..text.len], text);
    original[text.len] = 0;
    @memcpy(port[0..text.len], text);
    port[text.len] = 0;
    const n = (cgltf.decodeString(port[0..text.len :0]) catch return).len;
    const expected = c.cgltf_decode_string(&original);
    // Both decode in place: every byte of the buffer must match.
    if (n != expected or !std.mem.eql(u8, original[0 .. text.len + 1], port[0 .. text.len + 1])) {
        std.debug.print("decode_string(\"{s}\")\n", .{text});
        return error.Mismatch;
    }
}

fn expectSameDecodeUri(text: []const u8) !void {
    var original: [128:0]u8 = undefined;
    var port: [128:0]u8 = undefined;
    @memcpy(original[0..text.len], text);
    original[text.len] = 0;
    @memcpy(port[0..text.len], text);
    port[text.len] = 0;
    const n = cgltf.decodeUri(port[0..text.len :0]);
    const expected = c.cgltf_decode_uri(&original);
    if (n != expected or !std.mem.eql(u8, original[0 .. text.len + 1], port[0 .. text.len + 1])) {
        std.debug.print("decode_uri(\"{s}\")\n", .{text});
        return error.Mismatch;
    }
}

test "decoding: escapes and percent signs decode as the original decodes them" {
    const texts = [_][]const u8{
        "",         "plain",     "\\n",        "\\\"\\/\\\\\\b\\f\\r\\n\\t", "\\u0041", "\\u00e9",
        "\\u07FF",  "\\u0800",   "\\uFFFF",    "\\uD83D\\uDE00", "\\u0000x",   "\\uzzzz",
        "\\u12zz",  "\\uz123",   "\\q",        "a\\",         "\\u12",       "\\u",
        "%20",      "%2",        "%",          "%zz",         "%4a%4A",      "%%41",
        "a%00b",    "%G0",       "%0G",       "a\x00\\n",   "\\n\x00\\t",   "\\\x00\\n",
        "\\u1\x00\\n", "%2\x00",
    };
    for (texts) |text| {
        try expectSameDecodeString(text);
        try expectSameDecodeUri(text);
    }
}

test "decoding: a parsed name decoded in place reads as the original's" {
    const json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"name\":\"a\\nb\\u00e9\"}]}";
    var options = std.mem.zeroes(c.cgltf_options);
    var original: [*c]c.cgltf_data = null;
    try testing.expect(c.cgltf_parse(&options, json.ptr, json.len, &original) == c.cgltf_result_success);
    defer c.cgltf_free(original);
    var gltf = try cgltf.parse(testing.allocator, json, .{});
    defer gltf.deinit();
    const expected_len = c.cgltf_decode_string(original.*.nodes[0].name);
    const decoded = try cgltf.decodeString(gltf.nodes[0].name.?);
    try testing.expectEqual(expected_len, decoded.len);
    try testing.expectEqualStrings(std.mem.span(original.*.nodes[0].name), decoded);
}

test "decoding: fuzz: random escapes decode as the original decodes them" {
    const alphabet = "\\\\\\u%0123456789abcdefABCDEFxyzbfnrt\"/ \x00";
    try fuzz.run("decode", 20000, struct {
        fn case(random: std.Random) !void {
            var buffer: [60]u8 = undefined;
            const len = random.uintLessThan(usize, buffer.len);
            for (buffer[0..len]) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            try expectSameDecodeString(buffer[0..len]);
            try expectSameDecodeUri(buffer[0..len]);
        }
    }.case);
}

fn expectSameBase64(size: usize, text: [:0]const u8) !void {
    var options = std.mem.zeroes(c.cgltf_options);
    var out: ?*anyopaque = null;
    const result = c.cgltf_load_buffer_base64(&options, size, text.ptr, &out);
    defer if (result == c.cgltf_result_success) std.c.free(out);
    const port = cgltf.loadBufferBase64(testing.allocator, size, text);
    defer if (port) |data| testing.allocator.free(data) else |_| {};
    const code: c.cgltf_result = if (port) |_| c.cgltf_result_success else |_| c.cgltf_result_io_error;
    if (code != result) {
        std.debug.print("base64({d}, \"{s}\"): original {d}, port {d}\n", .{ size, text, result, code });
        return error.Mismatch;
    }
    if (port) |data| {
        const expected: [*]const u8 = @ptrCast(out.?);
        if (!std.mem.eql(u8, expected[0..size], data)) return error.Mismatch;
    } else |_| {}
}

test "base64: fuzz: random texts decode as the original decodes them" {
    const alphabet = "ABCXYZabcxyz0189+/=-_ \n";
    try fuzz.run("base64", 20000, struct {
        fn case(random: std.Random) !void {
            // Long texts reach the decoder's 64-character chunks; most are
            // valid base64 with a bad character here and there.
            var buffer: [400:0]u8 = undefined;
            const len = random.uintLessThan(usize, buffer.len);
            const valid = std.base64.standard_alphabet_chars;
            const bad_rate = random.uintLessThan(usize, 4) * 100 + 2;
            for (buffer[0..len]) |*b| b.* = if (random.uintLessThan(usize, bad_rate) == 0)
                alphabet[random.uintLessThan(usize, alphabet.len)]
            else
                valid[random.uintLessThan(usize, valid.len)];
            buffer[len] = 0;
            try expectSameBase64(random.uintLessThan(usize, len * 3 / 4 + 8), buffer[0..len :0]);
        }
    }.case);
}

test "sizes: components, component sizes and element sizes match for every type" {
    for (0..10) |t| {
        for (0..10) |ct| {
            const port_t: cgltf.Type = if (t < 8) @fromBackingInt(@as(u32, @intCast(t))) else continue;
            const port_ct: cgltf.ComponentType = if (ct < 7) @fromBackingInt(@as(u32, @intCast(ct))) else continue;
            try testing.expectEqual(c.cgltf_num_components(@intCast(t)), cgltf.numComponents(port_t));
            try testing.expectEqual(c.cgltf_component_size(@intCast(ct)), cgltf.componentSize(port_ct));
            try testing.expectEqual(c.cgltf_calc_size(@intCast(t), @intCast(ct)), cgltf.calcSize(port_t, port_ct));
        }
    }
}
