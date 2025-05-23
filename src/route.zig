const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;
const mem = @import("mem.zig");
const schema = @import("schema.zig");
const injector = @import("injector.zig");
const resolver = @import("resolver.zig");
const metrics = @import("metrics.zig");
const InternFmtCache = @import("intern_fmt_cache.zig");
const Client = @import("client.zig");
const Template = @import("template.zig").Template;
const handlers = @import("handlers.zig");

pub const Method = enum {
    publish,
    consume,
    reply,
};

pub fn Route(PathParams: type) type {
    return struct {
        method: Method,
        handlers: handlers.HandlerCodeGen(PathParams).Handlers,
        metadata: *const handlers.Metadata,
        binding: handlers.Binding,

        const Self = @This();

        pub fn updateBindings(self: *Self, inj: *injector.Injector) !?[]const u8 {
            var inj_args: std.meta.Tuple(&.{*injector.Injector}) = undefined;
            inj_args[0] = inj;

            const client = try inj.require(Client);

            var _route = try @call(.auto, self.handlers.route, inj_args);
            defer _route.deinit();
            var _exchange = try @call(.auto, self.handlers.exchange, inj_args);
            defer _exchange.deinit();
            var _queue = if (self.handlers.queue) |q| try @call(.auto, q, inj_args) else null;
            defer if (_queue) |*q| q.deinit();

            const new = _route.updated() or _exchange.updated() or if (_queue) |q| q.updated() else false;

            self.binding.route = _route.new;
            self.binding.exchange = _exchange.new;
            self.binding.queue = if (_queue) |q| q.new else null;

            std.log.debug(
                "[{?s}, new: {}] Updated bindings for {} route {s}/{s}/{?s}",
                .{
                    self.binding.consumer_tag,
                    new,
                    self.method,
                    self.binding.exchange,
                    self.binding.route,
                    self.binding.queue,
                },
            );

            if (!new) return self.binding.consumer_tag;

            if (self.binding.consumer_tag) |ct| {
                try client.unbind(ct, .{});
                return self.bind(client);
            }

            return self.binding.consumer_tag;
        }

        pub fn bind(self: *Self, client: Client) !?[]const u8 {
            switch (self.method) {
                .consume, .reply => {
                    const res = try client.bind(
                        self.binding.queue,
                        self.binding.route,
                        self.binding.exchange,
                        .{},
                    );
                    try metrics.consumeQueue(self.binding.route);
                    self.binding.consumer_tag = res;
                    return res;
                },
                .publish => {
                    try metrics.publishQueue(self.binding.route, self.binding.exchange);
                    return null;
                },
            }
        }

        pub fn from(comptime ContainerType: type, comptime EventProvider: type) []const Self {
            meta.ensureStruct(ContainerType);

            const routes = comptime blk: {
                @setEvalBranchQuota(@typeInfo(ContainerType).@"struct".decls.len * 100);
                var res: []const Self = &.{};

                for (std.meta.declarations(ContainerType)) |d| {
                    if (@typeInfo(@TypeOf(@field(ContainerType, d.name))) != .@"fn") continue;

                    const route = handlers.HandlerCodeGen(PathParams).gen(
                        ContainerType,
                        EventProvider,
                        d.name,
                    );

                    res = res ++ .{route};
                }

                break :blk res;
            };

            return routes;
        }
    };
}
