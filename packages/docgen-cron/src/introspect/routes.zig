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
    return struct { key: []const u8, jobs: []const JobVM };
}

fn CronNext(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, job: JobVM };
}

fn findCronDocument(comptime Docs: type, key: []const u8) ?Docs.CronDocument {
    for (Docs.cron_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

/// The single data-acquisition seam for the cron view. Today it projects the
/// manifest document through `calcNext`; when dynamic timers become visible this
/// is where the live scheduler query (via a shim) joins in — routes and templates
/// stay put.
fn jobSnapshots(
    comptime Docs: type,
    document: Docs.CronDocument,
    now: i64,
    allocator: std.mem.Allocator,
) ![]const JobVM {
    const jobs = try allocator.alloc(JobVM, document.jobs.len);
    for (document.jobs, 0..) |job, i| {
        jobs[i] = try snapshot(job, now, allocator);
    }
    return jobs;
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
    const next = cron.calcNext(now, sched);
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
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(CronView(Docs), &.{200}) {
            // Next-fire is time-sensitive: never let the browser reuse a stale fragment.
            body.response.header("Cache-Control", "no-cache");

            const now = std.time.timestamp();
            const doc = findCronDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{ .key = body.captures.key, .jobs = &.{} } },
            };

            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .jobs = try jobSnapshots(Docs, doc, now, allocator.value),
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
