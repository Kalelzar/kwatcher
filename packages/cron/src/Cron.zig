// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

test {
    _ = Lexer;
    _ = Parser;
    _ = VM;
}

pub const Lexer = struct {
    pub const Kind = enum {
        whitespace,
        number,
        wildcard,
        list,
        range,
        step,
        name,
        eof,
    };

    pub const Token = struct {
        kind: Kind,
        lexeme: []const u8,
        start: usize,
        end: usize,
    };

    const State = enum {
        begin,
        name,
        number,
        whitespace,
        wildcard,
        step,
        list,
        range,
        eof,
        debug,
    };

    fn peek(comptime buffer: []const u8, comptime cursor: usize) u8 {
        if (buffer.len <= cursor) @compileError("cron: Buffer overflow during cron statement compilation.");
        return buffer[cursor];
    }

    pub fn debug(comptime tokens: []const Token, comptime buffer: []const u8) void {
        for (tokens) |t| {
            switch (t.kind) {
                .number => {
                    const num = std.fmt.parseInt(u6, buffer[t.start..t.end], 10) catch unreachable;
                    const lnum = std.fmt.parseInt(u6, t.lexeme, 10) catch unreachable;
                    @compileLog(num);
                    @compileLog(lnum);
                },
                else => @compileLog(t),
            }
        }
    }

    pub fn lex(comptime buffer: []const u8) []const Token {
        return comptime blk: {
            var tokens: []const Token = &.{};
            var cursor: usize = 0;
            state: switch (State.begin) {
                .begin => {
                    const next = peek(buffer, cursor);
                    switch (next) {
                        'a'...'z', 'A'...'Z', '_' => continue :state .name,
                        '0'...'9' => continue :state .number,
                        ' ' => continue :state .whitespace,
                        '*' => continue :state .wildcard,
                        else => @compileError("cron: Invalid start of cron expression."),
                    }
                },
                .whitespace => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            // Just discard it, who cares at this point.
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            ' ' => {
                                cursor += 1;
                                continue;
                            },
                            '0'...'9' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .whitespace,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .number;
                            },
                            'a'...'z', 'A'...'Z', '_' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .whitespace,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .name;
                            },
                            '*' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .whitespace,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .wildcard;
                            },
                            else => @compileError("cron: Invalid character found."),
                        }
                    }
                },
                .name => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .name,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                                cursor += 1;
                                continue;
                            },
                            ' ' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .name,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .whitespace;
                            },
                            else => @compileError("cron: Invalid name expression."),
                        }
                    }
                },
                .number => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .number,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            '0'...'9' => {
                                cursor += 1;
                                continue;
                            },
                            ' ' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .number,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .whitespace;
                            },
                            ',' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .number,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .list;
                            },
                            '-' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .number,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .range;
                            },
                            '/' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .number,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .step;
                            },
                            else => @compileError("cron: Invalid number expression."),
                        }
                    }
                },
                .wildcard => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .wildcard,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            '0'...'9' => {
                                @compileError("cron(wildcard): Invalid continuation. Expected '/' or whitespace. Found number.");
                            },
                            'a'...'z', 'A'...'Z', '_' => {
                                @compileError("cron(wildcard): Invalid continuation. Expected '/' or whitespace. Found name.");
                            },
                            ',' => {
                                @compileError("cron(wildcard): Invalid continuation. Expected '/' or whitespace. Found list.");
                            },
                            '-' => {
                                @compileError("cron(wildcard): Invalid continuation. Expected '/' or whitespace. Found range.");
                            },
                            '*' => {
                                if (start == cursor) {
                                    cursor += 1;
                                    continue;
                                }
                                @compileError("cron(wildcard): Invalid continuation. Expected '/' or whitespace. Found wildcard.");
                            },
                            ' ' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .wildcard,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .whitespace;
                            },
                            '/' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .wildcard,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .step;
                            },
                            else => @compileError("cron: Invalid wildcard expression."),
                        }
                    }
                },
                .step => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .step,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            '0'...'9' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .step,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .number;
                            },
                            'a'...'z', 'A'...'Z', '_' => {
                                @compileError("cron(step): Invalid continuation. Expected number. Found name.");
                            },
                            ',' => {
                                @compileError("cron(step): Invalid continuation. Expected number. Found list.");
                            },
                            '-' => {
                                @compileError("cron(step): Invalid continuation. Expected number. Found range.");
                            },
                            '*' => {
                                @compileError("cron(step): Invalid continuation. Expected number. Found wildcard.");
                            },
                            ' ' => {
                                @compileError("cron(step): Invalid continuation. Expected number. Found whitespace.");
                            },
                            '/' => {
                                if (start == cursor) {
                                    cursor += 1;
                                    continue;
                                }
                                @compileError("cron(step): Invalid continuation. Expected number. Found step.");
                            },
                            else => @compileError("cron: Invalid step expression."),
                        }
                    }
                },
                .range => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .range,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            '0'...'9' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .range,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .number;
                            },
                            'a'...'z', 'A'...'Z', '_' => {
                                @compileError("cron(range): Invalid continuation. Expected number. Found name.");
                            },
                            ',' => {
                                @compileError("cron(range): Invalid continuation. Expected number. Found list.");
                            },
                            '-' => {
                                if (start == cursor) {
                                    cursor += 1;
                                    continue;
                                }
                                @compileError("cron(range): Invalid continuation. Expected number. Found range.");
                            },
                            '*' => {
                                @compileError("cron(range): Invalid continuation. Expected number. Found wildcard.");
                            },
                            ' ' => {
                                @compileError("cron(range): Invalid continuation. Expected number. Found whitespace.");
                            },
                            '/' => {
                                @compileError("cron(range): Invalid continuation. Expected number. Found step.");
                            },
                            else => @compileError("cron: Invalid range expression."),
                        }
                    }
                },
                .list => {
                    const start = cursor;
                    while (true) {
                        if (buffer.len == cursor) {
                            tokens = tokens ++ .{Token{
                                .kind = .list,
                                .lexeme = buffer[start..cursor],
                                .start = start,
                                .end = cursor,
                            }};
                            continue :state .eof;
                        }
                        const next = peek(buffer, cursor);
                        switch (next) {
                            '0'...'9' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .list,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .number;
                            },
                            'a'...'z', 'A'...'Z', '_' => {
                                @compileError("cron(list): Invalid continuation. Expected number or wildcard. Found name.");
                            },
                            ',' => {
                                if (start == cursor) {
                                    cursor += 1;
                                    continue;
                                }
                                @compileError("cron(list): Invalid continuation. Expected number or wildcard. Found list.");
                            },
                            '-' => {
                                @compileError("cron(list): Invalid continuation. Expected number or wildcard. Found range.");
                            },
                            '*' => {
                                tokens = tokens ++ .{Token{
                                    .kind = .list,
                                    .lexeme = buffer[start..cursor],
                                    .start = start,
                                    .end = cursor,
                                }};
                                continue :state .wildcard;
                            },
                            ' ' => {
                                @compileError("cron(list): Invalid continuation. Expected number or wildcard. Found whitespace.");
                            },
                            '/' => {
                                @compileError("cron(list): Invalid continuation. Expected number or wildcard. Found step.");
                            },
                            else => @compileError("cron: Invalid list expression."),
                        }
                    }
                },
                .eof => {
                    if (buffer.len == cursor) {
                        tokens = tokens ++ .{Token{
                            .kind = .eof,
                            .lexeme = buffer[cursor - 1 .. cursor],
                            .start = cursor,
                            .end = cursor,
                        }};
                        break :state;
                    }
                    @compileError("cron: Tokenizing EOF, yet buffer is not empty?");
                },
                else => @compileError("cron: Unimplemented"),
            }

            // @compileLog(tokens);
            break :blk tokens;
        };
    }

    test "shouldParseStartingNumber" {
        const res = lex("10");

        try std.testing.expectEqual(2, res.len);
        try std.testing.expectEqual(Kind.number, res[0].kind);
        try std.testing.expectEqualStrings("10", res[0].lexeme);
        try std.testing.expectEqual(Kind.eof, res[1].kind);
    }

    test "shouldParseWildcard" {
        const res = lex("*");

        try std.testing.expectEqual(2, res.len);
        try std.testing.expectEqual(Kind.wildcard, res[0].kind);
        try std.testing.expectEqualStrings("*", res[0].lexeme);
        try std.testing.expectEqual(Kind.eof, res[1].kind);
    }

    test "shouldParseList" {
        const res = lex("1,2,3");

        try std.testing.expectEqual(6, res.len);
        try std.testing.expectEqual(Kind.number, res[0].kind);
        try std.testing.expectEqualStrings("1", res[0].lexeme);
        try std.testing.expectEqual(Kind.list, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("2", res[2].lexeme);
        try std.testing.expectEqual(Kind.list, res[3].kind);
        try std.testing.expectEqual(Kind.number, res[4].kind);
        try std.testing.expectEqualStrings("3", res[4].lexeme);
        try std.testing.expectEqual(Kind.eof, res[5].kind);
    }

    test "shouldParseWildcardWithStep" {
        const res = lex("*/5");

        try std.testing.expectEqual(4, res.len);
        try std.testing.expectEqual(Kind.wildcard, res[0].kind);
        try std.testing.expectEqualStrings("*", res[0].lexeme);
        try std.testing.expectEqual(Kind.step, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("5", res[2].lexeme);
        try std.testing.expectEqual(Kind.eof, res[3].kind);
    }

    test "shouldParseRangeWithStep" {
        const res = lex("0-30/5");

        try std.testing.expectEqual(6, res.len);
        try std.testing.expectEqual(Kind.number, res[0].kind);
        try std.testing.expectEqualStrings("0", res[0].lexeme);
        try std.testing.expectEqual(Kind.range, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("30", res[2].lexeme);
        try std.testing.expectEqual(Kind.step, res[3].kind);
        try std.testing.expectEqual(Kind.number, res[4].kind);
        try std.testing.expectEqualStrings("5", res[4].lexeme);
        try std.testing.expectEqual(Kind.eof, res[5].kind);
    }

    test "shouldParseMultipleNumbers" {
        const res = lex("10 10     10    10  20");

        try std.testing.expectEqual(10, res.len);
        for (0..4) |i| {
            try std.testing.expectEqual(Kind.number, res[i * 2].kind);
            try std.testing.expectEqualStrings("10", res[i * 2].lexeme);
            try std.testing.expectEqual(Kind.whitespace, res[i * 2 + 1].kind);
        }
        try std.testing.expectEqual(Kind.number, res[8].kind);
        try std.testing.expectEqualStrings("20", res[8].lexeme);
        try std.testing.expectEqual(Kind.eof, res[9].kind);
    }

    test "shouldParseMultipleNumbersStartingWithName" {
        const res = lex("name 10  20");

        try std.testing.expectEqual(6, res.len);
        try std.testing.expectEqual(Kind.name, res[0].kind);
        try std.testing.expectEqualStrings("name", res[0].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("10", res[2].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[3].kind);
        try std.testing.expectEqual(Kind.number, res[4].kind);
        try std.testing.expectEqualStrings("20", res[4].lexeme);
        try std.testing.expectEqual(Kind.eof, res[5].kind);
    }

    test "shouldParseMultipleNumbersStartingWithNameWithInterleavingNames" {
        const res = lex("name 10  20 name2");

        try std.testing.expectEqual(8, res.len);
        try std.testing.expectEqual(Kind.name, res[0].kind);
        try std.testing.expectEqualStrings("name", res[0].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("10", res[2].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[3].kind);
        try std.testing.expectEqual(Kind.number, res[4].kind);
        try std.testing.expectEqualStrings("20", res[4].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[5].kind);
        try std.testing.expectEqual(Kind.name, res[6].kind);
        try std.testing.expectEqualStrings("name2", res[6].lexeme);
        try std.testing.expectEqual(Kind.eof, res[7].kind);
    }

    test "shouldParseStartingName" {
        const res = lex("name");

        try std.testing.expectEqual(2, res.len);
        try std.testing.expectEqual(Kind.name, res[0].kind);
        try std.testing.expectEqualStrings("name", res[0].lexeme);
        try std.testing.expectEqual(Kind.eof, res[1].kind);
    }

    test "shouldParseComplexExpressions" {
        _ = lex("name * * * * * *");
        _ = lex("name 0 * * * * *");
        _ = lex("*/5 * * * * *");
        _ = lex("0-29/5,30-59/10 */5 0,12 * * *");
    }

    test "shouldParseAFullExpressionOfAll0" {
        const res = comptime lex("name 0 0 0 0 0 0");
        try std.testing.expectEqual(14, res.len);
        try std.testing.expectEqual(Kind.name, res[0].kind);
        try std.testing.expectEqualStrings("name", res[0].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[1].kind);
        try std.testing.expectEqual(Kind.number, res[2].kind);
        try std.testing.expectEqualStrings("0", res[2].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[3].kind);
        try std.testing.expectEqual(Kind.number, res[4].kind);
        try std.testing.expectEqualStrings("0", res[4].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[5].kind);
        try std.testing.expectEqual(Kind.number, res[6].kind);
        try std.testing.expectEqualStrings("0", res[6].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[7].kind);
        try std.testing.expectEqual(Kind.number, res[8].kind);
        try std.testing.expectEqualStrings("0", res[8].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[9].kind);
        try std.testing.expectEqual(Kind.number, res[10].kind);
        try std.testing.expectEqualStrings("0", res[10].lexeme);
        try std.testing.expectEqual(Kind.whitespace, res[11].kind);
        try std.testing.expectEqual(Kind.number, res[12].kind);
        try std.testing.expectEqualStrings("0", res[12].lexeme);
        try std.testing.expectEqual(Kind.eof, res[13].kind);
    }
};

pub const Parser = struct {
    const Extent = struct { max: u6, min: u6 };

    pub const Node = union(enum) {
        toplevel: struct {
            seconds: *Node,
            minutes: *Node,
            hours: *Node,
            daysOfMonth: *Node,
            month: *Node,
            daysOfWeek: *Node,
            name: *?Node,
        },
        number: u6,
        name: []const u8,
        wildcard: struct {},
        range: struct { lhs: *const Node, rhs: *const Node },
        step: struct { lhs: *const Node, rhs: *const Node },
        list: struct { lhs: *const Node, rhs: *const Node },
    };

    fn matches(tokens: []const Lexer.Token, comptime cursor: usize, comptime expected: Lexer.Kind) bool {
        if (tokens.len <= cursor) @compileError("cron: Buffer overflow while parsing cron expression.");
        return tokens[cursor].kind == expected;
    }

    fn consume(tokens: []const Lexer.Token, comptime cursor: *usize, comptime expected: Lexer.Kind) Lexer.Token {
        if (matches(tokens, cursor.*, expected)) {
            defer cursor.* += 1;
            return tokens[cursor.*];
        }
        @compileError("cron: Wrong token type. Expected " ++ @tagName(expected) ++ ", found: " ++ @tagName(tokens[cursor.*].kind));
    }

    fn parseName(comptime tokens: []const Lexer.Token, comptime cursor: *usize) Node {
        const name = consume(tokens, cursor, .name);
        return .{
            .name = name.lexeme,
        };
    }

    fn parseUntil(
        comptime tokens: []const Lexer.Token,
        comptime cursor: *usize,
        comptime extent: Extent,
        comptime lhs: *const Node,
        comptime any: []const Lexer.Kind,
    ) Node {
        if (tokens.len <= cursor.*) @compileError("cron: Buffer overflow while parsing expression.");
        const next = tokens[cursor.*];
        if (std.mem.containsAtLeast(Lexer.Kind, any, 1, &.{next.kind})) {
            return lhs.*;
        }
        switch (next.kind) {
            .name => @compileError("cron: Invalid continuation. Expected step, range, list, whitespace or eof. Found name."),
            .list => return parseList(tokens, cursor, extent, lhs),
            .range => return parseRange(tokens, cursor, extent, lhs),
            .step => return parseStep(tokens, cursor, extent, lhs),
            .whitespace, .eof => @compileError("cron: Unexpected end of expression."),
            .number => return parseNumber(tokens, cursor, extent, any),
            .wildcard => return parseWildcard(tokens, cursor, extent, any),
        }
    }

    fn parseStep(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent, comptime lhs: *const Node) Node {
        _ = consume(tokens, cursor, .step);
        const rhs = parseUntil(tokens, cursor, extent, lhs, &.{ .whitespace, .eof, .list, .range, .step });
        const step_node = Node{
            .step = .{
                .lhs = lhs,
                .rhs = &rhs,
            },
        };
        const next = parseUntil(tokens, cursor, extent, &step_node, &.{ .whitespace, .eof, .list });
        if (matches(tokens, cursor.*, .eof) or matches(tokens, cursor.*, .whitespace)) return next;
        return parseUntil(tokens, cursor, extent, &next, &.{ .eof, .whitespace });
    }

    fn parseRange(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent, comptime lhs: *const Node) Node {
        _ = consume(tokens, cursor, .range);
        const rhs = parseUntil(tokens, cursor, extent, lhs, &.{ .whitespace, .eof, .list, .range, .step });
        const range_node = Node{
            .range = .{
                .lhs = lhs,
                .rhs = &rhs,
            },
        };
        const next = parseUntil(tokens, cursor, extent, &range_node, &.{ .whitespace, .eof, .list, .step });
        if (matches(tokens, cursor.*, .eof) or matches(tokens, cursor.*, .whitespace)) return next;
        return parseUntil(tokens, cursor, extent, &next, &.{ .eof, .whitespace });
    }

    fn parseList(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent, comptime lhs: *const Node) Node {
        _ = consume(tokens, cursor, .list);
        const rhs = parseUntil(tokens, cursor, extent, lhs, &.{ .whitespace, .eof, .list });
        const list_node = Node{
            .list = .{
                .lhs = lhs,
                .rhs = &rhs,
            },
        };
        return parseUntil(tokens, cursor, extent, &list_node, &.{ .whitespace, .eof });
    }

    fn parseNumber(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent, until: []const Lexer.Kind) Node {
        comptime {
            const num = consume(tokens, cursor, .number);
            const num_val = std.fmt.parseInt(u6, num.lexeme, 10) catch @compileError("cron: Malformed number: " ++ num.lexeme);
            if (num_val > extent.max) @compileError("Number exceeded allotted extent.");
            if (num_val < extent.min) @compileError("Number is under allotted extent.");
            const num_node = Node{
                .number = num_val,
            };
            return parseUntil(tokens, cursor, extent, &num_node, until);
        }
    }

    fn parseWildcard(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent, until: []const Lexer.Kind) Node {
        comptime {
            _ = consume(tokens, cursor, .wildcard);
            const wc_node = Node{
                .wildcard = .{},
            };
            return parseUntil(tokens, cursor, extent, &wc_node, until);
        }
    }

    fn parseExpression(comptime tokens: []const Lexer.Token, comptime cursor: *usize, comptime extent: Extent) Node {
        if (tokens.len <= cursor.*) @compileError("cron: Buffer overflow while parsing expression.");
        const next = tokens[cursor.*];
        switch (next.kind) {
            .name => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found name."),
            .list => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found list."),
            .range => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found range."),
            .step => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found step."),
            .whitespace => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found whitespace."),
            .eof => @compileError("cron: Invalid start of expression. Expected number or wildcard. Found whitespace."),
            .number => return parseNumber(tokens, cursor, extent, &.{ .eof, .whitespace }),
            .wildcard => return parseWildcard(tokens, cursor, extent, &.{ .eof, .whitespace }),
        }
    }

    pub fn parse(comptime tokens: []const Lexer.Token) Node {
        @setEvalBranchQuota(tokens.len * 40);
        var name: ?Node = null;
        var cursor: usize = 0;
        var steps: [6]Node = undefined;
        const extents: []const Extent = &.{
            Extent{ .min = 0, .max = 59 },
            Extent{ .min = 0, .max = 59 },
            Extent{ .min = 0, .max = 23 },
            Extent{ .min = 1, .max = 31 },
            Extent{ .min = 1, .max = 12 },
            Extent{ .min = 0, .max = 7 },
        };

        switch (tokens[cursor].kind) {
            .name => {
                name = parseName(tokens, &cursor);
                _ = consume(tokens, &cursor, .whitespace);
            },
            else => {},
        }

        for (extents, 0..) |e, i| {
            steps[i] = parseExpression(tokens, &cursor, e);
            _ = consume(tokens, &cursor, if (i == 5) .eof else .whitespace);
        }

        return .{
            .toplevel = .{
                .name = &name,
                .seconds = &steps[0],
                .minutes = &steps[1],
                .hours = &steps[2],
                .daysOfMonth = &steps[3],
                .month = &steps[4],
                .daysOfWeek = &steps[5],
            },
        };
    }

    test "canParseOnlyNumber" {
        const tokens = comptime Lexer.lex("name 6 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseOnlyWildcard" {
        const tokens = comptime Lexer.lex("name * * * * * *");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseWildcardWithStep" {
        const tokens = comptime Lexer.lex("name */5 * * * * *");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseNumberWithStep" {
        const tokens = comptime Lexer.lex("name 5/10,8/10 * * * * *");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseListOfWildcardWithStep" {
        const tokens = comptime Lexer.lex("name */6,*/4 * * * * *");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseMixedList" {
        const tokens = comptime Lexer.lex("name */6,*/4,0-10/2 * * * * *");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseSimpleList" {
        const tokens = comptime Lexer.lex("name 6,7 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseLongList" {
        const tokens = comptime Lexer.lex("name 6,7,8,9,10 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseRange" {
        const tokens = comptime Lexer.lex("name 0-15 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseListsWithRanges" {
        const tokens = comptime Lexer.lex("name 0-15,16-30,31-46 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseRangeWithStep" {
        const tokens = comptime Lexer.lex("name 0-15/5 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }

    test "canParseListOfRangeWithStep" {
        const tokens = comptime Lexer.lex("name 0-15/5,16-30/5,31-45/5 5 4 3 2 1");
        const node = comptime parse(tokens);
        _ = node;
    }
};

pub const VM = struct {
    pub const Schedule = struct {
        seconds: u60,
        minutes: u60,
        hours: u24,
        daysOfMonth: u31,
        months: u12,
        daysOfWeek: u8,
        name: ?[]const u8,

        pub fn init(comptime expr: []const u8) Schedule {
            return parse(expr);
        }
    };

    pub fn parse(comptime expr: []const u8) Schedule {
        comptime {
            const lex = Lexer.lex(expr);
            const node = Parser.parse(lex);
            return evalToplevel(node);
        }
    }

    pub fn evalToplevel(comptime node: Parser.Node) Schedule {
        const name = if (node.toplevel.name.*) |n| n.name else null;
        const seconds = eval(u60, 0, node.toplevel.seconds.*);
        const minutes = eval(u60, 0, node.toplevel.minutes.*);
        const hours = eval(u24, 0, node.toplevel.hours.*);
        const daysOfMonth = eval(u31, 1, node.toplevel.daysOfMonth.*);
        const months = eval(u12, 1, node.toplevel.month.*);
        const daysOfWeek = eval(u8, 1, node.toplevel.daysOfWeek.*);

        return .{
            .name = name,
            .seconds = seconds,
            .minutes = minutes,
            .hours = hours,
            .daysOfMonth = daysOfMonth,
            .months = months,
            .daysOfWeek = daysOfWeek,
        };
    }

    pub fn eval(
        comptime bitfield: type,
        comptime offset: u1,
        comptime node: Parser.Node,
    ) bitfield {
        switch (node) {
            .number => |n| {
                const b: bitfield = 1;
                return (b << n) >> offset;
            },
            .list => |n| {
                const l = eval(bitfield, offset, n.lhs.*);
                const r = eval(bitfield, offset, n.rhs.*);
                return l | r;
            },
            .range => |r| {
                var b: bitfield = 0;
                const bottom = r.lhs.number - offset;
                const top = r.rhs.number - offset;
                if (bottom > top) @compileError("cron: Invalid range. Upper bound is less than the lower bound.");
                inline for (bottom..top + 1) |i| {
                    b = b | @as(bitfield, (1 << i));
                }
                return b;
            },
            .step => |s| {
                const right = s.rhs.number;
                if (right == 0) @compileError("cron: Step cannot be 0.");
                switch (s.lhs.*) {
                    .number => |n| {
                        const start = n - offset;
                        const end = comptime @bitSizeOf(bitfield);
                        comptime var r: bitfield = 0;
                        comptime var i = start;
                        inline while (i < end) : (i += right) {
                            r = r | (1 << i);
                        }
                        return r;
                    },
                    else => |n| {
                        const b = comptime eval(bitfield, offset, n);
                        const start = comptime @ctz(b);
                        const end = comptime (@bitSizeOf(bitfield) - @clz(b));
                        comptime var r: bitfield = 0;
                        comptime var i = start;
                        inline while (i < end) : (i += right) {
                            r = r | (1 << i);
                        }
                        return r & b;
                    },
                }
            },
            .wildcard => {
                const res: bitfield = 0;
                return res -% 1;
            },
            .name => @compileError("Name isn't part of a schedule"),
            .toplevel => @compileError("Incorrect toplevel placement"),
        }
    }

    test "exactSecond" {
        const l = comptime Lexer.lex("0 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b1, val);
    }

    test "exactSecond2" {
        const l = comptime Lexer.lex("4 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b10000, val);
    }

    test "listSecond" {
        const l = comptime Lexer.lex("0,1 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b11, val);
    }

    test "listSecond2" {
        const l = comptime Lexer.lex("0,2,4 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b10101, val);
    }

    test "rangeSecond" {
        const l = comptime Lexer.lex("0-1 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b11, val);
    }

    test "rangeSecond2" {
        const l = comptime Lexer.lex("1-4 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b11110, val);
    }

    test "wildcard" {
        const l = comptime Lexer.lex("* * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b111111111111111111111111111111111111111111111111111111111111, val);
    }

    test "stepSecond" {
        const l = comptime Lexer.lex("*/5 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b000010000100001000010000100001000010000100001000010000100001, val);
    }

    test "stepSecond2" {
        const l = comptime Lexer.lex("*/2 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b010101010101010101010101010101010101010101010101010101010101, val);
    }

    test "stepRangeSecond" {
        const l = comptime Lexer.lex("0-10/2 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b10101010101, val);
    }

    test "stepRangeSecond2" {
        const l = comptime Lexer.lex("10-20/2 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b101010101010000000000, val);
    }

    test "numRangeSecond" {
        const l = comptime Lexer.lex("10/10 * * * * *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.seconds;
        const val = eval(u60, 0, s.*);
        try std.testing.expectEqual(0b000000000100000000010000000001000000000100000000010000000000, val);
    }

    test "numMonth" {
        const l = comptime Lexer.lex("* * * * 1 *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.month;
        const val = eval(u12, 1, s.*);
        try std.testing.expectEqual(0b1, val);
    }

    test "rangeMonth" {
        const l = comptime Lexer.lex("* * * * 3-5 *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.month;
        const val = eval(u12, 1, s.*);
        try std.testing.expectEqual(0b11100, val);
    }

    test "stepMonth" {
        const l = comptime Lexer.lex("* * * * */2 *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.month;
        const val = eval(u12, 1, s.*);
        try std.testing.expectEqual(0b010101010101, val);
    }

    test "numStepMonth" {
        const l = comptime Lexer.lex("* * * * 5/5 *");
        const p = comptime Parser.parse(l);
        const s = p.toplevel.month;
        const val = eval(u12, 1, s.*);
        try std.testing.expectEqual(0b1000010000, val);
    }
};
