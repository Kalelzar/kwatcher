const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.cron);

const dep = @import("../dep.zig");
const server = @import("../server.zig");
const Event = @import("../event.zig").Event;

const CronTemplate = @import("../template/Cron.zig");

const shared = @import("../utils/shared.zig");
const meta = @import("../utils/meta.zig");

const MPMCQueue = @import("../utils/queue.zig").StaticStrict;

pub const kind = .cron;

pub const Driver = shared.DriverBuilder(DriverBuilder, false);

pub fn DriverBuilder(
    comptime driver_key: anytype,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = ErrorHandler;
    if (comptime _jobs > 1) @compileError("More than 1 watch job is useless for the cron driver.");
    const H = struct {
        pub fn CronHandler(comptime block_start: u12) type {
            return struct {
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(Routes, &.{std.mem.Allocator});
                pub const map = shared.RouteMap(Routes);
                pub const EventType = enum(u12) {
                    trigger_job = block_start,
                    __end,
                };

                const TriggerJobData = struct {
                    route: RouteKeys,
                };

                pub const EventValues = union(EventType) {
                    trigger_job: TriggerJobData,
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
                        const Self = @This();
                        pub const Scheduler = struct {
                            parent: *Self,

                            pub fn once(self: @This(), comptime schedule: []const u8, event: E) !void {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const parsed = comptime CronTemplate.VM.Schedule.init(schedule);
                                const sch = Schedule{
                                    .oneshot = true,
                                    .target = .{
                                        .event = event,
                                    },
                                    .run_at = calcNext(std.time.timestamp() + 1, parsed),
                                    .schedule = parsed,
                                };
                                try self.parent.schedules.add(sch);
                                self.parent.cond.broadcast();
                            }

                            pub fn after(self: @This(), time_s: i64, event: E) !void {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const sch = Schedule{
                                    .oneshot = true,
                                    .target = .{
                                        .event = event,
                                    },
                                    .run_at = std.time.timestamp() + time_s,
                                    .schedule = comptime .init("0 0 0 1 1 0"),
                                };
                                try self.parent.schedules.add(sch);
                                self.parent.cond.broadcast();
                            }

                            pub fn trigger(self: @This(), route: RouteKeys) !void {
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .trigger_job = .{
                                            .route = route,
                                        },
                                    },
                                );

                                const ev = E{
                                    .event_data = value,
                                    .event_type = .trigger_job,
                                };

                                self.parent.queue.?.pushNoClobber(ev) catch |e| switch (e) {
                                    error.WouldBlock => {
                                        // FIXME: Words
                                        // Ideally we would want to be able to do:
                                        // self.parent.handle(.trigger_job, ev, ???);
                                        // But we can't get an injector for our handler at the
                                        // moment.
                                        // We could accept an injector from outside but there
                                        // is no gurantee that it was built for our invariant.
                                        // The dependency system should allow us to request injectors for other uses.
                                        // That's the fix.
                                        @panic("Preemptive execution is not implemented!");
                                    },
                                    else => return e,
                                };
                            }
                        };

                        const Schedule = struct {
                            oneshot: bool = false,
                            run_at: i64,
                            target: union(enum) {
                                route: RouteKeys,
                                event: E,
                            },
                            schedule: CronTemplate.VM.Schedule,
                        };

                        const SchCtx = struct {};

                        queue: ?*MPMCQueue(E) = null,
                        schedules: std.PriorityQueue(Schedule, SchCtx, compareSchedule),
                        cond: std.Thread.Condition = .{},
                        mutex: std.Thread.Mutex = .{},
                        should_run: bool = true,
                        pub const accepts = server.genAccepts(ET, EventType);

                        fn compareSchedule(_: SchCtx, a: Schedule, b: Schedule) std.math.Order {
                            if (a.run_at == b.run_at) {
                                return .eq;
                            } else if (a.run_at < b.run_at) {
                                return .lt;
                            }
                            return .gt;
                        }

                        pub fn init(allocator: std.mem.Allocator) !@This() {
                            var q = std.PriorityQueue(Schedule, SchCtx, compareSchedule).init(allocator, .{});

                            const now = std.time.timestamp();
                            inline for (Routes) |R| {
                                const next = calcNext(now, R.schedule);
                                try q.add(.{
                                    .target = .{ .route = map.get(R.id).? },
                                    .run_at = next,
                                    .schedule = R.schedule,
                                });
                            }
                            return .{
                                .schedules = q,
                            };
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            _ = allocator;
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.schedules.deinit();
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
                            defer arc.deinit();
                            if (!listen) return;
                            if (comptime jobs > 1) @compileError("Cron is only allowed 1 watch job.");

                            for (0..jobs) |_| {
                                pool.spawnWg(wg, watch_inner, .{self});
                            }
                        }

                        fn watch_inner(self: *@This()) void {
                            var reserve: ?Schedule = null;
                            while (@atomicLoad(bool, &self.should_run, .acquire)) {
                                self.watch_failing(&reserve) catch |e| {
                                    log.err("Cron loop failed with: {t}", .{e});
                                };
                            }
                        }

                        fn watch_failing(self: *@This(), reserve: *?Schedule) !void {
                            self.mutex.lock();
                            var sch = self.schedules.removeOrNull();
                            {
                                defer self.mutex.unlock();
                                if (sch == null) {
                                    self.cond.wait(&self.mutex);
                                    return;
                                } else {
                                    if (reserve.*) |r| {
                                        defer reserve.* = null;
                                        self.schedules.add(r) catch @panic("Potential unsynchronized write. Cron queue was filled while under lock.");
                                    }
                                }
                            }

                            var now = std.time.timestamp();
                            const name = switch (sch.?.target) {
                                .route => |r| @tagName(r),
                                .event => |e| @tagName(e.event_type),
                            };
                            while (now < sch.?.run_at) {
                                log.info("Job '{s}' to fire in {d} seconds.", .{ name, @max(0, sch.?.run_at - now) });
                                self.mutex.lock();
                                self.cond.timedWait(&self.mutex, @as(u64, @intCast(@max(0, sch.?.run_at - now))) * std.time.ns_per_s) catch {
                                    // We are using timeout to signal when we should run next rather than an error condition
                                };
                                // FIXME: We have to add the schedule back and get a new one.
                                // We might ahve been woken up because a new schedule was added and that one might need to fire sooner
                                self.mutex.unlock();
                                if (!@atomicLoad(bool, &self.should_run, .acquire))
                                    return;
                                now = std.time.timestamp();
                            }
                            if (!sch.?.oneshot) {
                                const next = calcNext(@max(now, sch.?.run_at), sch.?.schedule);
                                log.info("Scheduling job '{s}' to fire in {d} seconds.", .{ name, @max(0, next - now) });
                                sch.?.run_at = next;
                                self.mutex.lock();
                                defer self.mutex.unlock();
                                // This can OOM but is unlikely
                                // because we should have the original slot left
                                // so long as it hasn't been filled with a oneshot.
                                // That said, dropping a schedule is not an option here.
                                // We are going to pop another one off right after
                                // so space will be created that we can reuse.
                                self.schedules.add(sch.?) catch |e| switch (e) {
                                    error.OutOfMemory => {
                                        reserve.* = sch;
                                    },
                                    else => return e,
                                };
                            }
                            switch (sch.?.target) {
                                .route => |route| {
                                    const data = @unionInit(EV, @tagName(key), .{
                                        .trigger_job = .{
                                            .route = route,
                                        },
                                    });
                                    _ = self.queue.?.push(.{
                                        .event_type = .trigger_job,
                                        .event_data = data,
                                    });
                                    log.info("Job {s} queued successfully.", .{name});
                                },
                                .event => |event| {
                                    _ = self.queue.?.push(event);
                                    log.info("Event {s} queued successfully.", .{name});
                                },
                            }
                        }

                        pub fn stop(self: *@This()) void {
                            @atomicStore(bool, &self.should_run, false, .release);
                            self.cond.broadcast();
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));
                            _ = self;

                            switch (et) {
                                inline .trigger_job => {
                                    switch (ev.trigger_job.route) {
                                        inline else => |r| {
                                            const R = comptime Routes[@intFromEnum(r)];
                                            try R.call(inj, .{});
                                        },
                                    }
                                },
                                else => @compileError("Invalid handler mapping!"),
                            }
                        }
                    };
                }
            };
        }
    };

    return H.CronHandler;
}

pub const CapabilityType = enum { name };

pub const Capability = union(CapabilityType) {
    name: []const u8,
};

pub fn From(comptime Container: type) []type {
    const routes = comptime blk: {
        var rp = RouteParser(){ .routes = &.{} };

        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }

        break :blk rp.routes;
    };

    return routes;
}

pub fn RouteBase(
    comptime sched: CronTemplate.VM.Schedule,
    comptime HandlerFac: anytype,
    comptime parsed_id: []const u8,
) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const schedule = sched;
        pub const id = parsed_id;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(
                schedule,
                NextHandler,
                parsed_id,
            );
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(
                schedule,
                NextHandlerFac(HandlerFac).make,
                parsed_id,
            );
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by CRON routes.",
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
                inline .name => |n| RouteBase(
                    schedule,
                    HandlerFac,
                    n,
                ),
            };
        }

        pub fn query(comptime ct: anytype) @field(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .name => parsed_id,
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
                @setEvalBranchQuota(10000);
                const tokens = CronTemplate.Lexer.lex(fnname);
                const ast = CronTemplate.Parser.parse(tokens);
                const schedule = CronTemplate.VM.evalToplevel(ast);
                const job_name = schedule.name orelse @compileError("Cron routes must have names.");
                const f = @field(Container, fnname);

                const fargs = @typeInfo(@TypeOf(f)).@"fn".params;
                const has_context = fargs.len > 0 and blk: {
                    const ti = @typeInfo(fargs[0].type.?);
                    switch (ti) {
                        .@"struct" => |s| break :blk s.is_tuple,
                        else => break :blk false,
                    }
                };

                const di_start_idx = if (has_context) 1 else 0;
                const __CallContext = if (has_context) fargs[0].type.? else struct {};

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
                                return std.fmt.allocPrint(allocator, "cron: {s}", .{job_name});
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

                const RB = RouteBase(schedule, H.make, job_name);

                return self.extend(RB);
            }
        }
    };
}

fn calcNext(timestamp: i64, schedule: CronTemplate.VM.Schedule) i64 {
    var candidate = timestamp + 1; // Start checking from next second
    while (true) {
        const n = nextOffset(schedule, candidate);
        if (n == 0) {
            return candidate;
        }
        candidate += n;
    }
}

test "Calculate next: 0 */5 * * * *" {
    const template = comptime CronTemplate.Lexer.lex("job 0 */5 * * * *");
    const ast = comptime CronTemplate.Parser.parse(template);

    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    try std.testing.expectEqual(
        300,
        calcNext(0, schedule),
    );
    try std.testing.expectEqual(
        600,
        calcNext(300, schedule),
    );

    try std.testing.expectEqual(
        300,
        calcNext(5, schedule),
    );

    try std.testing.expectEqual(
        300,
        calcNext(299, schedule),
    );

    try std.testing.expectEqual(
        3600,
        calcNext(3300, schedule),
    );

    try std.testing.expectEqual(
        24 * 3600,
        calcNext(24 * 3600 - 300, schedule),
    );

    try std.testing.expectEqual(
        31 * 24 * 3600,
        calcNext(31 * 24 * 3600 - 300, schedule),
    );

    try std.testing.expectEqual(
        365 * 24 * 3600,
        calcNext(365 * 24 * 3600 - 300, schedule),
    );
}

test "Calculate next: 30 */5 * * * * (second-level offset)" {
    const template = comptime CronTemplate.Lexer.lex("job 30 */5 * * * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    // Second 30 of minute 0
    try std.testing.expectEqual(
        30,
        calcNext(0, schedule),
    );

    // Second 30 of minute 5
    try std.testing.expectEqual(
        330,
        calcNext(30, schedule),
    );

    // From middle of minute 5, still lands on second 30
    try std.testing.expectEqual(
        330,
        calcNext(300, schedule),
    );

    // Second 30 of minute 10
    try std.testing.expectEqual(
        630,
        calcNext(330, schedule),
    );
}

test "Calculate next: 0 0 0 1 * * (monthly on the 1st)" {
    const template = comptime CronTemplate.Lexer.lex("job 0 0 0 1 * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    const jan1: i64 = 0;
    const feb1: i64 = 31 * 24 * 3600;
    const mar1: i64 = (31 + 28) * 24 * 3600;
    const apr1: i64 = (31 + 28 + 31) * 24 * 3600;

    // Jan 1 00:00:00 → Feb 1 00:00:00
    try std.testing.expectEqual(feb1, calcNext(jan1, schedule));

    // Feb 1 00:00:00 → Mar 1 00:00:00
    try std.testing.expectEqual(mar1, calcNext(feb1, schedule));

    // Mar 1 00:00:00 → Apr 1 00:00:00
    try std.testing.expectEqual(apr1, calcNext(mar1, schedule));

    // Jan 31 23:59:59 → Feb 1 00:00:00
    try std.testing.expectEqual(feb1, calcNext(feb1 - 1, schedule));
}

test "Calculate next: 0 0 12 * * * (daily at noon)" {
    const template = comptime CronTemplate.Lexer.lex("job 0 0 12 * * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    const noon: i64 = 12 * 3600;

    // Midnight → same day noon
    try std.testing.expectEqual(noon, calcNext(0, schedule));

    // Noon → next day noon
    try std.testing.expectEqual(noon + 24 * 3600, calcNext(noon, schedule));

    // 1pm → next day noon
    try std.testing.expectEqual(noon + 24 * 3600, calcNext(13 * 3600, schedule));
}

fn nextOffset(schedule: CronTemplate.VM.Schedule, timestamp: i64) i64 {
    // NOTE: This is probably incorrect. But my brain hurty.
    const epoch = std.time.epoch.EpochSeconds{
        .secs = @intCast(timestamp),
    };
    const second = epoch.getDaySeconds().getSecondsIntoMinute();
    const soffset = @ctz(schedule.seconds >> second);
    const minute = epoch.getDaySeconds().getMinutesIntoHour();
    const moffset = @ctz(schedule.minutes >> minute);
    const hour = epoch.getDaySeconds().getHoursIntoDay();
    const hoffset = @ctz(schedule.hours >> hour);
    const epoch_year = epoch.getEpochDay().calculateYearDay();
    const epoch_month = epoch_year.calculateMonthDay().month;
    const day = epoch_year.calculateMonthDay().day_index;
    const daysInMonth = std.time.epoch.getDaysInMonth(epoch_year.year, epoch_month);
    const doffset = @ctz(schedule.daysOfMonth >> day);
    const month = epoch_month.numeric() - 1;
    const mthoffset = @ctz(schedule.months >> month);

    if (soffset +| second < 59 and second != 59 and soffset != 0) {
        // There is still a next second that will match.
        return @as(i64, soffset);
    }
    // No seconds left that will match.

    if (moffset +| minute < 59 and minute != 59 and moffset != 0) {
        return @as(i64, moffset) * 60 - second;
    }

    if (hoffset +| hour < 23 and hour != 23 and hoffset != 0) {
        return @as(i64, hoffset) * 60 * 60 - minute * 60 - second;
    }

    if (doffset != 0 and doffset +| day < daysInMonth) {
        return @as(i64, doffset) * 24 * 60 * 60 - @as(i64, hour) * 60 * 60 - @as(i64, minute) * 60 - second;
    }

    if (mthoffset != 0 and mthoffset +| month < 11 and month != 11) {
        // We calculate the minimum safe offset to jump by.
        // All months have at least 28 days so this is safe.
        // This lets us hone in on the correct date with the next iteration without
        // complex date calculations.
        const total = @as(i64, 28) * mthoffset * 24 * 60 * 60;

        return total - @as(i64, day) * 24 * 60 * 60 - @as(i64, hour) * 60 * 60 - @as(i64, minute) * 60 - @as(i64, second);
    }

    if (mthoffset >= 11) {
        return (12 - @as(i64, month)) * 28 * 24 * 60 * 60;
    }

    if (doffset >= daysInMonth) {
        return (@as(i64, daysInMonth) - day) * 24 * 60 * 60;
    }

    if (hoffset >= 23) {
        return (@as(i64, 24) - hour) * 60 * 60;
    }

    if (moffset >= 59) {
        return (@as(i64, 60) - minute) * 60;
    }

    if (soffset >= 59) {
        return @as(i64, 60) - second;
    }

    return 0;
}

comptime {
    const Drv = Driver
        .new(.cron)
        .listen(false)
        .jobs(0)
        .routes(&.{})
        .build();

    @import("../driver.zig").AssertDriver(Drv, .cron);
}
