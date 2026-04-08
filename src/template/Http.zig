//! This module contains everything necessary to tokenize and parse
//! a route string into a functioning route object.
//!
//! A route string is defined as follows:
//! ```ebnf
//! Route ::= [ ModifierList ] " " Verb " " Path [ " @" Identifier ]
//! ModifierList ::= Modifier ( " "  Modifier)*
//! Modifier ::= "provide"
//! Verb ::= "get" | "post" | "put" | "patch" | "delete" | "options" | "head" | "trace" | "connect"
//! Identifier ::= ( Letter | Digit | "_" | "-" | "$")+
//! Letter         ::= "a"..."z" | "A"..."Z"
//! Digit          ::= "0"..."9"
//! Path ::= PathSegment ( "/" PathSegment )
//! PathSegment ::= Identifier | RouteCapture | RouteParameter
//! RouteCapture ::= "{" DirectPath | WildcardCapture "}"
//! DirectPath ::= Identifier ( "." Identifier )*
//! WildcardCapture ::= "*" DirectPath
//! RouteParameter ::= "[" DirectPath | UnwrappedParameter "]"
//! UnwrappedParameter ::= "..." DirectPath
//! ```

const std = @import("std");
const Resolver = @import("../utils/resolver.zig").Resolver;

pub const Lexer = struct {
    const Kind = enum {
        identifier,
        get,
        post,
        put,
        patch,
        delete,
        options,
        head,
        trace,
        connect,
        provide,
        route_separator,
        atsign,
        wildcard,
        spread,
        rbracket,
        lbracket,
        rbrace,
        lbrace,
        eof,
    };

    const Token = struct {
        kind: Kind,
        lexeme: []const u8,
        start: usize,
        end: usize,
    };

    const State = enum {
        begin,
        identifier,
        whitespace,
        eof,
    };

    fn peek(comptime buffer: []const u8, comptime cursor: usize) u8 {
        if (buffer.len <= cursor) @compileError("http: Buffer overflow during http route compilation.");
        return buffer[cursor];
    }

    fn match(comptime buffer: []const u8, comptime cursor: usize, comptime expected: []const u8) bool {
        if (buffer.len <= cursor + expected.len) return false;
        return std.mem.eql(u8, buffer[cursor .. cursor + expected.len], expected);
    }

    fn matchInsensitive(comptime buffer: []const u8, comptime cursor: usize, comptime expected: []const u8) bool {
        if (buffer.len <= cursor + expected.len) return false;
        return std.ascii.eqlIgnoreCase(buffer[cursor .. cursor + expected.len], expected);
    }

    fn new(comptime kind: Kind, comptime buffer: []const u8, comptime start: usize, comptime end: usize) Token {
        return comptime Token{
            .kind = kind,
            .lexeme = buffer[start..end],
            .start = start,
            .end = end,
        };
    }

    pub fn debug(comptime tokens: []const Token, comptime buffer: []const u8) void {
        _ = buffer;
        for (tokens) |t| {
            switch (t.kind) {
                else => @compileLog(t),
            }
        }
    }

    pub fn lex(comptime buffer: []const u8) []const Token {
        @setEvalBranchQuota(10000);
        return comptime blk: {
            var tokens: []const Token = &.{};
            var cursor: usize = 0;
            state: switch (State.begin) {
                .begin => {
                    if (buffer.len <= cursor) continue :state .eof;
                    const start = cursor;
                    const next = peek(buffer, cursor);
                    switch (next) {
                        'g', 'G' => {
                            if (matchInsensitive(buffer, cursor, "get")) {
                                cursor += 3;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.get, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 3,
                                }
                            }
                            continue :state .identifier;
                        },
                        'p', 'P' => {
                            cursor += 1;
                            const n = peek(buffer, cursor);
                            switch (n) {
                                'a', 'A' => {
                                    if (matchInsensitive(buffer, cursor, "atch")) {
                                        cursor += 4;
                                        switch (peek(buffer, cursor)) {
                                            ' ', '\r', '\t' => {
                                                tokens = tokens ++ .{new(.patch, buffer, start, cursor)};
                                                continue :state .begin;
                                            },
                                            else => cursor -= 5,
                                        }
                                    }
                                },
                                'u', 'U' => {
                                    if (matchInsensitive(buffer, cursor, "ut")) {
                                        cursor += 2;
                                        switch (peek(buffer, cursor)) {
                                            ' ', '\r', '\t' => {
                                                tokens = tokens ++ .{new(.put, buffer, start, cursor)};
                                                continue :state .begin;
                                            },
                                            else => cursor -= 3,
                                        }
                                    }
                                },
                                'o', 'O' => {
                                    if (matchInsensitive(buffer, cursor, "ost")) {
                                        cursor += 3;
                                        switch (peek(buffer, cursor)) {
                                            ' ', '\r', '\t' => {
                                                tokens = tokens ++ .{new(.post, buffer, start, cursor)};
                                                continue :state .begin;
                                            },
                                            else => cursor -= 4,
                                        }
                                    }
                                },
                                'r', 'R' => {
                                    if (matchInsensitive(buffer, cursor, "rovide")) {
                                        cursor += 6;
                                        switch (peek(buffer, cursor)) {
                                            ' ', '\r', '\t' => {
                                                tokens = tokens ++ .{new(.provide, buffer, start, cursor)};
                                                continue :state .begin;
                                            },
                                            else => cursor -= 7,
                                        }
                                    }
                                },
                                else => cursor -= 1,
                            }
                            continue :state .identifier;
                        },
                        'c', 'C' => {
                            if (matchInsensitive(buffer, cursor, "connect")) {
                                cursor += 7;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.connect, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 7,
                                }
                            }
                            continue :state .identifier;
                        },
                        'd', 'D' => {
                            if (matchInsensitive(buffer, cursor, "delete")) {
                                cursor += 6;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.delete, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 6,
                                }
                            }
                            continue :state .identifier;
                        },
                        'h', 'H' => {
                            if (matchInsensitive(buffer, cursor, "head")) {
                                cursor += 4;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.head, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 4,
                                }
                            }
                            continue :state .identifier;
                        },
                        'o', 'O' => {
                            if (matchInsensitive(buffer, cursor, "options")) {
                                cursor += 7;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.options, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 7,
                                }
                            }
                            continue :state .identifier;
                        },
                        't', 'T' => {
                            if (matchInsensitive(buffer, cursor, "trace")) {
                                cursor += 5;
                                switch (peek(buffer, cursor)) {
                                    ' ', '\r', '\t' => {
                                        tokens = tokens ++ .{new(.trace, buffer, start, cursor)};
                                        continue :state .begin;
                                    },
                                    else => cursor -= 5,
                                }
                            }
                            continue :state .identifier;
                        },
                        'a'...'b',
                        'e'...'f',
                        'i'...'n',
                        'q'...'s',
                        'u'...'z',
                        'A'...'B',
                        'E'...'F',
                        'I'...'N',
                        'Q'...'S',
                        'U'...'Z',
                        '0'...'9',
                        '_',
                        '-',
                        '$',
                        => continue :state .identifier,
                        ' ', '\t', '\r' => continue :state .whitespace,
                        '.' => {
                            if (match(buffer, cursor, "...")) {
                                cursor += 3;
                                tokens = tokens ++ .{new(.spread, buffer, start, cursor)};
                                continue :state .begin;
                            } else {
                                @compileError(std.fmt.comptimePrint(
                                    "Encountered unexpected '.'. '.' is only allowed as part of a path expression or the spread operator.\nAt char {d}, \ncontext: {s}\n{s}^",
                                    .{
                                        cursor,
                                        buffer[@max(0, cursor -| 20)..@min(buffer.len, cursor +| 20)],
                                        @as([cursor - @max(0, cursor -| 20) + 9]u8, @splat('-')),
                                    },
                                ));
                            }
                        },
                        '[' => {
                            tokens = tokens ++ .{new(.lbracket, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        ']' => {
                            tokens = tokens ++ .{new(.rbracket, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        '{' => {
                            tokens = tokens ++ .{new(.lbrace, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        '}' => {
                            tokens = tokens ++ .{new(.rbrace, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        '/' => {
                            tokens = tokens ++ .{new(.route_separator, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        '*' => {
                            tokens = tokens ++ .{new(.wildcard, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        '@' => {
                            tokens = tokens ++ .{new(.atsign, buffer, cursor, cursor + 1)};
                            cursor += 1;
                            continue :state .begin;
                        },
                        else => @compileError(std.fmt.comptimePrint(
                            "Encountered unexpected character '{c}'.\nAt char {d}, \ncontext: {s}\n{s}^",
                            .{
                                next,
                                cursor,
                                buffer[@max(0, cursor -| 20)..@min(buffer.len, cursor +| 20)],
                                @as([cursor - @max(0, cursor -| 20) + 9]u8, @splat('-')),
                            },
                        )),
                    }
                },
                .identifier => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{new(.identifier, buffer, start, cursor)};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '$', '.' => {
                                cursor += 1;
                                continue;
                            },
                            else => {
                                tokens = tokens ++ .{new(.identifier, buffer, start, cursor)};
                                continue :state .begin;
                            },
                        }
                    }
                },
                .whitespace => {
                    while (true) {
                        if (buffer.len == cursor) {
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            ' ', '\t', '\r' => {
                                cursor += 1;
                                continue;
                            },
                            else => continue :state .begin,
                        }
                    }
                },
                .eof => {
                    if (buffer.len == cursor) {
                        tokens = tokens ++ .{new(
                            .eof,
                            buffer,
                            cursor,
                            cursor,
                        )};
                        break :state;
                    }
                    @compileError("http: Tokenizing EOF, yet buffer is not empty?");
                },
            }

            break :blk tokens;
        };
    }

    test "basic_get" {
        const tokens = comptime Lexer.lex("GET /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.get, tokens[0].kind);
        try std.testing.expectEqualStrings("GET", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_post" {
        const tokens = comptime Lexer.lex("POST /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.post, tokens[0].kind);
        try std.testing.expectEqualStrings("POST", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_put" {
        const tokens = comptime Lexer.lex("PUT /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.put, tokens[0].kind);
        try std.testing.expectEqualStrings("PUT", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_patch" {
        const tokens = comptime Lexer.lex("PATCH /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.patch, tokens[0].kind);
        try std.testing.expectEqualStrings("PATCH", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_head" {
        const tokens = comptime Lexer.lex("HEAD /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.head, tokens[0].kind);
        try std.testing.expectEqualStrings("HEAD", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_options" {
        const tokens = comptime Lexer.lex("OPTIONS /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.options, tokens[0].kind);
        try std.testing.expectEqualStrings("OPTIONS", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_connect" {
        const tokens = comptime Lexer.lex("CONNECT /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.connect, tokens[0].kind);
        try std.testing.expectEqualStrings("CONNECT", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_trace" {
        const tokens = comptime Lexer.lex("TRACE /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.trace, tokens[0].kind);
        try std.testing.expectEqualStrings("TRACE", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "basic_delete" {
        const tokens = comptime Lexer.lex("DELETE /api");
        try std.testing.expectEqual(4, tokens.len);
        try std.testing.expectEqual(Kind.delete, tokens[0].kind);
        try std.testing.expectEqualStrings("DELETE", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[1].kind);
        try std.testing.expectEqualStrings("/", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[2].kind);
        try std.testing.expectEqualStrings("api", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.eof, tokens[3].kind);
    }

    test "complex_post" {
        const tokens = comptime Lexer.lex(
            "PROVIDE POST /api/[a.var0.len]/[...b]/{cap}/{*wild} @test",
        );
        try std.testing.expectEqual(25, tokens.len);
        try std.testing.expectEqual(Kind.provide, tokens[0].kind);
        try std.testing.expectEqualStrings("PROVIDE", tokens[0].lexeme);
        try std.testing.expectEqual(Kind.post, tokens[1].kind);
        try std.testing.expectEqualStrings("POST", tokens[1].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[2].kind);
        try std.testing.expectEqualStrings("/", tokens[2].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[3].kind);
        try std.testing.expectEqualStrings("api", tokens[3].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[4].kind);
        try std.testing.expectEqualStrings("/", tokens[4].lexeme);
        try std.testing.expectEqual(Kind.lbracket, tokens[5].kind);
        try std.testing.expectEqualStrings("[", tokens[5].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[6].kind);
        try std.testing.expectEqualStrings("a.var0.len", tokens[6].lexeme);
        try std.testing.expectEqual(Kind.rbracket, tokens[7].kind);
        try std.testing.expectEqualStrings("]", tokens[7].lexeme);
        try std.testing.expectEqual(Kind.route_separator, tokens[8].kind);
        try std.testing.expectEqualStrings("/", tokens[8].lexeme);
        try std.testing.expectEqual(Kind.lbracket, tokens[9].kind);
        try std.testing.expectEqualStrings("[", tokens[9].lexeme);
        try std.testing.expectEqual(Kind.spread, tokens[10].kind);
        try std.testing.expectEqualStrings("...", tokens[10].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[11].kind);
        try std.testing.expectEqualStrings("b", tokens[11].lexeme);
        try std.testing.expectEqual(Kind.rbracket, tokens[12].kind);
        try std.testing.expectEqualStrings("]", tokens[12].lexeme);

        try std.testing.expectEqual(Kind.route_separator, tokens[13].kind);
        try std.testing.expectEqualStrings("/", tokens[13].lexeme);
        try std.testing.expectEqual(Kind.lbrace, tokens[14].kind);
        try std.testing.expectEqualStrings("{", tokens[14].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[15].kind);
        try std.testing.expectEqualStrings("cap", tokens[15].lexeme);
        try std.testing.expectEqual(Kind.rbrace, tokens[16].kind);
        try std.testing.expectEqualStrings("}", tokens[16].lexeme);

        try std.testing.expectEqual(Kind.route_separator, tokens[17].kind);
        try std.testing.expectEqualStrings("/", tokens[17].lexeme);
        try std.testing.expectEqual(Kind.lbrace, tokens[18].kind);
        try std.testing.expectEqualStrings("{", tokens[18].lexeme);
        try std.testing.expectEqual(Kind.wildcard, tokens[19].kind);
        try std.testing.expectEqualStrings("*", tokens[19].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[20].kind);
        try std.testing.expectEqualStrings("wild", tokens[20].lexeme);
        try std.testing.expectEqual(Kind.rbrace, tokens[21].kind);
        try std.testing.expectEqualStrings("}", tokens[21].lexeme);

        try std.testing.expectEqual(Kind.atsign, tokens[22].kind);
        try std.testing.expectEqualStrings("@", tokens[22].lexeme);
        try std.testing.expectEqual(Kind.identifier, tokens[23].kind);
        try std.testing.expectEqualStrings("test", tokens[23].lexeme);

        try std.testing.expectEqual(Kind.eof, tokens[24].kind);
    }
};

const Parser = struct {
    const HttpVerb = enum {
        get,
        head,
        options,
        connect,
        trace,
        put,
        post,
        patch,
        delete,
    };

    pub const Mods = packed struct(u8) {
        provider: bool = false,
        _: u7 = 0,
    };

    pub const Node = union(enum) {
        route: struct {
            modifiers: Mods,
            verb: HttpVerb,
            path: *const Node,
            identifier: ?[]const u8 = null,
        },
        static_path_segment: struct {
            segm: []const u8,
            next: ?*const Node = null,
        },
        path_capture: struct {
            pattern: []const u8,
            wildcard: bool = false,
            next: ?*const Node = null,
        },
        path_parameter: struct {
            pattern: []const u8,
            spread: bool = false,
            next: ?*const Node = null,
        },
        composite_segment: struct {
            left: *const Node,
            right: *const Node,
        },
    };

    fn matches(tokens: []const Lexer.Token, comptime cursor: usize, comptime expected: Lexer.Kind) bool {
        if (tokens.len <= cursor) @compileError("http: Buffer overflow while parsing http route expression.");
        return tokens[cursor].kind == expected;
    }

    fn consume(tokens: []const Lexer.Token, comptime cursor: *usize, comptime expected: Lexer.Kind) Lexer.Token {
        if (matches(tokens, cursor.*, expected)) {
            defer cursor.* += 1;
            return tokens[cursor.*];
        }
        @compileError("cron: Wrong token type. Expected " ++ @tagName(expected) ++ ", found: " ++ @tagName(tokens[cursor.*].kind));
    }

    fn parsePathSegment(
        comptime tokens: []const Lexer.Token,
        comptime cursor: *usize,
        comptime buffer: []const u8,
    ) ?Node {
        if (matches(tokens, cursor.*, .route_separator)) {
            _ = consume(tokens, cursor, .route_separator);
        }
        const next = tokens[cursor.*];
        switch (next.kind) {
            .identifier => {
                _ = consume(tokens, cursor, .identifier);
                if (matches(tokens, cursor.*, .route_separator) or
                    matches(tokens, cursor.*, .atsign) or
                    matches(tokens, cursor.*, .eof))
                {
                    const n = parsePathSegment(tokens, cursor, buffer);
                    return .{
                        .static_path_segment = .{
                            .segm = next.lexeme,
                            .next = if (n) |*o| o else null,
                        },
                    };
                }
                const l: Node = .{ .static_path_segment = .{
                    .segm = next.lexeme,
                    .next = null,
                } };
                const r = parsePathSegment(tokens, cursor, buffer) orelse
                    @compileError("TODO");
                return .{
                    .composite_segment = .{
                        .left = &l,
                        .right = &r,
                    },
                };
            },
            .lbrace => {
                _ = consume(tokens, cursor, .lbrace);
                const wildcard = if (matches(tokens, cursor.*, .wildcard)) blk: {
                    _ = consume(tokens, cursor, .wildcard);
                    break :blk true;
                } else false;
                const pattern = consume(tokens, cursor, .identifier);
                _ = consume(tokens, cursor, .rbrace);

                if ((!wildcard and matches(tokens, cursor.*, .route_separator)) or
                    matches(tokens, cursor.*, .atsign) or
                    matches(tokens, cursor.*, .eof))
                {
                    const n = parsePathSegment(tokens, cursor, buffer);
                    return .{
                        .path_capture = .{
                            .pattern = pattern.lexeme,
                            .wildcard = wildcard,
                            .next = if (n) |*o| o else null,
                        },
                    };
                }
                if (wildcard) @compileError("TODO");
                const l: Node = .{
                    .path_capture = .{
                        .pattern = pattern.lexeme,
                        .wildcard = wildcard,
                        .next = null,
                    },
                };
                const r = parsePathSegment(tokens, cursor, buffer) orelse
                    @compileError("TODO");
                return .{
                    .composite_segment = .{
                        .left = &l,
                        .right = &r,
                    },
                };
            },
            .lbracket => {
                _ = consume(tokens, cursor, .lbracket);
                const spread = if (matches(tokens, cursor.*, .spread)) blk: {
                    _ = consume(tokens, cursor, .spread);
                    break :blk true;
                } else false;
                const pattern = consume(tokens, cursor, .identifier);
                _ = consume(tokens, cursor, .rbracket);

                if (matches(tokens, cursor.*, .route_separator) or
                    matches(tokens, cursor.*, .atsign) or
                    matches(tokens, cursor.*, .eof))
                {
                    const n = parsePathSegment(tokens, cursor, buffer);
                    return .{
                        .path_parameter = .{
                            .pattern = pattern.lexeme,
                            .spread = spread,
                            .next = if (n) |*o| o else null,
                        },
                    };
                }

                const l: Node = .{
                    .path_parameter = .{
                        .pattern = pattern.lexeme,
                        .spread = spread,
                        .next = null,
                    },
                };
                const r = parsePathSegment(tokens, cursor, buffer) orelse
                    @compileError("TODO");
                return .{
                    .composite_segment = .{
                        .left = &l,
                        .right = &r,
                    },
                };
            },
            .eof, .atsign => return null,
            else => |e| @compileError("Bad kind: " ++ @tagName(e)),
        }
    }

    fn parseVerb(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime buffer: []const u8) HttpVerb {
        if (tokens.len <= cursor.*) @compileError("http: Buffer overflow while parsing verb.");
        const next = tokens[cursor.*];
        switch (next.kind) {
            .put,
            .patch,
            .post,
            .options,
            .trace,
            .get,
            .head,
            .connect,
            .delete,
            => |e| {
                _ = consume(tokens, cursor, e);
                const verb = std.meta.stringToEnum(HttpVerb, @tagName(e));
                return verb orelse @compileError("Invalid verb: " ++ @tagName(e));
            },
            inline else => |e| {
                @compileError(std.fmt.comptimePrint(
                    "Expected an http verb. Found {t}:\nAt char {d}..{d},\ncontext: {s}\n{s}{s}",
                    .{
                        e,
                        next.start,
                        next.end,
                        buffer[@max(0, cursor.* -| 20)..@min(buffer.len, cursor.* +| 20)],
                        @as([cursor.* - @max(0, cursor.* -| 20) + 9]u8, @splat(' ')),
                        @as([next.end - next.start]u8, @splat('^')),
                    },
                ));
            },
        }
    }

    fn parseModifier(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime buffer: []const u8) ?Mods {
        _ = buffer;
        if (tokens.len <= cursor.*) @compileError("http: Buffer overflow while parsing modifier.");
        const next = tokens[cursor.*];
        switch (next.kind) {
            .provide => {
                _ = consume(tokens, cursor, .provide);
                return .{ .provider = true };
            },
            else => return null,
        }
    }

    fn parseIdentifier(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime buffer: []const u8) ?[]const u8 {
        _ = buffer;
        if (tokens.len <= cursor.*) @compileError("http: Buffer overflow while parsing identifier.");
        if (matches(tokens, cursor.*, .atsign)) {
            _ = consume(tokens, cursor, .atsign);
        } else return null;

        const next = tokens[cursor.*];
        switch (next.kind) {
            .identifier => {
                _ = consume(tokens, cursor, .identifier);
                return next.lexeme;
            },
            else => @compileError("Invalid identifier. TODO"),
        }
    }

    pub fn parse(comptime buffer: []const u8) Node {
        const tokens = comptime Lexer.lex(buffer);
        comptime {
            @setEvalBranchQuota(tokens.len * 20);
            var cursor: usize = 0;
            var mods: u8 = 0;
            while (parseModifier(tokens, &cursor, buffer)) |mod| {
                mods |= @bitCast(mod);
            }

            const verb = parseVerb(tokens, &cursor, buffer);
            const path = parsePathSegment(tokens, &cursor, buffer) orelse
                @compileError("TODO");

            const identifier = parseIdentifier(tokens, &cursor, buffer);

            _ = consume(tokens, &cursor, .eof);

            return .{
                .route = .{
                    .modifiers = @bitCast(mods),
                    .verb = verb,
                    .path = &path,
                    .identifier = identifier,
                },
            };
        }
    }

    test "parse simple get" {
        const parsed = comptime Parser.parse("GET /api");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqualStrings("api", parsed.route.path.static_path_segment.segm);
        try std.testing.expectEqual(null, parsed.route.path.static_path_segment.next);
    }

    test "parse simple get with identifier" {
        const parsed = comptime Parser.parse("GET /api @identifier");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqualStrings("api", parsed.route.path.static_path_segment.segm);
        try std.testing.expectEqual(null, parsed.route.path.static_path_segment.next);
        try std.testing.expect(parsed.route.identifier != null);
        try std.testing.expectEqualStrings("identifier", parsed.route.identifier.?);
    }

    test "parse modifier" {
        const parsed = comptime Parser.parse("PROVIDE GET /api");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(true, parsed.route.modifiers.provider);
        try std.testing.expectEqualStrings("api", parsed.route.path.static_path_segment.segm);
        try std.testing.expectEqual(null, parsed.route.path.static_path_segment.next);
    }

    test "parse deep route" {
        const parsed = comptime Parser.parse("GET /api/v1/user/configuration/id");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        var n = parsed.route.path.static_path_segment;
        try std.testing.expectEqualStrings("api", n.segm);
        n = n.next.?.static_path_segment;
        try std.testing.expectEqualStrings("v1", n.segm);
        n = n.next.?.static_path_segment;
        try std.testing.expectEqualStrings("user", n.segm);
        n = n.next.?.static_path_segment;
        try std.testing.expectEqualStrings("configuration", n.segm);
        n = n.next.?.static_path_segment;
        try std.testing.expectEqualStrings("id", n.segm);
    }

    test "parse capture" {
        const parsed = comptime Parser.parse("GET /{id}");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        const n = parsed.route.path.path_capture;
        try std.testing.expectEqualStrings("id", n.pattern);
        try std.testing.expectEqual(false, n.wildcard);
        try std.testing.expectEqual(null, n.next);
    }

    test "parse wildcard capture" {
        const parsed = comptime Parser.parse("GET /{*id}");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        const n = parsed.route.path.path_capture;
        try std.testing.expectEqualStrings("id", n.pattern);
        try std.testing.expectEqual(true, n.wildcard);
        try std.testing.expectEqual(null, n.next);
    }

    test "parse partial capture" {
        const parsed = comptime Parser.parse("GET /player-{id}-active");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        var n = parsed.route.path.composite_segment;
        try std.testing.expectEqualStrings("player-", n.left.static_path_segment.segm);
        n = n.right.composite_segment;
        try std.testing.expectEqualStrings("id", n.left.path_capture.pattern);
        try std.testing.expectEqualStrings("-active", n.right.static_path_segment.segm);
    }

    test "parse parameter" {
        const parsed = comptime Parser.parse("GET /[id]");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        const n = parsed.route.path.path_parameter;
        try std.testing.expectEqualStrings("id", n.pattern);
        try std.testing.expectEqual(false, n.spread);
        try std.testing.expectEqual(null, n.next);
    }

    test "parse spread parameter" {
        const parsed = comptime Parser.parse("GET /[...id]");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        const n = parsed.route.path.path_parameter;
        try std.testing.expectEqualStrings("id", n.pattern);
        try std.testing.expectEqual(true, n.spread);
        try std.testing.expectEqual(null, n.next);
    }

    test "parse partial parameter" {
        const parsed = comptime Parser.parse("GET /player-[id]-active");
        try std.testing.expect(std.meta.activeTag(parsed) == .route);
        try std.testing.expectEqual(.get, parsed.route.verb);
        try std.testing.expectEqual(false, parsed.route.modifiers.provider);
        var n = parsed.route.path.composite_segment;
        try std.testing.expectEqualStrings("player-", n.left.static_path_segment.segm);
        n = n.right.composite_segment;
        try std.testing.expectEqualStrings("id", n.left.path_parameter.pattern);
        try std.testing.expectEqualStrings("-active", n.right.static_path_segment.segm);
    }
};

pub const RouteGen = struct {
    const Segment = union(enum) {
        static: []const u8,
        capture: struct {
            type: type,
            name: []const u8,
            wildcard: bool,
        },
        parameter: struct {
            type: type,
            name: []const u8,
            spread: bool,
        },
        compound: []const Segment,
    };

    const Route = struct {
        method: Parser.HttpVerb,
        modifiers: Parser.Mods,
        identifier: []const u8,
        path: []const Segment,
    };

    pub fn gen(comptime Context: type, comptime Source: type, comptime field_name: []const u8) Route {
        const f = @field(Source, field_name);
        const Fn = @TypeOf(f);
        const Fn_ti = @typeInfo(Fn);
        switch (Fn_ti) {
            .@"fn" => |fn_typeinfo| {
                const parsed = comptime Parser.parse(field_name);
                if (comptime std.meta.activeTag(parsed) != .route) @compileError("Expected field name to parse into a route.");
                const route = parsed.route;
                const method = route.verb;
                const modifiers = route.modifiers;
                const identifier = route.identifier orelse field_name;
                const path = route.path;
                const Segments = genRoute(Context, fn_typeinfo, path, &.{});
                const R = Route{
                    .method = method,
                    .modifiers = modifiers,
                    .identifier = identifier,
                    .path = Segments,
                };
                return R;
            },
            else => @compileError("Invalid route source. Expected function."),
        }
    }

    fn genRoute(comptime Context: type, comptime Fn: std.builtin.Type.Fn, comptime path: *const Parser.Node, comptime segments: []const Segment) []const Segment {
        switch (path.*) {
            .static_path_segment => |s| {
                const next = segments ++ .{Segment{
                    .static = s.segm,
                }};
                if (comptime s.next) |n| {
                    return genRoute(Context, Fn, n, next);
                }
                return next;
            },
            .path_capture => |c| {
                if (comptime Fn.params.len < 1) @compileError("Cannot capture without a target.");
                const Head = Fn.params[0].type orelse @compileError("Invalid capture type");
                const CaptureType = Resolver(Head).resolveType("captures." ++ c.pattern);

                // TODO: We should verify that the type is parsable from a string.

                const next = segments ++ .{Segment{
                    .capture = .{
                        .type = CaptureType,
                        .name = c.pattern,
                        .wildcard = c.wildcard,
                    },
                }};
                if (comptime c.next) |n| {
                    return genRoute(Context, Fn, n, next);
                }

                return next;
            },
            .path_parameter => |c| {
                const ParameterType = Resolver(Context).resolveType(c.pattern);

                if (comptime c.spread) {
                    const ti: std.builtin.Type = @typeInfo(ParameterType);
                    switch (ti) {
                        .pointer => |p| {
                            if (p.size != .slice) @compileError("Invalid context spread type: " ++ @typeName(ParameterType));
                        },
                        else => @compileError("Invalid context spread type: " ++ @typeName(ParameterType)),
                    }
                }

                //TODO: We should verify that the type is formattable into a string.

                const next = segments ++ .{Segment{
                    .parameter = .{
                        .type = ParameterType,
                        .name = c.pattern,
                        .spread = c.spread,
                    },
                }};
                if (comptime c.next) |n| {
                    return genRoute(Context, Fn, n, next);
                }
                return next;
            },
            .composite_segment => |c| {
                const s1 = genRoute(Context, Fn, c.left, &.{});
                const s2 = genRoute(Context, Fn, c.right, s1);
                const s: []const Segment = s2[0..2];
                const rest = s2[2..];
                return segments ++ .{Segment{
                    .compound = s,
                }} ++ rest;
            },
            inline else => @compileError("Not Implemented"),
        }
    }

    test "Generate basic Get route" {
        const T = struct {};

        const H = struct {
            pub fn @"GET /api/v1/route"() T {
                return .{};
            }
        };

        const route = gen(struct {}, H, "GET /api/v1/route");
        try std.testing.expectEqual(.get, route.method);
        try std.testing.expectEqual(false, route.modifiers.provider);
        try std.testing.expectEqualStrings("GET /api/v1/route", route.identifier);
        try std.testing.expectEqual(3, route.path.len);
    }

    test "Generate Get route with captures" {
        const T = struct {};

        const H = struct {
            pub fn @"GET /api/v1/route/{id}"(target: struct {
                captures: struct {
                    id: u64,
                },
            }) T {
                _ = target;
                return .{};
            }
        };

        _ = gen(struct {}, H, "GET /api/v1/route/{id}");
    }

    test "Generate Get route with composite captures" {
        const T = struct {};

        const H = struct {
            pub fn @"GET /api/v1/route/{id}${*action}"(target: struct {
                captures: struct {
                    id: u64,
                    action: []const u8,
                },
            }) T {
                _ = target;
                return .{};
            }
        };

        _ = gen(struct {}, H, "GET /api/v1/route/{id}${*action}");
    }

    test "Generate Get route with params" {
        const T = struct {};
        const Context = struct { id: u64 };

        const H = struct {
            pub fn @"GET /api/v1/route/[id]"() T {
                return .{};
            }
        };

        _ = gen(Context, H, "GET /api/v1/route/[id]");
    }

    test "Generate Get route with compound parameters" {
        const T = struct {};
        const Context = struct { id: []const u64, user_id: []const u8 };

        const H = struct {
            pub fn @"GET /api/v1/route/[user_id]-[...id]/get"() T {
                return .{};
            }
        };

        _ = gen(Context, H, "GET /api/v1/route/[user_id]-[...id]/get");
    }
};

test {
    _ = Lexer;
    _ = Parser;
    _ = RouteGen;
}
