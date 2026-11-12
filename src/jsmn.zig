//! jsmn, the JSON tokenizer inside cgltf, in its strict mode with parent
//! links. It splits the text into tokens (objects, arrays, strings and
//! primitives) without converting anything; cgltf reads the tokens in order.
//! Like jsmn, it stops at the first NUL byte.

const std = @import("std");

pub const TokenType = enum(u8) {
    undefined = 0,
    object = 1,
    array = 2,
    string = 3,
    primitive = 4,
};

pub const Token = struct {
    type: TokenType,
    /// Byte offsets into the text; -1 until known. A string's exclude its
    /// quotes.
    start: isize,
    end: isize,
    /// An object's keys, an array's elements, or 1 for a key with a value.
    size: i32,
    parent: i32,
};

pub const Error = error{
    /// More tokens than the array holds.
    NoMem,
    /// A character that cannot be where it is.
    Inval,
    /// The text ends inside a token.
    Part,
};

pub const Parser = struct {
    pos: usize = 0,
    toknext: u32 = 0,
    toksuper: i32 = -1,
};

fn allocToken(parser: *Parser, tokens: []Token) ?*Token {
    if (parser.toknext >= tokens.len) return null;
    const token = &tokens[parser.toknext];
    parser.toknext += 1;
    token.start = -1;
    token.end = -1;
    token.size = 0;
    token.parent = -1;
    return token;
}

fn fillToken(token: *Token, token_type: TokenType, start: isize, end: isize) void {
    token.type = token_type;
    token.start = start;
    token.end = end;
    token.size = 0;
}

fn parsePrimitive(parser: *Parser, js: []const u8, tokens: ?[]Token) Error!void {
    const start = parser.pos;
    while (parser.pos < js.len and js[parser.pos] != 0) : (parser.pos += 1) {
        switch (js[parser.pos]) {
            '\t', '\r', '\n', ' ', ',', ']', '}' => break,
            else => {},
        }
        if (js[parser.pos] < 32 or js[parser.pos] >= 127) {
            parser.pos = start;
            return error.Inval;
        }
    } else {
        // Strict mode: a primitive ends at a delimiter, not at the end.
        parser.pos = start;
        return error.Part;
    }
    const all = tokens orelse {
        parser.pos -= 1;
        return;
    };
    const token = allocToken(parser, all) orelse {
        parser.pos = start;
        return error.NoMem;
    };
    fillToken(token, .primitive, @intCast(start), @intCast(parser.pos));
    token.parent = parser.toksuper;
    parser.pos -= 1;
}

fn parseString(parser: *Parser, js: []const u8, tokens: ?[]Token) Error!void {
    const start = parser.pos;
    parser.pos += 1;
    while (parser.pos < js.len and js[parser.pos] != 0) : (parser.pos += 1) {
        const c = js[parser.pos];
        if (c == '"') {
            const all = tokens orelse return;
            const token = allocToken(parser, all) orelse {
                parser.pos = start;
                return error.NoMem;
            };
            fillToken(token, .string, @intCast(start + 1), @intCast(parser.pos));
            token.parent = parser.toksuper;
            return;
        }
        if (c == '\\' and parser.pos + 1 < js.len) {
            parser.pos += 1;
            switch (js[parser.pos]) {
                '"', '/', '\\', 'b', 'f', 'r', 'n', 't' => {},
                'u' => {
                    parser.pos += 1;
                    var i: usize = 0;
                    while (i < 4 and parser.pos < js.len and js[parser.pos] != 0) : (i += 1) {
                        if (!std.ascii.isHex(js[parser.pos])) {
                            parser.pos = start;
                            return error.Inval;
                        }
                        parser.pos += 1;
                    }
                    parser.pos -= 1;
                },
                else => {
                    parser.pos = start;
                    return error.Inval;
                },
            }
        }
    }
    parser.pos = start;
    return error.Part;
}

/// Tokenizes `js` into `tokens` and returns how many it filled; with no
/// `tokens`, only counts them. The count counts on from `parser.toknext`.
pub fn parse(parser: *Parser, js: []const u8, tokens: ?[]Token) Error!usize {
    var count: usize = parser.toknext;
    while (parser.pos < js.len and js[parser.pos] != 0) : (parser.pos += 1) {
        const c = js[parser.pos];
        switch (c) {
            '{', '[' => {
                count += 1;
                const all = tokens orelse continue;
                const token = allocToken(parser, all) orelse return error.NoMem;
                if (parser.toksuper != -1) {
                    all[@intCast(parser.toksuper)].size += 1;
                    token.parent = parser.toksuper;
                }
                token.type = if (c == '{') .object else .array;
                token.start = @intCast(parser.pos);
                parser.toksuper = @as(i32, @intCast(parser.toknext)) - 1;
            },
            '}', ']' => {
                const all = tokens orelse continue;
                const token_type: TokenType = if (c == '}') .object else .array;
                if (parser.toknext < 1) return error.Inval;
                var token = &all[parser.toknext - 1];
                while (true) {
                    if (token.start != -1 and token.end == -1) {
                        if (token.type != token_type) return error.Inval;
                        token.end = @intCast(parser.pos + 1);
                        parser.toksuper = token.parent;
                        break;
                    }
                    if (token.parent == -1) {
                        if (token.type != token_type or parser.toksuper == -1) {
                            return error.Inval;
                        }
                        break;
                    }
                    token = &all[@intCast(token.parent)];
                }
            },
            '"' => {
                try parseString(parser, js, tokens);
                count += 1;
                if (parser.toksuper != -1) {
                    if (tokens) |all| all[@intCast(parser.toksuper)].size += 1;
                }
            },
            '\t', '\r', '\n', ' ' => {},
            ':' => parser.toksuper = @as(i32, @intCast(parser.toknext)) - 1,
            ',' => {
                if (tokens) |all| {
                    if (parser.toksuper != -1) {
                        const super = &all[@intCast(parser.toksuper)];
                        if (super.type != .array and super.type != .object) {
                            parser.toksuper = super.parent;
                        }
                    }
                }
            },
            '-', '0'...'9', 't', 'f', 'n' => {
                // Primitives are values, never keys.
                if (tokens) |all| {
                    if (parser.toksuper != -1) {
                        const super = &all[@intCast(parser.toksuper)];
                        if (super.type == .object or (super.type == .string and super.size != 0)) {
                            return error.Inval;
                        }
                    }
                }
                try parsePrimitive(parser, js, tokens);
                count += 1;
                if (parser.toksuper != -1) {
                    if (tokens) |all| all[@intCast(parser.toksuper)].size += 1;
                }
            },
            else => return error.Inval,
        }
    }
    if (tokens) |all| {
        var i = parser.toknext;
        while (i > 0) {
            i -= 1;
            if (all[i].start != -1 and all[i].end == -1) return error.Part;
        }
    }
    return count;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "jsmn tokenizes nested values with parent links" {
    var tokens: [8]Token = undefined;
    var parser: Parser = .{};
    const n = try parse(&parser, "{\"a\":[1,true]}", &tokens);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(TokenType.object, tokens[0].type);
    try testing.expectEqual(@as(i32, 1), tokens[0].size);
    try testing.expectEqual(@as(i32, 2), tokens[2].size);
    try testing.expectEqual(@as(i32, 2), tokens[3].parent);
}

test "jsmn rejects what strict mode rejects" {
    var tokens: [8]Token = undefined;
    var parser: Parser = .{};
    try testing.expectError(error.Inval, parse(&parser, "{1:2}", &tokens));
    parser = .{};
    try testing.expectError(error.Part, parse(&parser, "[1", &tokens));
    parser = .{};
    try testing.expectError(error.Part, parse(&parser, "5", &tokens));
}
