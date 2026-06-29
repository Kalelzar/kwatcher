pub const std = @import("std");
pub const klib = @import("klib");
pub const dep = @import("kw-core").deps;
pub const response = @import("../http/response.zig");
pub const http = @import("../Http.zig");
pub const driver = @import("../http.zig");
pub const mem = @import("kw-core").mem;

const EventPropertiesEx = @import("kw-core").event.ExtendedProperties;
const Statuses = packed struct(u9) {
    get: u1 = 0,
    head: u1 = 0,
    post: u1 = 0,
    put: u1 = 0,
    delete: u1 = 0,
    connect: u1 = 0,
    options: u1 = 0,
    trace: u1 = 0,
    patch: u1 = 0,
};

pub const Config = struct { allowed_origins: []const []const u8 };

const RType = response.Json(struct {}, &.{
    .no_content,
    .bad_request,
});

const PreflightRouteHandlers = struct {
    pub fn create(comptime cache: Statuses) type {
        comptime var method_payload: []const u8 = "";
        for (0..@bitSizeOf(Statuses)) |i| {
            const tag: http.Parser.HttpVerb = @enumFromInt(i);
            const name = @tagName(tag);
            const v = @field(cache, name);
            if (v == 1) {
                var buf: [name.len]u8 = undefined;
                method_payload = method_payload ++ "," ++ std.ascii.upperString(&buf, name);
            }
        }
        method_payload = method_payload[1..];
        return struct {
            pub fn make(comptime Base: type) type {
                _ = Base;
                return struct {
                    pub const CallContext = struct {
                        request: *driver.Request,
                        response: *driver.Response,
                    };

                    pub const Dependencies: []const type = &.{
                        mem.ScopedAllocator,
                        *Config,
                    };

                    pub fn call(
                        inj: *dep.DepCtx,
                        ctx: CallContext,
                        evprop: EventPropertiesEx,
                    ) !*anyopaque {
                        _ = evprop;
                        const arena = try inj.require(mem.ScopedAllocator);
                        const alloc = arena.value;
                        const r = try alloc.create(RType);
                        errdefer alloc.destroy(r);
                        const req = ctx.request;
                        const res = ctx.response;
                        const origin = req.header("origin");

                        if (origin == null) {
                            res.status = 400;
                            const rtype: RType = .{
                                .value = .{
                                    .bad_request = .{
                                        .type = error.MalformedRequest,
                                        .title = "Malformed Request",
                                        .details = "Received a CORS pre-flight with no Origin",
                                        .instance = "TODO",
                                    },
                                },
                            };
                            r.* = rtype;
                            return @ptrCast(@alignCast(r));
                        }

                        // NOTE: Maybe we should cache this
                        const conf = try inj.require(*Config);
                        const is_allowed = blk: {
                            for (conf.allowed_origins) |o| {
                                if (std.mem.eql(u8, o, origin.?)) {
                                    break :blk true;
                                }
                            }
                            break :blk false;
                        };
                        if (is_allowed) {
                            res.header("Access-Control-Allow-Origin", origin.?);
                            res.header("Access-Control-Allow-Methods", method_payload);
                            res.header("Access-Control-Allow-Headers", "*");
                            res.header("Vary", "Origin");
                        }

                        const rtype: RType = .{
                            .value = .{
                                .no_content = {},
                            },
                        };
                        r.* = rtype;
                        return @ptrCast(@alignCast(r));
                    }
                };
            }
        };
    }
};

fn upcaseMethod(comptime method: []const u8) []const u8 {
    const method_payload = comptime blk: {
        var buf: [method.len]u8 = undefined;
        _ = std.ascii.upperString(
            &buf,
            method,
        );
        break :blk buf;
    };

    return &method_payload;
}

const WrapRouteHandlers = struct {
    pub fn create(comptime HandlerFac: anytype) type {
        return struct {
            pub fn make(comptime Base: type) type {
                const Handler = HandlerFac(Base);
                return struct {
                    pub const CallContext = Handler.CallContext;

                    pub const Dependencies: []const type = &Handler.Dependencies ++ .{*Config};

                    pub fn call(
                        inj: *dep.DepCtx,
                        ctx: CallContext,
                        evprop: EventPropertiesEx,
                    ) !*anyopaque {
                        const req = ctx.request;
                        const res = ctx.response;
                        const origin = req.header("origin");

                        if (origin != null) {
                            // NOTE: Maybe we should cache this
                            const conf = try inj.require(*Config);
                            const is_allowed = blk: {
                                for (conf.allowed_origins) |o| {
                                    if (std.mem.eql(u8, o, origin.?)) {
                                        break :blk true;
                                    }
                                }
                                break :blk false;
                            };

                            if (is_allowed) {
                                res.header("Access-Control-Allow-Origin", origin.?);
                            }
                            res.header("Vary", "Origin");
                        }

                        return @call(.auto, Handler.call, .{ inj, ctx, evprop });
                    }

                    pub inline fn name(inj: *dep.DepCtx) ![]const u8 {
                        return @call(.auto, Handler.name, .{inj});
                    }
                };
            }
        };
    }
};

pub fn WithCors(comptime routes: []const type) []const type {
    if (comptime routes.len == 0) return routes;
    comptime var nroutes: [routes.len]type = undefined;
    comptime var mroutes: [routes.len]type = undefined;
    comptime var count = 0;

    const map = comptime blk: {
        const P = struct { []const u8, u32 };
        const E = struct { []const u8, Statuses };
        var pre_entries: []const P = &.{};
        for (routes, 0..) |R, i| {
            R.requires(.route);
            pre_entries = pre_entries ++ .{P{ R.query(.route).canonic(), i }};
        }
        const pre = std.StaticStringMap(u32).initComptime(pre_entries);
        var entries: [pre_entries.len]E = @splat(E{ "__none__", .{} });

        for (routes) |R| {
            {
                R.requires(.method);
                R.requires(.route);
                @setEvalBranchQuota(routes.len * 300);
                const c = R.query(.route).canonic();
                const i = pre.get(c) orelse @compileError("Bug: Route not registered in pre-map");
                entries[i].@"0" = c;
                var new = entries[i].@"1";
                switch (R.query(.method)) {
                    inline else => |m| {
                        @field(new, @tagName(m)) = 1;
                    },
                }
                entries[i].@"1" = new;
            }
        }
        {
            @setEvalBranchQuota(routes.len * 300);
            break :blk std.StaticStringMap(Statuses).initComptime(entries);
        }
    };

    inline for (routes, 0..) |R, i| {
        comptime {
            R.requires(.method);
            R.requires(.route);
            R.requires(.response);
            const cur = R.query(.method);
            const route = R.query(.route);
            const cache = map.get(route.canonic()) orelse @compileError("Bug: Route not registered in map");
            const flags: u9 = @bitCast(cache);
            const earliest = @ctz(flags);
            const tag: http.Parser.HttpVerb = @enumFromInt(earliest);
            if (cache.options == 0 and cur == tag) {
                var new_route = route;
                new_route.method = .options;
                new_route.identifier = "[CORS] " ++ route.identifier;
                new_route.raw = "";

                nroutes[count] = R.swap(PreflightRouteHandlers.create(cache).make)
                    .mod(.{ .method = .options })
                    .mod(.{ .route = new_route })
                    .mod(.{ .response = RType });
                count += 1;
            }
            mroutes[i] = R.wrap(WrapRouteHandlers.create);
        }
    }

    return mroutes ++ nroutes[0..count];
}
