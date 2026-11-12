//! The C library's text-to-number conversions as cgltf calls them: `atoi`,
//! `atoll` and `atof`, with glibc's behaviour in the C locale. cgltf reads
//! every JSON number through these, so a port that reads numbers any other
//! way gives different integers and floats on unusual input: leading
//! spaces, trailing text, hexadecimal floats, `nan(...)`, overflow.

const std = @import("std");

/// The C locale's `isspace`.
fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c | 0x20 >= 'a' and c | 0x20 <= 'f');
}

fn hexValue(c: u8) u8 {
    return if (isDigit(c)) c - '0' else (c | 0x20) - 'a' + 10;
}

/// The text up to its first NUL, as C sees a string.
fn cString(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// glibc's `strtol(s, NULL, 10)` with a 64-bit `long`: leading spaces, a
/// sign, then decimal digits, saturating at the limits of `i64`.
pub fn strtol(text: []const u8) i64 {
    const s = cString(text);
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var negative = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        negative = s[i] == '-';
        i += 1;
    }
    // Accumulate the magnitude; the negative limit is one larger.
    const limit: u64 = if (negative) @as(u64, 1) << 63 else std.math.maxInt(i64);
    var magnitude: u64 = 0;
    var overflow = false;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        const digit = s[i] - '0';
        if (!overflow) {
            if (magnitude > (limit - digit) / 10) {
                overflow = true;
            } else {
                magnitude = magnitude * 10 + digit;
            }
        }
    }
    if (overflow) return if (negative) std.math.minInt(i64) else std.math.maxInt(i64);
    if (negative) return @bitCast(0 -% magnitude);
    return @intCast(magnitude);
}

/// glibc's `atoi`: `strtol`'s result truncated to an `int`.
pub fn atoi(text: []const u8) i32 {
    return @truncate(strtol(text));
}

/// glibc's `atoll`, which is `strtol` on a 64-bit `long`.
pub fn atoll(text: []const u8) i64 {
    return strtol(text);
}

/// glibc's `strtoull(s, &end, 0)` over the characters of a NaN's
/// `n-char-sequence`, which are only letters, digits and underscores:
/// the value, saturating, and how many characters it used.
fn strtoullBase0(s: []const u8) struct { value: u64, used: usize } {
    var i: usize = 0;
    var base: u8 = 10;
    if (s.len >= 1 and s[0] == '0') {
        if (s.len >= 3 and s[1] | 0x20 == 'x' and isHexDigit(s[2])) {
            base = 16;
            i = 2;
        } else {
            base = 8;
        }
    }
    const start = i;
    var value: u64 = 0;
    var overflow = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const digit: u8 = if (isDigit(c))
            c - '0'
        else if (c | 0x20 >= 'a' and c | 0x20 <= 'z')
            (c | 0x20) - 'a' + 10
        else
            break;
        if (digit >= base) break;
        const product = @mulWithOverflow(value, base);
        const sum = @addWithOverflow(product[0], digit);
        if (product[1] != 0 or sum[1] != 0) overflow = true;
        value = sum[0];
    }
    if (i == start and base != 8) return .{ .value = 0, .used = 0 };
    return .{ .value = if (overflow) std.math.maxInt(u64) else value, .used = i };
}

const nan_bits: u64 = 0x7FF8_0000_0000_0000;

/// glibc's `strtod(s, NULL)` in the C locale: the value of the longest
/// prefix that is a number, `inf`, `infinity` or `nan` with an optional
/// `(n-char-sequence)`, correctly rounded; 0 when there is none.
pub fn strtod(text: []const u8) f64 {
    const s = cString(text);
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var negative = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        negative = s[i] == '-';
        i += 1;
    }
    const rest = s[i..];
    const starts_number = (rest.len >= 1 and isDigit(rest[0])) or
        (rest.len >= 2 and rest[0] == '.' and isDigit(rest[1]));
    if (!starts_number) {
        if (std.ascii.startsWithIgnoreCase(rest, "inf")) {
            return if (negative) -std.math.inf(f64) else std.math.inf(f64);
        }
        if (std.ascii.startsWithIgnoreCase(rest, "nan")) {
            var bits = nan_bits;
            const after = rest[3..];
            if (after.len >= 1 and after[0] == '(') {
                var end: usize = 1;
                while (end < after.len and
                    (std.ascii.isAlphanumeric(after[end]) or after[end] == '_')) end += 1;
                if (end < after.len and after[end] == ')') {
                    const sequence = after[1..end];
                    const parsed = strtoullBase0(sequence);
                    const payload = parsed.value & ((@as(u64, 1) << 51) - 1);
                    if (parsed.used == sequence.len and payload != 0) bits |= payload;
                }
            }
            if (negative) bits |= @as(u64, 1) << 63;
            return @bitCast(bits);
        }
        return 0.0;
    }
    const signed_zero: f64 = if (negative) -0.0 else 0.0;

    const hex = rest.len >= 2 and rest[0] == '0' and rest[1] | 0x20 == 'x';
    if (hex and !((rest.len >= 3 and isHexDigit(rest[2])) or
        (rest.len >= 4 and rest[2] == '.' and isHexDigit(rest[3]))))
    {
        // "0x" with no hex digit is the number 0 followed by text.
        return signed_zero;
    }
    const isBaseDigit = if (hex) &isHexDigit else &isDigit;
    // The valid prefix is contiguous: digits, a point and digits, then an
    // exponent only when it has digits. std's parser takes it whole.
    var end: usize = if (hex) 2 else 0;
    var nonzero = false;
    while (end < rest.len and isBaseDigit(rest[end])) : (end += 1) {
        nonzero = nonzero or rest[end] != '0';
    }
    if (end < rest.len and rest[end] == '.') {
        end += 1;
        while (end < rest.len and isBaseDigit(rest[end])) : (end += 1) {
            nonzero = nonzero or rest[end] != '0';
        }
    }
    if (!nonzero) return signed_zero;
    const exp_char: u8 = if (hex) 'p' else 'e';
    if (end < rest.len and rest[end] | 0x20 == exp_char) {
        var k = end + 1;
        if (k < rest.len and (rest[k] == '-' or rest[k] == '+')) k += 1;
        if (k < rest.len and isDigit(rest[k])) {
            while (k < rest.len and isDigit(rest[k])) k += 1;
            end = k;
        }
    }
    const magnitude = std.fmt.parseFloat(f64, rest[0..end]) catch unreachable;
    return if (negative) -magnitude else magnitude;
}

/// glibc's `atof`, which is `strtod(s, NULL)`.
pub fn atof(text: []const u8) f64 {
    return strtod(text);
}

/// `(float)d` as x86-64 and AArch64 convert it: rounded to nearest, with
/// a NaN keeping its sign, its quiet bit and the top of its payload.
pub fn toFloat(d: f64) f32 {
    if (std.math.isNan(d)) {
        const bits: u64 = @bitCast(d);
        const sign: u32 = @intCast(bits >> 63);
        const payload: u32 = @intCast((bits >> 29) & 0x7F_FFFF);
        return @bitCast(sign << 31 | 0x7F80_0000 | payload | 0x40_0000);
    }
    return @floatCast(d);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "strtol skips spaces, saturates and stops at text" {
    try testing.expectEqual(@as(i64, 42), strtol("  \t42abc"));
    try testing.expectEqual(@as(i64, -7), strtol("-7"));
    try testing.expectEqual(@as(i64, 0), strtol("abc"));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), strtol("99999999999999999999"));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), strtol("-9223372036854775808"));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), strtol("-99999999999999999999"));
    try testing.expectEqual(@as(i32, -1), atoi("4294967295"));
}

test "strtod reads the forms glibc reads" {
    try testing.expectEqual(@as(f64, 1.5), strtod("1.5e0x"));
    try testing.expectEqual(@as(f64, 3.0), strtod("0x1.8p1"));
    try testing.expectEqual(@as(f64, 26.0), strtod("0x1A"));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(strtod("-0"))));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(strtod("-."))));
    try testing.expectEqual(@as(u64, nan_bits | 16), @as(u64, @bitCast(strtod("nan(0x10)"))));
    try testing.expect(std.math.isInf(strtod("-Infinity")));
    try testing.expectEqual(@as(f64, 5.0), strtod("5e"));
}
