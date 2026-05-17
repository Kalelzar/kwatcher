const std = @import("std");
const klib = @import("klib");
const httpz = @import("httpz");

const kw = @import("../root.zig");

const schema = kw.schema;
const conftype = struct {};
const cache = kw.cache;
const mem = kw.mem;
const InternFmtCache = kw.InternFmtCache;
const HttpTemplate = @import("../template/Http.zig");

const meta = kw.meta;
const dep = kw.deps;
const shared = kw.shared;
const server = kw.server;
const EventProperties = kw.event.Properties;
const EventPropertiesEx = kw.event.ExtendedProperties;
const Event = kw.event.Event;
const MPMCQueue = kw.queue.StaticStrict;
const Resolver = kw.resolver.Resolver;
const Router = @import("http/router.zig");

pub const kind = .http;
pub const data = @import("http/response.zig");
pub const Response = httpz.Response;
pub const Request = httpz.Request;

// TODO: pub const default = @import("amqp/default.zig").default;
// TODO: pub const defaultFor = @import("amqp/default.zig").defaultFor;

pub const Driver = shared.DriverBuilder(DriverBuilder, true);

pub const HttpMessage = *anyopaque;
pub const State = enum {
    waiting,
    accepted,
    done,
};

pub fn DriverBuilder(
    comptime driver_key: @Type(.enum_literal),
    comptime config: []const u8,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
) *const fn (comptime u12) type {
    const H = struct {
        pub fn HttpHandler(comptime block_start: u12) type {
            return struct {
                pub const ConfigType = conftype;
                pub const config_path = config;
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(
                    Routes,
                    &.{std.mem.Allocator},
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
                    cond: *std.Thread.Condition,
                    ready: *State,

                    pub fn write(self: RequestData, w: *std.Io.Writer) !void {
                        _ = self;
                        try w.writeAll(".{ .todo = TODO }");
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
                        server: ?*httpz.Server(*Handler) = null,

                        const Handler = struct {
                            self: *Self,
                            pub fn handle(this: *Handler, req: *httpz.Request, res: *httpz.Response) void {
                                this.self.handleRequest(req, res) catch |e| {
                                    res.status = 500;
                                    res.body = @errorName(e);
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

                            var handler = Handler{ .self = self };
                            const _server = httpz.Server(*Handler).init(
                                alloc,
                                .{ .address = .localhost(2000) },
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
                            const method: HttpTemplate.Parser.HttpVerb = @enumFromInt(@intFromEnum(req.method));

                            switch (method) {
                                inline else => |m| {
                                    const f = comptime FilterRoutes(Routes, m);
                                    const match = Router.route(f, 0, req.url.path[1..], 0);

                                    if (match == null) {
                                        return error.NotFound;
                                    }

                                    // FIXME: This will be returned as an enum directly after the rest of the refactor
                                    const id = std.meta.stringToEnum(RouteKeys, match.?).?;

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
                                                .cond = &cond,
                                                .ready = &ready,
                                            },
                                        },
                                    );

                                    const slot = self.queue.?.tryPush(
                                        .{
                                            .event_type = .http_recv,
                                            .event_data = val,
                                        },
                                        std.time.ns_per_s * 5,
                                    ) catch return error.QueueFull;

                                    const timed_out = blk: {
                                        while (@atomicLoad(State, &ready, .acquire) != .done) {
                                            cond.timedWait(&mut, std.time.ns_per_s * 30) catch break :blk true;
                                        }
                                        break :blk false;
                                    };

                                    if (timed_out and
                                        @atomicLoad(State, &ready, .acquire) == .waiting)
                                    {
                                        slot.event_type = .noop;
                                        return error.Timeout;
                                    } else if (timed_out and
                                        @atomicLoad(State, &ready, .acquire) == .accepted)
                                    {
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
                                },
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
                            dispatchRequest(
                                route,
                                injector,
                                evprop,
                                @constCast(&event),
                            ) catch |e| {
                                event.res.status = 500;
                                event.res.body = @errorName(e);
                                event.res.content_type = .TEXT;
                                // FIXME: We should only signal on the last attempt
                                @atomicStore(State, event.ready, .done, .release);
                                event.cond.signal();
                                return e;
                            };

                            @atomicStore(State, event.ready, .done, .release);
                            event.cond.signal();
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
                                        //TODO: @compileError("Captures are not implemented");
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
            return shared.hasKey(CapabilityType, ct);
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
                            kw.mem.ScopedAllocator,
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
