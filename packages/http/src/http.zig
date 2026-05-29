const std = @import("std");
const klib = @import("klib");
const httpz = @import("httpz");

const core = @import("kw-core");

const schema = core.schema;
const cache = @import("kw-cache");
const mem = core.mem;
const InternFmtCache = core.InternFmtCache;
const HttpTemplate = @import("Http.zig");

const meta = core.meta;
const dep = core.deps;
const shared = core.shared;
const server = core;
const EventProperties = core.event.Properties;
const EventPropertiesEx = core.event.ExtendedProperties;
const Event = core.event.Event;
const MPMCQueue = core.queue.StaticStrict;
const Resolver = core.resolver.Resolver;
const Router = @import("http/router.zig");

pub const kind = .http;
pub const data = @import("http/response.zig");
pub const Response = httpz.Response;
pub const Request = httpz.Request;
pub const DefaultErrorHandler = @import("http/default_error_handler.zig").DefaultErrorHandler;

// TODO: pub const default = @import("amqp/default.zig").default;
// TODO: pub const defaultFor = @import("amqp/default.zig").defaultFor;

pub const middleware = struct {
    pub const cors = @import("middleware/cors.zig").WithCors;
    pub const Cors = @import("middleware/cors.zig");
};

pub const Driver = shared.DriverBuilder(DriverBuilder, true);

pub const HttpMessage = *anyopaque;
pub const State = enum {
    waiting,
    accepted,
    done,
};

pub const Config = struct {
    port: u16 = 2000,
};

pub fn DriverBuilder(
    comptime driver_key: @Type(.enum_literal),
    comptime config: []const u8,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    const H = struct {
        pub fn HttpHandler(comptime block_start: u12) type {
            return struct {
                pub const ConfigType = Config;
                pub const config_path = config;
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(
                    Routes,
                    &.{ std.mem.Allocator, *ConfigType },
                );

                //pub const Provides = ConstructProviders(ProviderRoutes);
                //pub const DependencyContext = ProvideAll(Provides);

                pub const map = shared.RouteMap(Routes);

                pub const EventType = enum(u12) {
                    http_recv = block_start,
                    __end,
                };

                pub const RequestData = struct {
                    id: RouteKeys,
                    req: *httpz.Request,
                    res: *httpz.Response,
                    captures: []const []const u8,
                    cond: *std.Thread.Condition,
                    ready: *State,

                    pub fn write(self: RequestData, w: *std.Io.Writer) !void {
                        _ = self;
                        try w.writeAll(".{ .type = HTTP }");
                    }
                };

                pub const EventValues = union(EventType) {
                    http_recv: RequestData,
                    __end: struct {},
                };

                pub inline fn __block_end() u12 {
                    comptime {
                        return @intFromEnum(@This().EventType.__end);
                    }
                }

                pub fn Yield(comptime ET: type, comptime EV: type) type {
                    const E = Event(ET, EV);
                    return struct {
                        queue: ?*MPMCQueue(E) = null,
                        //TODO: This should be replaced with a custom event loop as httpz does not support
                        // our use case very well and requires some ugly cludges.
                        server: ?*httpz.Server(*Handler) = null,

                        const Handler = struct {
                            self: *Self,
                            pub fn handle(this: *Handler, req: *httpz.Request, res: *httpz.Response) void {
                                this.self.handleRequest(req, res) catch |e| {
                                    ErrorHandler.preQueue(e, req, res);
                                };
                            }
                        };

                        const Self = @This();
                        pub const accepts = server.genAccepts(ET, EventType);

                        pub const Scheduler = struct {
                            parent: *Self,
                        };

                        pub fn init() @This() {
                            return .{};
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            if (self.server) |s| {
                                s.deinit();
                                allocator.destroy(s);
                            }
                        }

                        pub fn bind(self: *@This(), queue: *MPMCQueue(E)) void {
                            self.queue = queue;
                        }

                        pub fn scheduler(self: *@This()) Scheduler {
                            return .{
                                .parent = self,
                            };
                        }

                        pub fn watch(
                            self: *@This(),
                            wg: *std.Thread.WaitGroup,
                            pool: *std.Thread.Pool,
                            arc: anytype,
                        ) anyerror!void {
                            if (!listen or jobs == 0) {
                                arc.deinit();
                                return;
                            }

                            pool.spawnWg(wg, watch_inner, .{ self, arc });
                        }

                        pub fn watch_inner(self: *@This(), arc: anytype) void {
                            const inj: *dep.DepCtx = &arc.ref().data;
                            defer arc.unref();
                            const alloc = inj.require(std.mem.Allocator) catch unreachable;
                            const conf = inj.require(*Config) catch unreachable;

                            var handler = Handler{ .self = self };
                            const _server = httpz.Server(*Handler).init(
                                alloc,
                                .{ .address = .localhost(conf.port) },
                                &handler,
                            ) catch null;
                            if (_server == null) @panic("Could not start server.");
                            self.server = alloc.create(httpz.Server(*Handler)) catch @panic("panic");
                            self.server.?.* = _server.?;

                            self.server.?.listen() catch unreachable;
                        }

                        pub fn stop(self: *@This()) void {
                            if (self.server) |s| s.stop();
                        }

                        pub fn handleRequest(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
                            const method: HttpTemplate.Parser.HttpVerb = switch (req.method) {
                                .CONNECT => .connect,
                                .DELETE => .delete,
                                .GET => .get,
                                .HEAD => .head,
                                .OPTIONS => .options,
                                .OTHER => {
                                    //FIXME: TRACE
                                    return error.MethodNotAllowed;
                                },
                                .PATCH => .patch,
                                .POST => .post,
                                .PUT => .put,
                            };

                            const match = out: switch (method) {
                                inline else => |m| {
                                    const f = comptime FilterRoutes(Routes, m);
                                    const depth = comptime blk: {
                                        var max: u64 = 0;
                                        for (f) |route| {
                                            max = @max(max, route.inner.path.len); // Over-allocating but reduces backwards branches. FIXME: This can be improved by shrink-fitting
                                        }
                                        break :blk max;
                                    };
                                    var buf: [depth][]const u8 = undefined;
                                    const match = Router.route(
                                        f,
                                        0,
                                        &buf,
                                        0,
                                        req.url.path[1..],
                                        0,
                                    );

                                    if (match == null) {
                                        return error.NotFound;
                                    }

                                    break :out match;
                                },
                            };

                            // FIXME: This will be returned as an enum directly after the rest of the refactor
                            const id = std.meta.stringToEnum(RouteKeys, match.?.key).?;

                            var cond = std.Thread.Condition{};
                            var mut = std.Thread.Mutex{};
                            var ready = State.waiting;
                            mut.lock();
                            defer mut.unlock();

                            const val = @unionInit(
                                EV,
                                @tagName(key),
                                .{
                                    .http_recv = .{
                                        .req = req,
                                        .res = res,
                                        .id = id,
                                        // FIXME: Yikes
                                        .captures = try res.arena.dupe([]const u8, match.?.captures),
                                        .cond = &cond,
                                        .ready = &ready,
                                    },
                                },
                            );

                            const correlation = req.header("x-correlation-id");

                            const slot = self.queue.?.tryPush(
                                .{
                                    .event_type = .http_recv,
                                    .event_data = val,
                                    .properties = .{
                                        .correlation_id = if (correlation) |c| std.fmt.parseInt(u128, c, 10) catch 0 else 0,
                                    },
                                },
                                std.time.ns_per_s * 5,
                            ) catch return error.QueueFull;

                            //FIXME: This should be able to time out.
                            while (@atomicLoad(State, &ready, .acquire) != .done) {
                                cond.wait(&mut);
                            }

                            if (@atomicLoad(State, &ready, .acquire) == .waiting) {
                                @branchHint(.cold); // Right now this will never happen
                                slot.event_type = .noop;
                                return error.Timeout;
                            } else if (@atomicLoad(State, &ready, .acquire) == .accepted) {
                                @branchHint(.cold); // Right now this will never happen
                                while (@atomicLoad(State, &ready, .acquire) != .done) {
                                    // FIXME: This should also have a timeout
                                    // as is if the request takes forever to finish
                                    // we will permanently tie up on of the httpz thread pool
                                    // threads which can be abused for thread exhaustion and thus
                                    // lead to DoS.
                                    //
                                    // When we migrate to zig 0.16+'s async io we will be able to
                                    // cleanly cancel the in-flight request after the timeout
                                    // until then, this is fine so long as we don't introduce
                                    // routes that take a while.
                                    cond.wait(&mut);
                                }
                            }
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));

                            const ep = EventPropertiesEx{
                                .attempts = event.properties.attempts,
                                .correlation_id = event.properties.correlation_id,
                                .type = comptime @tagName(ehint),
                                .driver = comptime @tagName(key),
                            };

                            try switch (et) {
                                inline .http_recv => inj.call_first(receive, .{
                                    self,
                                    ev.http_recv,
                                    ep,
                                }),
                                inline else => @compileError("Invalid handler mapping!"),
                            };
                        }

                        fn receive(
                            self: *@This(),
                            event: RequestData,
                            evprop: EventPropertiesEx,
                            injector: *dep.DepCtx,
                        ) anyerror!void {
                            _ = self;
                            @atomicStore(State, event.ready, .accepted, .release);
                            const route = event.id;
                            // FIXME: We should only signal on the last attempt
                            defer {
                                @atomicStore(State, event.ready, .done, .release);
                                event.cond.signal();
                            }

                            event.res.header("x-correlation-id", try std.fmt.allocPrint(event.res.arena, "{d}", .{evprop.correlation_id}));

                            dispatchRequest(
                                route,
                                injector,
                                evprop,
                                @constCast(&event),
                            ) catch |e| {
                                ErrorHandler.postQueue(e, event.req, event.res);
                                return e;
                            };
                        }

                        fn dispatchRequest(
                            k: RouteKeys,
                            inj: *dep.DepCtx,
                            evprop: EventPropertiesEx,
                            event: *RequestData,
                        ) anyerror!void {
                            if (comptime Routes.len == 0) return error.NoRoutes;
                            switch (k) {
                                inline else => |e| {
                                    const idx = comptime @intFromEnum(e);
                                    const R = comptime Routes[idx];
                                    const RCtx = comptime @FieldType(CallContext, @tagName(e));
                                    var rctx: RCtx = undefined;

                                    const allocator: std.mem.Allocator = event.res.arena;

                                    rctx.request = event.req;
                                    rctx.response = event.res;

                                    if (comptime @hasField(RCtx, "body")) {
                                        const Body = @FieldType(RCtx, "body");
                                        if (comptime @hasDecl(Body, "read")) {
                                            rctx.body = try Body.read(allocator, event.req.reader(5000));
                                        } else {
                                            rctx.body = event.req.json(Body) catch |err| {
                                                std.log.err(
                                                    "TODO Failed to parse body: {t}",
                                                    .{err},
                                                );
                                                event.res.body = "Bad Body";
                                                event.res.status = 400;
                                                return error.InvalidBody;
                                            } orelse return error.NoBody;
                                        }
                                    }
                                    if (comptime @hasField(RCtx, "query")) {
                                        const Query = @FieldType(RCtx, "query");
                                        rctx.query = std.mem.zeroInit(Query, .{});
                                        const required_params = comptime blk: {
                                            var i = 0;
                                            for (@typeInfo(Query).@"struct".fields) |field| {
                                                const is_required = field.defaultValue() == null;
                                                i += if (is_required) 1 else 0;
                                            }
                                            break :blk i;
                                        };
                                        var set_params: usize = 0;
                                        var q = try event.req.query();
                                        if (q.len < required_params) {
                                            // TODO: Better error messaging.
                                            return error.BadQuery;
                                        }
                                        var it = q.iterator();
                                        outer: while (it.next()) |kv| {
                                            inline for (std.meta.fields(Query)) |field| {
                                                if (std.mem.eql(u8, field.name, kv.key)) {
                                                    switch (field.type) {
                                                        []const u8, []u8 => {
                                                            @field(rctx.query, field.name) = kv.value;
                                                            set_params += 1;
                                                            continue :outer;
                                                        },
                                                        else => |t| {
                                                            if (comptime @hasDecl(t, "deserialize")) {
                                                                @field(rctx.query, field.name) = t.deserialize(kv.value);
                                                                set_params += 1;
                                                                continue :outer;
                                                            } else {
                                                                @compileError("(TODO better error): Invalid query type. Not serializable.");
                                                            }
                                                        },
                                                    }
                                                }
                                            }
                                            // TODO: better error
                                            return error.InvalidQueryParameter;
                                        }
                                        if (set_params < required_params) {
                                            // TODO: better error
                                            return error.BadQuery;
                                        }
                                    }
                                    if (comptime @hasField(RCtx, "captures")) {
                                        const Captures = @FieldType(RCtx, "captures");
                                        rctx.captures = std.mem.zeroInit(Captures, .{});
                                        const inner = R.inner;
                                        comptime var set_captures: usize = 0;
                                        outer: inline for (inner.path) |segment| {
                                            switch (segment) {
                                                .capture => |c| {
                                                    const CType = @FieldType(Captures, c.name);
                                                    switch (CType) {
                                                        []const u8, []u8 => {
                                                            @field(rctx.captures, c.name) = event.captures[set_captures];
                                                            set_captures += 1;
                                                            continue :outer;
                                                        },
                                                        u64,
                                                        u32,
                                                        u16,
                                                        u8,
                                                        i64,
                                                        i32,
                                                        i16,
                                                        i8,
                                                        usize,
                                                        isize,
                                                        => |t| {
                                                            @field(rctx.captures, c.name) = std.fmt.parseInt(t, event.captures[set_captures], 10) catch return error.NotFound;
                                                            set_captures += 1;
                                                            continue :outer;
                                                        },
                                                        else => |t| {
                                                            if (comptime @hasDecl(t, "deserialize")) {
                                                                @field(rctx.captures, c.name) = t.deserialize(event.captures[set_captures]) catch return error.NotFound;
                                                                set_captures += 1;
                                                                continue :outer;
                                                            } else {
                                                                @compileError("(TODO better error): Invalid capture type. Not serializable.");
                                                            }
                                                        },
                                                    }
                                                },
                                                else => {},
                                            }
                                        }
                                    }

                                    const result = try @call(
                                        .auto,
                                        R.call,
                                        .{ inj, rctx, evprop },
                                    );

                                    const typed: *R.Return = @ptrCast(@alignCast(result));
                                    if (comptime @typeInfo(R.Return) == .@"struct" and
                                        @hasDecl(R.Return, "write"))
                                    {
                                        try typed.write(event.res.writer(), event.res);
                                    } else {
                                        try event.res.json(typed, .{});
                                    }
                                },
                            }
                        }
                    };
                }
            };
        }
    };

    return H.HttpHandler;
}

pub fn FilterRoutes(comptime Rs: []const type, comptime method: HttpTemplate.Parser.HttpVerb) []const type {
    const count = comptime blk: {
        var count = 0;
        for (Rs) |R| {
            if (R.method == method) count += 1;
        }
        break :blk count;
    };

    const Nrs = comptime blk: {
        var Nrs: [count]type = undefined;
        var i = 0;
        for (Rs) |R| {
            if (R.method == method) {
                Nrs[i] = R;
                i += 1;
            }
        }

        break :blk Nrs;
    };

    return &Nrs;
}

pub const CapabilityType = enum {
    method,
    route,
    response,
    // TODO: query, captures, parameters?
};

pub const Capability = union(CapabilityType) {
    method: HttpTemplate.Parser.HttpVerb,
    route: HttpTemplate.RouteGen.Route,
    response: type,
};

pub fn RouteBase(
    comptime m: HttpTemplate.Parser.HttpVerb,
    comptime route: HttpTemplate.RouteGen.Route,
    comptime HandlerFac: anytype,
    comptime ReturnType: type,
    comptime ev_id: @Type(.enum_literal),
) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const event_id = ev_id;
        pub const method = m;
        pub const inner = route;
        pub const id = route.identifier;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const Return = ReturnType;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(
                m,
                route,
                NextHandler,
                Return,
                event_id,
            );
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(
                m,
                route,
                NextHandlerFac(HandlerFac).make, // FIXME: This is very gross.
                Return,
                event_id,
            );
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by HTTP routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability,
        ) type {
            return switch (capability) {
                inline .method => |mt| RouteBase(
                    mt,
                    route,
                    HandlerFac,
                    Return,
                    ev_id,
                ),
                inline .route => |rt| RouteBase(
                    m,
                    rt,
                    HandlerFac,
                    Return,
                    ev_id,
                ),
                inline .response => |Resp| RouteBase(
                    m,
                    route,
                    HandlerFac,
                    Resp,
                    ev_id,
                ),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .method => m,
                .route => route,
                .response => Return,
                else => unreachable,
            };
        }
    };
}

pub fn From(comptime Container: type, comptime Context: type) []type {
    const routes = comptime blk: {
        var rp = RouteParser(Context){ .routes = &.{} };

        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }

        break :blk rp.routes;
    };

    return routes;
}

pub fn RouteParser(comptime Context: type) type {
    return struct {
        routes: []type,

        fn extend(comptime self: @This(), comptime Other: type) @This() {
            comptime {
                const routes = blk: {
                    var routes: [self.routes.len + 1]type = undefined;
                    for (self.routes, 0..) |o, i| {
                        routes[i] = o;
                    }
                    routes[self.routes.len] = Other;
                    break :blk routes;
                };
                return .{
                    .routes = @constCast(&routes),
                };
            }
        }

        fn http(
            comptime self: @This(),
            comptime route: HttpTemplate.RouteGen.Route,
            comptime f: anytype,
        ) @This() {
            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

            const __CallContext = fargs[0].type orelse
                @compileError("HTTP routes NEED to pass a context parameter.");

            if (comptime !@hasField(__CallContext, "request")) {
                @compileError("HTTP routes NEED to accept a `request: " ++ @typeName(Request) ++ "`\n\tRoute: " ++ route.identifier);
            }

            if (comptime @FieldType(__CallContext, "request") != *Request) {
                @compileError("HTTP routes expect their `request` context parameter to be of type `" ++ @typeName(Request) ++ "`\n\tRoute: " ++ route.identifier);
            }

            if (comptime !@hasField(__CallContext, "response")) {
                @compileError("HTTP routes NEED to accept a `response: " ++ @typeName(Response) ++ "`\n\tRoute: " ++ route.identifier);
            }

            if (comptime @FieldType(__CallContext, "response") != *Response) {
                @compileError("HTTP routes expect their `response` context parameter to be of type `" ++ @typeName(Response) ++ "`\n\tRoute: " ++ route.identifier);
            }

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - 1]type = undefined;
                for (fargs[1..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;

                        // FIXME: Context should only be required if we have route parameters
                        pub const Dependencies = __Dependencies ++ .{
                            core.mem.ScopedAllocator,
                            std.mem.Allocator,
                            *Context, //FIXME: This should not be a pointer
                        };

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "http: {t} {s}",
                                .{
                                    Base.method,
                                    Base.id,
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!HttpMessage {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            const ReturnType = klib.meta.Result(f);
                            if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                                @compileError("HTTP routes need at least one parameter for the request context");
                            }

                            args[0] = context;

                            inline for (1..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            const maybe_result = @call(.auto, f, args);

                            const result =
                                switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => maybe_result,
                                };

                            // FIXME: Ideally we don't need this
                            const arena = try inj.require(mem.ScopedAllocator);
                            const alloc = arena.value;
                            return handlePublish(
                                ReturnType,
                                result,
                                alloc,
                            );
                        }
                    };
                }
            };

            const ReturnType = klib.meta.Result(f);
            const ActualResultType =
                switch (comptime @typeInfo(ReturnType)) {
                    .optional => |o| o.child,
                    else => ReturnType,
                };

            const RB = RouteBase(
                route.method,
                route,
                H.make,
                ActualResultType,
                .http_recv,
            );

            return self.extend(RB);
        }

        fn handlePublish(
            comptime ResultType: type,
            result: anytype,
            alloc: std.mem.Allocator,
        ) !HttpMessage {
            const ActualResultType =
                switch (comptime @typeInfo(ResultType)) {
                    .optional => |o| o.child,
                    else => ResultType,
                };

            const actual_result =
                try @as(anyerror!ActualResultType, switch (comptime @typeInfo(ResultType)) {
                    .optional => result orelse error.Cancelled,
                    else => result,
                });

            const ptr = try alloc.create(ActualResultType);
            ptr.* = actual_result;

            return @ptrCast(@alignCast(ptr));
        }

        pub fn parse(
            comptime self: @This(),
            comptime Container: type,
            comptime fnname: []const u8,
        ) @This() {
            comptime {
                @setEvalBranchQuota(20000);
                const tmpl = HttpTemplate.RouteGen.gen(Context, Container, fnname);
                const f = @field(Container, fnname);

                switch (tmpl.method) {
                    else => {
                        return self.http(tmpl, f);
                    },
                }
            }
        }
    };
}

comptime {
    const Drv = Driver
        .new(.http)
        .config("null")
        .error_handler(DefaultErrorHandler)
        .jobs(1)
        .listen(true)
        .routes(&.{})
        .build();

    core.driver.AssertDriver(Drv, .http);
}
