//! The cron-specific introspection routes: the static job list and the per-job
//! next-fire fragment. They read the cron projection (`cron_documents`) that this
//! package's `runtime.zig` emits into the docgen manifest — threaded in as the
//! comptime `Docs` parameter (not `@import`ed) so this module carries no static
//! edge to docgen's output (which would form a build cycle).
//!
//! Liveness: next-fire is computed per request from the manifest's schedule
//! bitmasks via `cron.calcNext` — the same function the scheduler runs, so the
//! displayed time cannot diverge from the real one. Each job's next-fire fragment
//! is self-scheduling: it re-requests itself `next_fire - now + buffer` seconds
//! later (htmx `load delay:`), i.e. one request per fire event, timed to land just
//! after the value changes.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const http_template = @import("kw-http-template");
const cron = @import("kw-cron");

/// How long past the computed fire time the fragment re-polls, so a slow tick on
/// the scheduler side can't make us render a stale "in 0s" and go back to sleep.
const poll_buffer_s: i64 = 2;

/// One job as the templates consume it — a projection shaped to stay compatible
/// with `cron.JobInfo`, so live scheduler rows (dynamic timers, via a future shim)
/// can populate the same templates. Manifest-only fields (expression, docs) will
/// simply be empty for dynamic rows.
const JobVM = struct {
    name: []const u8,
    kind: []const u8, // "static" today; "dynamic" once scheduler-backed rows land
    expression: []const u8,
    summary: []const u8,
    description: []const u8,
    next_fire_at: []const u8,
    next_fire_in: []const u8,
    poll_delay: []const u8,
};

fn CronView(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, jobs: []const JobVM, cancelled: []const JobVM };
}

/// Response of the cancel/resurrect actions: which pane to reload.
fn CronAction(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, pane: []const u8 };
}

fn CronNext(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, job: JobVM };
}

/// The tab chrome: just enough to render the Routes/Timers tab bar.
fn Chrome(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8 };
}

/// The dynamic-timers pane. `status` is non-empty when there is a message to
/// show instead of rows (shim not wired, or simply no timers pending);
/// `refresh_delay` drives the whole-pane self-reload.
fn CronTimers(comptime Docs: type) type {
    _ = Docs;
    return struct {
        key: []const u8,
        timers: []const JobVM,
        refresh_delay: []const u8,
        status: []const u8,
    };
}

fn findCronDocument(comptime Docs: type, key: []const u8) ?Docs.CronDocument {
    for (Docs.cron_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

const Snapshots = struct {
    active: []const JobVM,
    cancelled: []const JobVM,
};

/// The data-acquisition seam for the routes pane. Schedules render exclusively
/// from the manifest; the live scheduler is consulted only for *existence* —
/// a manifest job with no live route entry has been cancelled. One `list` call
/// (a single lock acquisition) covers all jobs; without a shim everything
/// renders as active.
fn jobSnapshots(
    comptime Docs: type,
    document: Docs.CronDocument,
    now: i64,
    allocator: std.mem.Allocator,
    shim: ?cron.SchedulerShim,
) !Snapshots {
    const live: []cron.JobInfo = if (shim) |s| s.list(allocator) catch &.{} else &.{};

    const alive = try allocator.alloc(bool, document.jobs.len);
    var n_active: usize = 0;
    for (document.jobs, 0..) |job, i| {
        alive[i] = shim == null or blk: {
            for (live) |ji| {
                if (std.mem.eql(u8, ji.kind, "route") and std.mem.eql(u8, ji.id, job.name)) break :blk true;
            }
            break :blk false;
        };
        if (alive[i]) n_active += 1;
    }

    const active = try allocator.alloc(JobVM, n_active);
    const cancelled = try allocator.alloc(JobVM, document.jobs.len - n_active);
    var ai: usize = 0;
    var ci: usize = 0;
    for (document.jobs, 0..) |job, i| {
        const vm = try snapshot(job, now, allocator);
        if (alive[i]) {
            active[ai] = vm;
            ai += 1;
        } else {
            cancelled[ci] = vm;
            ci += 1;
        }
    }
    return .{ .active = active, .cancelled = cancelled };
}

/// Project one manifest job to its view model. `job` is `Docs.CronJob` (anytype:
/// the manifest types are per-app generated, so they can't be named here).
fn snapshot(job: anytype, now: i64, allocator: std.mem.Allocator) !JobVM {
    const sched = cron.VMSchedule{
        .seconds = job.schedule.seconds,
        .minutes = job.schedule.minutes,
        .hours = job.schedule.hours,
        .daysOfMonth = job.schedule.days_of_month,
        .months = job.schedule.months,
        .daysOfWeek = job.schedule.days_of_week,
        .name = null,
    };
    const next = cron.calcNext(now, .{ .schedule = sched });
    const in_s = @max(0, next - now);

    return .{
        .name = job.name,
        .kind = "static",
        .expression = job.expression,
        .summary = job.summary,
        .description = job.description,
        .next_fire_at = try formatUtc(allocator, next),
        .next_fire_in = try std.fmt.allocPrint(allocator, "{d}s", .{in_s}),
        .poll_delay = try std.fmt.allocPrint(allocator, "{d}", .{in_s + poll_buffer_s}),
    };
}

fn formatUtc(allocator: std.mem.Allocator, ts: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// Project one live scheduler row (an anonymous/dynamic timer) to the shared
/// view model. Static route rows render exclusively from the manifest; live
/// data feeds dynamic timers only. `ji`'s strings are borrowed (they share the
/// request allocator here, so lifetimes coincide).
fn dynamicSnapshot(ji: cron.JobInfo, now: i64, allocator: std.mem.Allocator) !JobVM {
    const in_s = @max(0, ji.scheduled_for - now);
    return .{
        .name = ji.id,
        .kind = "dynamic",
        .expression = switch (ji.source) {
            .delay => |d| try std.fmt.allocPrint(allocator, "+{d}s", .{d}),
            .schedule => "(dynamic schedule)",
        },
        .summary = ji.on_invoke_action,
        .description = "",
        .next_fire_at = try formatUtc(allocator, ji.scheduled_for),
        .next_fire_in = try std.fmt.allocPrint(allocator, "{d}s", .{in_s}),
        // The timers pane refreshes whole-pane and ignores this, but the
        // per-job fragment route can also serve dynamic jobs — give it a real
        // delay so a standalone fragment never re-polls in a tight loop.
        .poll_delay = try std.fmt.allocPrint(allocator, "{d}", .{in_s + poll_buffer_s}),
    };
}

/// The problem-detail `instance` for a not-found response: the request's correlation id.
/// `Properties` is injected per-event into the ad-hoc inner container, so it is pulled from
/// `depctx` in the body rather than declared as a handler param (the outer-generator analysis
/// can't see it).
fn instanceId(depctx: *core.deps.DepCtx, allocator: core.mem.ScopedAllocator) ![]const u8 {
    const properties = try depctx.require(core.event.Properties);
    return std.fmt.allocPrint(allocator.value, "{d}", .{properties.correlation_id});
}

fn notFound(comptime Docs: type, instance: []const u8) http.data.ApiResult(CronNext(Docs), http.data.ProblemDetails, &.{ 200, 404 }) {
    return .{
        .not_found = .{
            .type = error.NotFound,
            .title = "Job not found",
            .details = "No job with that name is registered on this driver.",
            .instance = instance,
        },
    };
}

fn Routes(comptime Docs: type) type {
    return struct {
        pub fn @"GET _introspect/cron/{key}/view @cronView"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
        ) !http.data.Html(Chrome(Docs), &.{200}) {
            return .{ .value = .{ .ok = .{ .key = body.captures.key } } };
        }

        pub fn @"GET _introspect/cron/{key}/routes @cronRoutes"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(CronView(Docs), &.{200}) {
            // Next-fire is time-sensitive: never let the browser reuse a stale fragment.
            body.response.header("Cache-Control", "no-cache");

            const now = std.time.timestamp();
            const doc = findCronDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{ .key = body.captures.key, .jobs = &.{}, .cancelled = &.{} } },
            };

            const shim: ?cron.SchedulerShim = depctx.require(cron.SchedulerShim) catch null;
            const snapshots = try jobSnapshots(Docs, doc, now, allocator.value, shim);
            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .jobs = snapshots.active,
                .cancelled = snapshots.cancelled,
            } } };
        }

        pub fn @"POST _introspect/cron/{key}/job/{kind}/{name}/cancel @cronJobCancel"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, kind: []const u8, name: []const u8 },
            },
            depctx: *core.deps.DepCtx,
        ) !http.data.Html(CronAction(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const is_static = std.mem.eql(u8, body.captures.kind, "static");

            const maybe_shim: ?cron.SchedulerShim = depctx.require(cron.SchedulerShim) catch null;
            if (maybe_shim) |shim| {
                const id: cron.ShimId = if (is_static)
                    .{ .route = body.captures.name }
                else
                    .{ .anonymous = body.captures.name };
                // Null means the job was already gone — same UI outcome, the
                // reloaded pane reflects reality either way.
                _ = shim.cancel(id);
            }

            return .{ .value = .{ .ok = .{
                .key = body.captures.key,
                .pane = if (is_static) "routes" else "timers",
            } } };
        }

        pub fn @"POST _introspect/cron/{key}/job/{kind}/{name}/run @cronJobRun"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, kind: []const u8, name: []const u8 },
            },
            depctx: *core.deps.DepCtx,
        ) !http.data.Html(CronAction(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const is_static = std.mem.eql(u8, body.captures.kind, "static");

            const maybe_shim: ?cron.SchedulerShim = depctx.require(cron.SchedulerShim) catch null;
            if (maybe_shim) |shim| {
                const id: cron.ShimId = if (is_static)
                    .{ .route = body.captures.name }
                else
                    .{ .anonymous = body.captures.name };
                // Fire-and-keep: an extra run, the schedule is untouched. Null
                // (job already gone) and push errors both resolve to the same
                // UI outcome — the reloaded pane shows reality.
                _ = shim.trigger(id) catch null;
            }

            return .{ .value = .{ .ok = .{
                .key = body.captures.key,
                .pane = if (is_static) "routes" else "timers",
            } } };
        }

        pub fn @"POST _introspect/cron/{key}/job/{name}/resurrect @cronJobResurrect"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, name: []const u8 },
            },
            depctx: *core.deps.DepCtx,
        ) !http.data.Html(CronAction(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");

            const maybe_shim: ?cron.SchedulerShim = depctx.require(cron.SchedulerShim) catch null;
            if (maybe_shim) |shim| {
                // UnknownRoute means a stale button; the pane reload corrects it.
                shim.resurrect(body.captures.name) catch {};
            }

            return .{ .value = .{ .ok = .{
                .key = body.captures.key,
                .pane = "routes",
            } } };
        }

        pub fn @"GET _introspect/cron/{key}/timers @cronTimers"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(CronTimers(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;
            const now = std.time.timestamp();

            const shim = depctx.require(cron.SchedulerShim) catch {
                return .{ .value = .{ .ok = .{
                    .key = body.captures.key,
                    .timers = &.{},
                    .refresh_delay = "10",
                    .status = "Scheduler shim is not wired; live timers are unavailable.",
                } } };
            };

            const live = try shim.list(a);
            std.mem.sort(cron.JobInfo, live, {}, struct {
                fn lt(_: void, x: cron.JobInfo, y: cron.JobInfo) bool {
                    return x.scheduled_for < y.scheduled_for;
                }
            }.lt);

            var count: usize = 0;
            for (live) |ji| {
                if (std.mem.eql(u8, ji.kind, "anonymous")) count += 1;
            }

            const rows = try a.alloc(JobVM, count);
            var earliest: ?i64 = null;
            var i: usize = 0;
            for (live) |ji| {
                if (!std.mem.eql(u8, ji.kind, "anonymous")) continue;
                rows[i] = try dynamicSnapshot(ji, now, a);
                if (earliest == null) earliest = ji.scheduled_for;
                i += 1;
            }

            // Reload the whole pane just after the earliest timer fires (so
            // done one-shots drop out on time), capped so newly created timers
            // still show up promptly when nothing is about to fire.
            const delay: i64 = if (earliest) |e| @min(@max(e - now, 0) + poll_buffer_s, 10) else 10;

            return .{ .value = .{ .ok = .{
                .key = body.captures.key,
                .timers = rows,
                .refresh_delay = try std.fmt.allocPrint(a, "{d}", .{delay}),
                .status = if (rows.len == 0) "No dynamic timers pending." else "",
            } } };
        }

        pub fn @"GET _introspect/cron/{key}/job/{name}/next @cronJobNext"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, name: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(CronNext(Docs), &.{ 200, 404 }) {
            body.response.header("Cache-Control", "no-cache");

            const now = std.time.timestamp();
            if (findCronDocument(Docs, body.captures.key)) |doc| {
                for (doc.jobs) |job| {
                    if (std.mem.eql(u8, job.name, body.captures.name)) {
                        return .{ .value = .{ .ok = .{
                            .key = doc.key,
                            .job = try snapshot(job, now, allocator.value),
                        } } };
                    }
                }
            }

            // Dynamic timers aren't in the manifest — ask the live scheduler.
            const maybe_shim: ?cron.SchedulerShim = depctx.require(cron.SchedulerShim) catch null;
            if (maybe_shim) |shim| {
                if (try shim.query(.{ .anonymous = body.captures.name }, allocator.value)) |ji| {
                    return .{ .value = .{ .ok = .{
                        .key = body.captures.key,
                        .job = try dynamicSnapshot(ji, now, allocator.value),
                    } } };
                }
            }

            return .{ .value = notFound(Docs, try instanceId(depctx, allocator)) };
        }
    };
}

/// Build this backend's introspection routes. All are HTTP-served, so the result is keyed
/// `http`; templates ship in this package under the `cron` prefix.
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn generate(comptime Docs: type) struct { http: []const type } {
    return .{ .http = http_template.WithTemplates("cron", http.From(Routes(Docs), void), &.{}) };
}
