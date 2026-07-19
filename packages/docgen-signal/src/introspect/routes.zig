//! The signal-specific introspection routes: the per-signal handler list and the
//! Send action. They read the signal projection (`signal_documents`) that this
//! package's `runtime.zig` emits into the docgen manifest — threaded in as the
//! comptime `Docs` parameter (not `@import`ed) so this module carries no static
//! edge to docgen's output (which would form a build cycle).
//!
//! Send fires a *real* signal at the process (`kill(getpid(), signum)`). This is
//! reliable because the app blocks every routed signal process-wide before any
//! thread spawns (see `signal.blockRouted`), making the driver's sigtimedwait
//! thread the sole consumer — so the raised signal is queued and dispatched to
//! all matching handlers instead of hitting a thread's default disposition.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("kw-core");
const http = @import("kw-http");
const http_template = @import("kw-http-template");

/// One handler as the templates consume it.
const HandlerVM = struct {
    id: []const u8,
    summary: []const u8,
    description: []const u8,
};

/// One signal group: the signal plus every handler that fans out from it.
/// `signum` is preformatted — zmpl interpolation consumes strings.
const GroupVM = struct {
    name: []const u8,
    signum: []const u8,
    handlers: []const HandlerVM,
};

/// The single static pane (no tab chrome needed for one pane).
fn SignalView(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8 };
}

/// The signal list: `groups` are sendable; `blocked` are the uncatchable ones
/// (KILL/STOP), rendered with a disabled Send — split into two lists so the
/// template needs no conditional around the button (the cron jobs/cancelled
/// pattern).
fn SignalList(comptime Docs: type) type {
    _ = Docs;
    return struct {
        key: []const u8,
        groups: []const GroupVM,
        blocked: []const GroupVM,
    };
}

/// Response of the Send action: empty `status` reloads the pane, non-empty
/// renders as an error line.
fn SignalSend(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, status: []const u8 };
}

fn findSignalDocument(comptime Docs: type, key: []const u8) ?Docs.SignalDocument {
    for (Docs.signal_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

/// KILL and STOP cannot be blocked or caught — they never reach the driver's
/// sigtimedwait thread; sending them would just kill/freeze the process.
fn uncatchable(name: []const u8) bool {
    return std.mem.eql(u8, name, "KILL") or std.mem.eql(u8, name, "STOP");
}

/// Project one manifest group to its view model. `g` is `Docs.SignalGroup`
/// (anytype: the manifest types are per-app generated, so they can't be named
/// here).
fn groupVM(g: anytype, allocator: std.mem.Allocator) !GroupVM {
    const handlers = try allocator.alloc(HandlerVM, g.handlers.len);
    for (g.handlers, 0..) |h, i| {
        handlers[i] = .{ .id = h.id, .summary = h.summary, .description = h.description };
    }
    return .{
        .name = g.name,
        .signum = try std.fmt.allocPrint(allocator, "{d}", .{g.signum}),
        .handlers = handlers,
    };
}

fn Routes(comptime Docs: type) type {
    return struct {
        pub fn @"GET _introspect/signal/{key}/view @signalView"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
        ) !http.data.Html(SignalView(Docs), &.{200}) {
            return .{ .value = .{ .ok = .{ .key = body.captures.key } } };
        }

        pub fn @"GET _introspect/signal/{key}/routes @signalRoutes"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SignalList(Docs), &.{200}) {
            // The pane is re-fetched after Send: never let the browser reuse a
            // stale fragment.
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            const doc = findSignalDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{ .key = body.captures.key, .groups = &.{}, .blocked = &.{} } },
            };

            var n_blocked: usize = 0;
            for (doc.signals) |g| {
                if (uncatchable(g.name)) n_blocked += 1;
            }

            const groups = try a.alloc(GroupVM, doc.signals.len - n_blocked);
            const blocked = try a.alloc(GroupVM, n_blocked);
            var gi: usize = 0;
            var bi: usize = 0;
            for (doc.signals) |g| {
                const vm = try groupVM(g, a);
                if (uncatchable(g.name)) {
                    blocked[bi] = vm;
                    bi += 1;
                } else {
                    groups[gi] = vm;
                    gi += 1;
                }
            }

            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .groups = groups,
                .blocked = blocked,
            } } };
        }

        pub fn @"POST _introspect/signal/{key}/sig/{signame}/send @signalSend"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, signame: []const u8 },
            },
        ) !http.data.Html(SignalSend(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const key = body.captures.key;

            if (comptime builtin.os.tag != .linux) {
                return .{ .value = .{ .ok = .{
                    .key = key,
                    .status = "Signal sending is only supported on Linux.",
                } } };
            }

            const doc = findSignalDocument(Docs, key) orelse return .{
                .value = .{ .ok = .{ .key = key, .status = "Unknown driver key." } },
            };

            // The manifest is the allowlist: only signals this driver actually
            // routes are sendable — anything else 404s into a status line.
            for (doc.signals) |g| {
                if (!std.mem.eql(u8, g.name, body.captures.signame)) continue;
                if (uncatchable(g.name)) {
                    return .{ .value = .{ .ok = .{
                        .key = key,
                        .status = "SIGKILL/SIGSTOP cannot be caught; refusing to send.",
                    } } };
                }
                std.posix.kill(std.os.linux.getpid(), @intCast(g.signum)) catch {
                    return .{ .value = .{ .ok = .{ .key = key, .status = "kill() failed." } } };
                };
                return .{ .value = .{ .ok = .{ .key = key, .status = "" } } };
            }
            return .{ .value = .{ .ok = .{
                .key = key,
                .status = "No routed handler for that signal.",
            } } };
        }
    };
}

/// Build this backend's introspection routes. All are HTTP-served, so the result is keyed
/// `http`; templates ship in this package under the `signal` prefix.
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn generate(comptime Docs: type) struct { http: []const type } {
    return .{ .http = http_template.WithTemplates("signal", http.From(Routes(Docs), void), &.{}) };
}
