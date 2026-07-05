const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.signal);

const dep = @import("kw-core").deps;
const server = @import("kw-core");
const Event = @import("kw-core").event.Event;
const EventProperties = @import("kw-core").event.Properties;

const meta = @import("kw-core").meta;
const shared = @import("kw-core").shared;
const MPMCQueue = @import("kw-core").queue.StaticStrict;

pub const kind = .signal;
const Root = @This();

pub const Driver = shared.DriverBuilder(DriverBuilder, false);

// TODO: Support other os-es
const SIG = std.os.linux.SIG;

// TODO: Auto-generate from SIG so it matches on all archs
// TODO: Add RT signals.
// TODO: We should forbid handlers for signals that are unblockable and/or used by pthread on glibc/musl
pub const Signal = enum(u32) {
    HUP = SIG.HUP,
    INT = SIG.INT,
    QUIT = SIG.QUIT,
    ILL = SIG.ILL,
    TRAP = SIG.TRAP,
    ABRT = SIG.ABRT,
    FPE = SIG.FPE,
    KILL = SIG.KILL,
    BUS = SIG.BUS,
    SEGV = SIG.SEGV,
    SYS = SIG.SYS,
    PIPE = SIG.PIPE,
    ALRM = SIG.ALRM,
    TERM = SIG.TERM,
    USR1 = SIG.USR1,
    USR2 = SIG.USR2,
    CHLD = SIG.CHLD,
    PWR = SIG.PWR,
    STLFLT = SIG.STKFLT,
    CONT = SIG.CONT,
    STOP = SIG.STOP,
    TSTP = SIG.TSTP,
    TTIN = SIG.TTIN,
    TTOU = SIG.TTOU,
    URG = SIG.URG,
    XCPU = SIG.XCPU,
    XFSZ = SIG.XFSZ,
    VTALRM = SIG.VTALRM,
    PROF = SIG.PROF,
    WINCH = SIG.WINCH,
    POLL = SIG.POLL,
};

pub const SignalInfo = std.os.linux.siginfo_t;

/// Pre-built signal route containers users can include (e.g. `default.Shutdown`).
pub const default = @import("default.zig");

pub fn ForSignal(comptime signum: Signal, comptime Rs: []const type) []const type {
    const count = comptime blk: {
        var count = 0;
        for (Rs) |R| {
            if (R.signum == signum) count += 1;
        }
        break :blk count;
    };

    const Nrs = comptime blk: {
        var Nrs: [count]type = undefined;
        var i = 0;
        for (Rs) |R| {
            if (R.signum == signum) {
                Nrs[i] = R;
                i += 1;
            }
        }

        break :blk Nrs;
    };

    return &Nrs;
}

pub fn DriverBuilder(
    comptime driver_key: anytype,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = ErrorHandler;
    if (comptime _jobs != 1) @compileError(std.fmt.comptimePrint(
        "Signal driver '{t}' expects exactly 1 job, found: {d}",
        .{ driver_key, _jobs },
    ));
    if (comptime !listen) @compileError(
        "Signal driver '" ++ @tagName(driver_key) ++ "' must be listening.",
    );
    const H = struct {
        pub fn SignalHandler(comptime block_start: u12) type {
            return struct {
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const kind = Root.kind;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(Routes, &.{std.mem.Allocator});
                pub const map = shared.RouteMap(Routes);

                const SignalData = struct {
                    signal_info: SignalInfo,
                    signum: Signal,

                    pub fn write(self: SignalData, w: *std.Io.Writer) !void {
                        switch (self.signum) {
                            inline else => |s| try w.print(".{{.signame = \"{t}\", .signum = {d}}}", .{ s, @intFromEnum(s) }),
                        }
                    }
                };

                pub const EventType = enum(u12) {
                    signal = block_start,
                };

                pub const EventValues = union(EventType) {
                    signal: SignalData,
                };

                pub inline fn __block_end() u12 {
                    comptime {
                        return block_start + meta.count(EventType);
                    }
                }

                pub fn Yield(comptime ET: type, comptime EV: type) type {
                    const E = Event(ET, EV);
                    return struct {
                        const Self = @This();

                        queue: ?*MPMCQueue(E) = null,
                        should_run: bool = true,

                        pub const accepts = server.genAccepts(ET, EventType);

                        pub const Scheduler = struct {
                            parent: *Self,
                        };

                        fn dispatch(data: SignalData, inj: *dep.DepCtx) anyerror!void {
                            switch (data.signum) {
                                inline else => |rctx| {
                                    const R = comptime ForSignal(rctx, Routes);
                                    inline for (R) |Route| {
                                        _ = try server.event.stampRoute(inj, Route.id);
                                        try Route.call(inj, data.signal_info);
                                    }
                                },
                            }
                        }

                        pub fn init() @This() {
                            return .{};
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            _ = allocator;
                            _ = self;
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
                            pool.spawnWg(wg, watch_inner, .{ self, arc });
                        }

                        fn rt_sigtimedwait(
                            set: *const std.os.linux.sigset_t,
                            info: ?*std.os.linux.siginfo_t,
                            timeout: *const std.os.linux.timespec,
                        ) error{ WouldBlock, Invalid, Interrupted, Unexpected }!u64 {
                            const res = std.os.linux.syscall4(
                                .rt_sigtimedwait,
                                @intFromPtr(set),
                                if (info) |i| @intFromPtr(i) else 0,
                                @intFromPtr(timeout),
                                @sizeOf(std.os.linux.sigset_t),
                            );

                            const err = std.os.linux.E.init(res);
                            return switch (err) {
                                .SUCCESS => res,
                                .INVAL => error.Invalid,
                                .INTR => error.Interrupted,
                                .AGAIN => error.WouldBlock,
                                else => error.Unexpected,
                            };
                        }

                        pub fn watch_inner(self: *@This(), arc: anytype) void {
                            _ = &arc.ref();
                            defer arc.unref();

                            const sigmask = std.os.linux.sigfillset();
                            var siginfo: std.os.linux.siginfo_t = undefined;
                            const timeout: std.os.linux.timespec = .{ .sec = 2, .nsec = 0 };

                            while (@atomicLoad(bool, &self.should_run, .acquire)) {
                                const res = rt_sigtimedwait(
                                    &sigmask,
                                    &siginfo,
                                    &timeout,
                                ) catch |e| switch (e) {
                                    error.Invalid => @panic("BUG: Bad timespec for rt_sigtimedwait."),
                                    error.Interrupted, error.WouldBlock => continue,
                                    error.Unexpected => unreachable,
                                };

                                const signal: Signal = @enumFromInt(res);

                                const data: SignalData = .{
                                    .signal_info = siginfo, // Deliberate copy
                                    .signum = signal,
                                };

                                const val = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{ .signal = data },
                                );

                                log.info("Got: {t}({d})", .{ signal, res });

                                _ = self.queue.?.push(.{
                                    .event_type = @field(ET, @tagName(key) ++ "_signal"),
                                    .event_data = val,
                                    .properties = .{
                                        .correlation_id = .unset,
                                    },
                                });
                            }
                        }

                        pub fn stop(self: *@This()) void {
                            @atomicStore(bool, &self.should_run, false, .release);
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));
                            _ = self;

                            switch (et) {
                                inline .signal => try dispatch(ev.signal, inj),
                            }
                        }
                    };
                }
            };
        }
    };

    return H.SignalHandler;
}

pub fn From(comptime Container: type) []type {
    comptime {
        var rp = RouteParser(){ .routes = &.{} };
        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }
        return rp.routes;
    }
}

pub const CapabilityType = enum { name, signal };

pub const Capability = union(CapabilityType) { name: []const u8, signal: Signal };

pub fn RouteBase(
    comptime HandlerFac: anytype,
    comptime parsed_id: []const u8,
    comptime _signum: Signal,
) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const id = parsed_id;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const call = Handler.call;
        pub const name = Handler.name;
        pub const signum: Signal = _signum;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(NextHandler, parsed_id, signum);
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(NextHandlerFac(HandlerFac).make, parsed_id, signum);
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by SIGNAL routes.",
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
                inline .name => |n| RouteBase(HandlerFac, n, signum),
                inline .signal => |n| RouteBase(HandlerFac, parsed_id, n),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .name => parsed_id,
                .signal => signum,
                else => unreachable,
            };
        }
    };
}

pub fn RouteParser() type {
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

        pub fn parse(
            comptime self: @This(),
            comptime Container: type,
            comptime fnname: []const u8,
        ) @This() {
            comptime {
                const f = @field(Container, fnname);

                var it = std.mem.splitScalar(u8, fnname, ' ');

                const signame = it.next() orelse @compileError("signal: Malformed signal handler name. Expected 'SIG @identifier', found ''");

                const raw_identifier = it.next() orelse @compileError("signal: Malformed signal handler name. Expected 'SIG @identifier', found 'SIG'");

                if (it.next() != null) {
                    @compileError("signal: Malformed signal handler name. Expected 'SIG @identifier', found 'SIG @identifer EXTRA...");
                }

                if (!@hasField(Signal, signame)) {
                    @compileError("signal: Expected SIG to be a signal name: Found " ++ signame);
                }

                const signal: Signal = @enumFromInt(@field(SIG, signame));

                const identifier = blk: {
                    if (!std.mem.startsWith(u8, raw_identifier, "@")) {
                        @compileError("signal: Expected identifier to begin with '@'. Found: " ++ raw_identifier[0..1]);
                    }

                    if (raw_identifier.len == 1) {
                        @compileError("signal: Empty identifier");
                    }

                    break :blk raw_identifier[1..];
                };

                const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

                if (fargs.len == 0) {
                    @compileError("signal: Expected first parameter to be SignalInfo");
                }

                if (fargs[0].type.? != SignalInfo) {
                    @compileError("signal: Expected first parameter to be SignalInfo");
                }

                const di_start_idx = 1;
                const __CallContext = fargs[0].type.?;

                const __Dependencies = blk: {
                    var deps: [fargs.len - di_start_idx]type = undefined;
                    for (fargs[di_start_idx..fargs.len], 0..) |a, i| {
                        deps[i] = a.type.?;
                    }
                    break :blk deps;
                };

                const H = struct {
                    pub fn make(comptime Base: type) type {
                        _ = Base;
                        return struct {
                            pub const CallContext = __CallContext;
                            pub const Dependencies = __Dependencies;

                            pub fn name(inj: *dep.DepCtx) ![]const u8 {
                                const allocator = try inj.require(std.mem.Allocator);
                                return std.fmt.allocPrint(allocator, "signal: {s}", .{fnname});
                            }

                            pub fn call(inj: *dep.DepCtx, context: CallContext) anyerror!void {
                                var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;

                                inline for (0..di_start_idx) |i| {
                                    args[i] = context;
                                }

                                inline for (di_start_idx..args.len) |i| {
                                    args[i] = try inj.require(@TypeOf(args[i]));
                                }
                                const maybe_result = @call(.auto, f, args);

                                switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => {},
                                }
                            }
                        };
                    }
                };

                const RB = RouteBase(H.make, identifier, signal);

                return self.extend(RB);
            }
        }
    };
}

comptime {
    const Drv = Driver
        .new(.signal)
        .listen(true)
        .jobs(1)
        .routes(&.{})
        .build();

    @import("kw-core").driver.AssertDriver(Drv, .signal);
}

// Ref all decls
comptime {
    const core = @import("kw-core");

    const Rs = struct {
        pub fn @"TERM @term"(info: SignalInfo) void {
            _ = info;
        }
        pub fn @"INT @int"(info: SignalInfo, dependency: i64) void {
            _ = info;
            _ = dependency;
        }
    };

    const Rts = From(Rs);

    const R1 = Rts[0];
    R1.requires(.name);
    R1.requires(.signal);
    if (R1.satisfies(.nothing)) @compileError("BUG: Incorrect constraint return");
    const R2 = R1.mod(.{ .name = "new" });
    if (!std.mem.eql(u8, R2.query(.name), "new")) @compileError("BUG: Wrong name - " ++ R2.query(.name));
    const R3 = R2.mod(.{ .signal = .HUP });
    if (R3.query(.signal) != .HUP) @compileError("BUG: Wrong signal");

    const Drv = Driver
        .new(.signal)
        .listen(true)
        .jobs(1)
        .routes(Rts)
        .build();

    const Ds = core.driver.Drivers.new().registerHandler(Drv);

    const ET = Ds.EventList();
    const EV = Ds.EventValues();
    const E = Event(ET, EV);

    _ = Ds.Handlers(ET, EV)[0];
    const Sch = Ds.SchedulerMap();
    _ = Sch(.signal);

    _ = E;
}
