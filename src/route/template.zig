//! This module contains everything necessary to tokenize and parse
//! a route string into a functioning route object.
//!
//! A route string is defined as follows:
//! ```ebnf
//! RouteString    ::= MethodDeclaration
//! MethodDeclaration ::= PublishDeclaration | ConsumeDeclaration | ReplyDeclaration
//!
//! PublishDeclaration ::= "publish" [ Modifier ] ":" EventName " " ExchangeName "/" RoutingKey
//! ConsumeDeclaration ::= "consume" [ Modifier ]" " ExchangeName "/" BindingKey [ "/" QueueName ]
//! ReplyDeclaration   ::= "reply" [ Modifier ] " " ExchangeName "/" BindingKey [ "/" QueueName ]
//!
//! EventName      ::= Identifier
//!
//! ExchangeName   ::= PathExpression
//! RoutingKey     ::= PathExpression
//! BindingKey     ::= PathExpression
//! QueueName      ::= PathExpression
//!
//! PathExpression ::= ( Identifier | Parameter )+
//!
//! Parameter      ::= "{" Identifier ( "." Identifier )* "}"
//!
//! Modifier       ::= "!"
//!
//! Identifier     ::= ( Letter | Digit | "_" | "-" | "." )+
//!
//! Letter         ::= "a"..."z" | "A"..."Z"
//! Digit          ::= "0"..."9"
//! ```
//! as an example:
//! `publish:heartbeat amq.topic/invalidate.{client.id}`
//! is read as "on every heartbeat publish to the `amq.topic` exchange with the `invalidate.{client.id}` routing key
//! where client.id is bound to the current client id.

const std = @import("std");
const resolver = @import("resolver.zig");

const injector = @import("../utils/injector.zig");
const InternFmtCache = @import("../utils/intern_fmt_cache.zig");

/// The type of tokens allowed in a route string
const TokenType = enum {
    /// The 'publish' method
    publish,
    /// The 'consume' method
    consume,
    /// The 'reply' method
    reply,
    /// The no record modifier
    norecord,
    /// Any non-special identifier
    identifier,
    /// A separator: One of ':', ' ', '/'.
    /// FIXME: These should probably be separate tokens.
    separator,
    /// A runtime interpolated parameter.
    /// It is any valid identifier surrounded by '{' '}'
    parameter,
};

/// A token scanned from a route string
const Token = struct {
    /// The type of the token
    type: TokenType,
    /// The raw original string of the token.
    lexeme: []const u8,
};

/// A short-cut for comparing strings
fn c(comptime a: []const u8, comptime b: []const u8) bool {
    return comptime std.mem.eql(u8, a, b);
}

/// Parse a comptime route string into a list of tokens.
/// @param source A comptime route string
/// @returns a comptime-known list of tokens.
pub fn scan(comptime source: []const u8) []const Token {
    comptime {
        var point: u64 = 0;
        var mark = 0;
        var tokens: []const Token = &.{};
        while (point < source.len) {
            // The currently considered string
            const string = source[mark .. point + 1];

            const ch = source[point];
            switch (ch) {
                '!' => {
                    if (point != mark) {
                        tokens = tokens ++ .{Token{ .type = .identifier, .lexeme = source[mark..point] }};
                        mark = point;
                    }
                    tokens = tokens ++ .{Token{ .type = .norecord, .lexeme = source[mark..point] }};
                    point += 1;
                    mark = point;
                    continue;
                },
                ' ', '/', ':' => |sep| {
                    if (point - mark == 0) {
                        tokens = tokens ++ .{Token{ .type = .separator, .lexeme = source[mark .. point + 1] }};
                        while (point < source.len and source[point] == sep) {
                            point += 1;
                        }
                        mark = point;
                        continue;
                    }
                    tokens = tokens ++ .{Token{ .type = .identifier, .lexeme = source[mark..point] }};
                    tokens = tokens ++ .{Token{ .type = .separator, .lexeme = source[point .. point + 1] }};
                    point += 1;
                    mark = point;
                    continue;
                },
                '{' => {
                    if (point != mark) {
                        tokens = tokens ++ .{Token{ .type = .identifier, .lexeme = source[mark..point] }};
                        mark = point;
                    }
                    while (source[point] != '}' and point < source.len) {
                        point += 1;
                        switch (source[point]) {
                            ' ', '/', ':' => {
                                @compileError("Unclosed parameter here: '" ++ source[mark .. point + 1] ++ "' while parsing '" ++ source ++ "'.");
                            },
                            else => {},
                        }
                    }
                    if (point == source.len) {
                        @compileError("Unexpected EOF in parameter: '" ++ source[mark .. point + 1] ++ "' while parsing '" ++ source ++ "'.");
                    }

                    tokens = tokens ++ .{Token{ .type = .parameter, .lexeme = source[mark + 1 .. point] }};
                    point += 1;
                    mark = point;
                    continue;
                },
                else => {},
            }

            const normalized: []const u8 = blk: {
                var source_buf: [string.len]u8 = undefined;
                _ = std.ascii.lowerString(&source_buf, string);
                const output = source_buf;
                break :blk &output;
            };

            const token: Token =
                if (c("publish", normalized))
                    .{ .type = .publish, .lexeme = normalized }
                else if (c("consume", normalized))
                    .{ .type = .consume, .lexeme = normalized }
                else if (c("reply", normalized))
                    .{ .type = .reply, .lexeme = normalized }
                else {
                    point += 1;
                    continue;
                };

            point += 1;
            mark = point;
            tokens = tokens ++ .{token};
        }

        if (mark != point and point <= source.len) {
            tokens = tokens ++ .{Token{ .type = .identifier, .lexeme = source[mark..point] }};
        }

        return tokens;
    }
}

test "scan should tokenize a publish method" {
    const res = comptime scan("publish");
    try std.testing.expectEqual(res.len, 1);
    const token = res[0];
    try std.testing.expectEqualStrings(token.lexeme, "publish");
    try std.testing.expectEqual(token.type, TokenType.publish);
}

test "scan should tokenize a reply method" {
    const res = comptime scan("reply");
    try std.testing.expectEqual(res.len, 1);
    const token = res[0];
    try std.testing.expectEqualStrings(token.lexeme, "reply");
    try std.testing.expectEqual(token.type, TokenType.reply);
}

test "scan should tokenize a consume method" {
    const res = comptime scan("consume");
    try std.testing.expectEqual(res.len, 1);
    const token = res[0];
    try std.testing.expectEqualStrings(token.lexeme, "consume");
    try std.testing.expectEqual(token.type, TokenType.consume);
}

test "scan should tokenize methods as case-insensitive" {
    const res1 = comptime scan("rEpLy");
    const res2 = comptime scan("RePlY");
    try std.testing.expectEqualDeep(res1, res2);
}

test "scan should tokenize separators" {
    const colon = comptime scan(":");
    const slash = comptime scan("/");
    const space = comptime scan(" ");
    try std.testing.expectEqual(colon.len, 1);
    try std.testing.expectEqual(slash.len, 1);
    try std.testing.expectEqual(space.len, 1);
    try std.testing.expectEqual(colon[0].type, TokenType.separator);
    try std.testing.expectEqual(slash[0].type, TokenType.separator);
    try std.testing.expectEqual(space[0].type, TokenType.separator);
    try std.testing.expectEqualStrings(colon[0].lexeme, ":");
    try std.testing.expectEqualStrings(slash[0].lexeme, "/");
    try std.testing.expectEqualStrings(space[0].lexeme, " ");
}

test "scan should batch successive separators of the same type as a single token" {
    const tokens = comptime scan(":::::::::::::::///////////////////////          ::");
    const expectedTokens: []const Token = &.{
        .{
            .type = .separator,
            .lexeme = ":",
        },
        .{
            .type = .separator,
            .lexeme = "/",
        },
        .{
            .type = .separator,
            .lexeme = " ",
        },
        .{
            .type = .separator,
            .lexeme = ":",
        },
    };
    try std.testing.expectEqualDeep(expectedTokens, tokens);
}

test "scan should terminate identifier scanning on EOF" {
    const tokens = comptime scan("identifier");
    const expectedTokens: []const Token = &.{
        .{
            .type = .identifier,
            .lexeme = "identifier",
        },
    };
    try std.testing.expectEqualDeep(expectedTokens, tokens);
}

test "scan should terminate identifier scanning on separator" {
    const tokens = comptime scan("identifier:");
    const expectedTokens: []const Token = &.{
        .{
            .type = .identifier,
            .lexeme = "identifier",
        },
        .{
            .type = .separator,
            .lexeme = ":",
        },
    };
    try std.testing.expectEqualDeep(expectedTokens, tokens);
}

test "scan should terminate identifier scanning on parameter" {
    const tokens = comptime scan("identifier{test}");
    const expectedTokens: []const Token = &.{
        .{
            .type = .identifier,
            .lexeme = "identifier",
        },
        .{
            .type = .parameter,
            .lexeme = "test",
        },
    };
    try std.testing.expectEqualDeep(expectedTokens, tokens);
}

test "scan should parse parameters" {
    const tokens = comptime scan("{test}");
    const expectedTokens: []const Token = &.{
        .{
            .type = .parameter,
            .lexeme = "test",
        },
    };
    try std.testing.expectEqualDeep(expectedTokens, tokens);
}

/// An expression that represents a 'value'
pub const ValueExpr = struct {
    /// The canonical fmt string that can be used to format the value.
    fmt: []const u8,
    /// The original raw combined string of the tokens that make up this value.
    raw: []const u8,
    /// The list of parameter paths into the context that should be used to format the value.
    params: []const []const u8,

    /// A debug comptime helper for printing the expression.
    pub fn print(comptime self: ValueExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "ValueExpr:");
        @compileLog(indent ++ "  fmt: " ++ self.fmt);
        @compileLog(indent ++ "  raw: " ++ self.raw);
        @compileLog(indent ++ "  params:");
        for (self.params) |v| {
            @compileLog(indent ++ "    " ++ v);
        }
    }
};

/// An expression that represents a 'constant'
const ConstExpr = struct {
    /// The original raw combined string of the tokens that make up this value.
    raw: []const u8,

    /// A debug comptime helper for printing the expression.
    pub fn print(comptime self: ConstExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "ConstExpr:");
        @compileLog(indent ++ "  raw: " ++ self.raw);
    }
};

/// An expression that represents a 'consume' route.
pub const ConsumeExpr = struct {
    /// The method of the expression -> always 'consume'.
    method: ExprType = .consume,
    /// The exchange of the route. Required.
    /// An exchange MAY contain dynamically bound parameters.
    exchange: ValueExpr,
    /// The binding key of the route. Required.
    /// A binding key MAY contain dynamically bound parameters.
    route: ValueExpr,
    /// The queue to which to bind. Optional.
    /// A queue MAY contain dynamically bound parameters.
    /// If not specified a transient, auto_delete, broker-generated queue is assumed.
    queue: ?ValueExpr,

    /// A debug comptime helper for printing the expression.
    pub fn print(comptime self: ConsumeExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "ConsumeExpr:");
        @compileLog(indent ++ "  exchange:");
        self.exchange.print(indent ++ "  ");
        @compileLog(indent ++ "  route:");
        self.route.print(indent ++ "  ");
        @compileLog(indent ++ "  queue:");
        if (self.queue) |q| {
            q.print(indent ++ "  ");
        } else {
            @compileLog(indent ++ "  null");
        }
    }
};

/// An expression that represents a 'reply' route.
const ExprType = enum {
    reply,
    publish,
    consume,
};

/// The
pub const ReplyExpr = struct {
    /// The method of the expression -> always 'reply'.
    method: ExprType = .reply,
    /// The exchange of the route. Required.
    /// An exchange MAY contain dynamically bound parameters.
    exchange: ValueExpr,
    /// The binding key of the route. Required.
    /// A binding key MAY contain dynamically bound parameters.
    route: ValueExpr,
    /// The queue to which to bind. Optional.
    /// A queue MAY contain dynamically bound parameters.
    /// If not specified a transient, auto_delete, broker-generated queue is assumed.
    queue: ?ValueExpr,

    /// A debug comptime helper for printing the expression.
    pub fn print(comptime self: ReplyExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "ReplyExpr:");
        @compileLog(indent ++ "  exchange:");
        self.exchange.print(indent ++ "  ");
        @compileLog(indent ++ "  route:");
        self.route.print(indent ++ "  ");
        @compileLog(indent ++ "  queue:");
        if (self.queue) |q| {
            q.print(indent ++ "  ");
        } else {
            @compileLog(indent ++ "  null");
        }
    }
};

/// An expression that represents a 'publish' route.
pub const PublishExpr = struct {
    /// The method of the expression -> always 'publish'.
    method: ExprType = .publish,
    /// The function name of the event in the event provider that triggers the publishing.
    /// An event CANNOT be dynamically bound and must be comptime-known.
    event: ConstExpr,
    /// The exchange of the route. Required.
    /// An exchange MAY contain dynamically bound parameters.
    exchange: ValueExpr,
    /// The binding key of the route. Required.
    /// A binding key MAY contain dynamically bound parameters.
    route: ValueExpr,
    /// A modifier that describes if the route should be included in recordings.
    norecord: bool,

    /// A debug comptime helper for printing the expression.
    pub fn print(comptime self: PublishExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "PublishExpr:");
        @compileLog(indent ++ "  event:");
        self.event.print(indent ++ "  ");
        @compileLog(indent ++ "  exchange:");
        self.exchange.print(indent ++ "  ");
        @compileLog(indent ++ "  route:");
        self.route.print(indent ++ "  ");
        @compileLog(indent ++ "  norecord:" ++ self.norecord);
    }
};

/// A template parser for route strings backed by the given route parameter context.
/// @typeparam Context The type of the context where route parameters will be looked up.
pub fn Template(comptime Context: type) type {
    const R = resolver.Resolver(Context);

    return struct {
        const Parser = @This();

        /// The expected return type of an expression.
        fn ExpressionType(comptime self: *Parser) type {
            return switch (self.peek().type) {
                .consume => ConsumeExpr,
                .publish => PublishExpr,
                .reply => ReplyExpr,
                else => @compileError("A route must begin with a method (publish/route/consume)"),
            };
        }

        /// The tokens to parse.
        tokens: []const Token,
        /// The current position of the parser.
        point: u64 = 0,

        /// Returns true if at the end of the token stream.
        inline fn isAtEnd(self: *const Parser) bool {
            return self.tokens.len <= self.point;
        }

        /// Peeks at the next token without consuming it if any.
        inline fn peek(self: *const Parser) Token {
            if (comptime self.isAtEnd()) {
                @compileError("Unexpected end of file");
            } else {
                return self.tokens[self.point];
            }
        }

        /// Consumes the next token.
        inline fn next(self: *Parser) Token {
            const t = self.peek();
            self.point += 1;
            return t;
        }

        /// Expects to peek at a particular token type. Fails if not matched.
        fn expect(self: *const Parser, ttype: TokenType, comptime msg: []const u8) void {
            if (comptime self.isAtEnd() or self.peek().type != ttype) {
                @compileError(msg);
            }
        }
        /// Expects to consume a particular token type. Fails if not matched.
        fn consume(self: *Parser, ttype: TokenType, comptime msg: []const u8) Token {
            self.expect(ttype, msg);
            return self.next();
        }

        /// Parses a value expression.
        fn parseValue(comptime self: *Parser) ValueExpr {
            var fmt: []const u8 = "";
            var raw: []const u8 = "";
            var params: []const []const u8 = &.{};
            while (!self.isAtEnd()) {
                const s = self.peek();
                switch (s.type) {
                    .consume, .publish, .reply => @compileError("Method found while parsing a value"),
                    .separator => {
                        if (c(s.lexeme, "/")) {
                            break;
                        }
                        @compileError("Found an unexpected separator while parsing value");
                    },
                    .norecord => {
                        const id = self.consume(.norecord, "sanity check: No Record(!) was expected.");
                        fmt = fmt ++ id.lexeme;
                        raw = raw ++ id.lexeme;
                    },
                    .identifier => {
                        const id = self.consume(.identifier, "sanity check: Identifier was expected.");
                        fmt = fmt ++ id.lexeme;
                        raw = raw ++ id.lexeme;
                    },
                    .parameter => {
                        const param = self.consume(.parameter, "sanity check: Parameter was expected.");
                        fmt = fmt ++ R.specifier(param.lexeme);
                        raw = raw ++ "{" ++ param.lexeme ++ "}";
                        params = params ++ .{param.lexeme};
                    },
                }
            }
            return .{
                .fmt = fmt,
                .raw = raw,
                .params = params,
            };
        }

        /// Parses a constant expression.
        fn parseConstant(comptime self: *Parser) ConstExpr {
            var raw: []const u8 = "";
            while (comptime !self.isAtEnd()) {
                const s = self.peek();
                switch (s.type) {
                    .consume, .publish, .reply => @compileError("Method found while parsing a value"),
                    .separator => {
                        break;
                    },
                    .identifier, .norecord => {
                        // Modifiers act as normal characters outside of method declarations.
                        raw = raw ++ s.lexeme;
                        _ = self.next();
                    },
                    .parameter => @compileError("Parameters are not allowed in constants."),
                }
            }
            return .{
                .raw = raw,
            };
        }

        /// Parses a consume expression.
        fn parseConsume(comptime self: *Parser) ConsumeExpr {
            const sep = self.consume(.separator, "Expected a separator after a method");
            if (comptime !c(" ", sep.lexeme)) {
                @compileError("Expected the separator after the method to be a whitespace.");
            }

            const exchange = self.parseValue();

            const afterExchange = self.consume(.separator, "Expected a separator after an exchange");
            if (comptime !c("/", afterExchange.lexeme)) {
                @compileError("Expected the separator after the exchange to be a slash.");
            }

            const route = self.parseValue();

            const queue = blk: {
                if (!self.isAtEnd()) {
                    const afterRoute = self.consume(.separator, "Expected a separator or EOF after an route");
                    if (comptime !c("/", afterRoute.lexeme)) {
                        @compileError("Expected the separator after the route to be a slash.");
                    }
                    break :blk self.parseValue();
                } else break :blk null;
            };

            if (!self.isAtEnd()) {
                @compileError("Expected end of file.");
            }

            return .{
                .exchange = exchange,
                .route = route,
                .queue = queue,
            };
        }

        /// Parses a publish expression.
        fn parsePublish(comptime self: *Parser) PublishExpr {
            const modifier: ?Token =
                switch (self.peek().type) {
                    .norecord => self.consume(.norecord, "Sanity check: Expected  a no record(!) modifier."),
                    else => null,
                };

            const sep = self.consume(.separator, "Expected a separator after a method");
            if (comptime !c(":", sep.lexeme)) {
                @compileError("Expected the separator after the method to be a colon.");
            }

            const event = self.parseConstant();

            const sepMain = self.consume(.separator, "Expected a separator after an event");
            if (comptime !c(" ", sepMain.lexeme)) {
                @compileError("Expected the separator after the event to be a whitespace.");
            }

            const exchange = self.parseValue();
            const afterExchange = self.consume(.separator, "Expected a separator after the exchange");
            if (comptime !c("/", afterExchange.lexeme)) {
                @compileError("Expected the separator after the exchange to be a slash.");
            }
            const route = self.parseValue();

            if (!self.isAtEnd()) {
                @compileError("Expected end of file.");
            }

            return .{
                .event = event,
                .exchange = exchange,
                .route = route,
                .norecord = if (modifier) |m| m.type == .norecord else false,
            };
        }

        /// Initializes a new parser with the given source.
        pub fn init(comptime string: []const u8) Parser {
            return .{
                .tokens = scan(string),
            };
        }

        /// Parses out the entire source string. This leaves the parser consumed.
        pub fn parseTokens(comptime self: *Parser) ExpressionType(self) {
            const method = self.next();
            return switch (comptime method.type) {
                .consume => self.parseConsume(),
                .publish => self.parsePublish(),
                .reply => {
                    const expr = self.parseConsume();
                    return ReplyExpr{
                        .exchange = expr.exchange,
                        .queue = expr.queue,
                        .route = expr.route,
                    };
                },
                else => @compileError("A route must begin with a method (publish/route/consume)"),
            };
        }

        /// Formats the remaining contents of the parser as a string.
        pub fn fmtTokens(comptime self: *Parser) []const u8 {
            var res: []const u8 = "";
            comptime for (self.tokens) |token| {
                res = res ++ @tagName(token.type) ++ ": " ++ token.lexeme ++ "\n";
            };
            return res;
        }
    };
}

// TODO: Once Zig implements the proposal for compile-time assertions tests for the parser should be added.
// see: https://github.com/ziglang/zig/issues/513
