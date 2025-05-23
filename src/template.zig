const std = @import("std");
const resolver = @import("resolver.zig");
const injector = @import("injector.zig");
const InternFmtCache = @import("intern_fmt_cache.zig");

const TokenType = enum {
    publish,
    consume,
    reply,
    identifier,
    separator,
    parameter,
};

const Token = struct {
    type: TokenType,
    lexeme: []const u8,
};

fn c(comptime a: []const u8, comptime b: []const u8) bool {
    return comptime std.mem.eql(u8, a, b);
}

pub fn scan(comptime raw_source: []const u8) []const Token {
    const source: []const u8 = comptime blk: {
        var source_buf: [raw_source.len]u8 = undefined;
        _ = std.ascii.lowerString(&source_buf, raw_source);
        const output = source_buf;
        break :blk &output;
    };

    var point: u64 = 0;
    var mark = 0;
    var tokens: []const Token = &.{};
    comptime while (point < source.len) {
        // The currently considered string
        const string = source[mark .. point + 1];

        const ch = source[point];
        switch (ch) {
            ' ', '/', ':' => |sep| {
                if (point - mark == 0) {
                    tokens = tokens ++ .{Token{ .type = .separator, .lexeme = source[mark .. point + 1] }};
                    while (source[point] == sep and point < source.len) {
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
                            @compileError("Unclosed parameter here: '" ++ source[mark .. point + 1] ++ "' while parsing '" ++ raw_source ++ "'.");
                        },
                        else => {},
                    }
                }
                if (point == source.len) {
                    @compileError("Unexpected EOF in parameter: '" ++ source[mark .. point + 1] ++ "' while parsing '" ++ raw_source ++ "'.");
                }

                tokens = tokens ++ .{Token{ .type = .parameter, .lexeme = source[mark + 1 .. point] }};
                point += 1;
                mark = point;
                continue;
            },
            else => {},
        }

        const token: Token =
            if (c("publish", string))
                .{ .type = .publish, .lexeme = string }
            else if (c("consume", string))
                .{ .type = .consume, .lexeme = string }
            else if (c("reply", string))
                .{ .type = .reply, .lexeme = string }
            else {
                point += 1;
                continue;
            };

        point += 1;
        mark = point;
        tokens = tokens ++ .{token};
    };

    if (comptime mark != point and point <= source.len) {
        tokens = tokens ++ .{Token{ .type = .identifier, .lexeme = source[mark..point] }};
    }

    return tokens;
}

pub const ValueExpr = struct {
    fmt: []const u8,
    raw: []const u8,
    params: []const []const u8,

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

const ConstExpr = struct {
    raw: []const u8,

    pub fn print(comptime self: ConstExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "ConstExpr:");
        @compileLog(indent ++ "  raw: " ++ self.raw);
    }
};

pub const ConsumeExpr = struct {
    method: ExprType = .consume,
    exchange: ValueExpr,
    route: ValueExpr,
    queue: ?ValueExpr,

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

const ExprType = enum {
    reply,
    publish,
    consume,
};

pub const ReplyExpr = struct {
    method: ExprType = .reply,
    exchange: ValueExpr,
    route: ValueExpr,
    queue: ?ValueExpr,

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

pub const PublishExpr = struct {
    method: ExprType = .publish,
    event: ConstExpr,
    exchange: ValueExpr,
    route: ValueExpr,

    pub fn print(comptime self: PublishExpr, comptime indent: []const u8) void {
        @compileLog(indent ++ "PublishExpr:");
        @compileLog(indent ++ "  event:");
        self.event.print(indent ++ "  ");
        @compileLog(indent ++ "  exchange:");
        self.exchange.print(indent ++ "  ");
        @compileLog(indent ++ "  route:");
        self.route.print(indent ++ "  ");
    }
};

pub fn Template(comptime Context: type) type {
    const R = resolver.Resolver(Context);

    return struct {
        const Parser = @This();

        fn ExpressionType(comptime self: *Parser) type {
            return switch (self.peek().type) {
                .consume => ConsumeExpr,
                .publish => PublishExpr,
                .reply => ReplyExpr,
                else => @compileError("A route must begin with a method (publish/route/consume)"),
            };
        }

        tokens: []const Token,
        point: u64 = 0,

        inline fn isAtEnd(self: *const Parser) bool {
            return self.tokens.len <= self.point;
        }

        inline fn peek(self: *const Parser) Token {
            if (comptime self.isAtEnd()) {
                @compileError("Unexpected end of file");
            } else {
                return self.tokens[self.point];
            }
        }

        inline fn next(self: *Parser) Token {
            const t = self.peek();
            self.point += 1;
            return t;
        }

        fn expect(self: *const Parser, ttype: TokenType, comptime msg: []const u8) void {
            if (comptime self.isAtEnd() or self.peek().type != ttype) {
                @compileError(msg);
            }
        }

        fn consume(self: *Parser, ttype: TokenType, comptime msg: []const u8) Token {
            self.expect(ttype, msg);
            return self.next();
        }

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

        fn parseConstant(comptime self: *Parser) ConstExpr {
            var raw: []const u8 = "";
            while (comptime !self.isAtEnd()) {
                const s = self.peek();
                switch (s.type) {
                    .consume, .publish, .reply => @compileError("Method found while parsing a value"),
                    .separator => {
                        break;
                    },
                    .identifier => {
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

        fn parsePublish(comptime self: *Parser) PublishExpr {
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
            };
        }

        pub fn init(comptime string: []const u8) Parser {
            return .{
                .tokens = scan(string),
            };
        }

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

        pub fn fmtTokens(comptime self: *Parser) []const u8 {
            var res: []const u8 = "";
            comptime for (self.tokens) |token| {
                res = res ++ @tagName(token.type) ++ ": " ++ token.lexeme ++ "\n";
            };
            return res;
        }
    };
}
