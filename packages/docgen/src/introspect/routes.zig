//! The generic (transport-agnostic) introspection routes: the redirect shell, the driver
//! chrome (driver page, sidebar list, per-driver icon card), the favicon endpoint, and the
//! JSON pretty-printer that backends render responses through. All are served over HTTP and
//! rendered through the `core` zmpl prefix; the favicon is a raw asset (excluded from
//! templating). Driver-specific operation browsers live in the per-kind backends.
//!
//! The generated manifest is threaded in as the comptime `Docs` parameter (not `@import`ed)
//! to keep this module free of a static edge to docgen's output — see `assemble.zig`.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const http_template = @import("kw-http-template");

fn prettyJson(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    var buf: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(parsed.value);
    return buf.written();
}

/// The fixed generic routes, generated over the manifest `Docs`. Template ids match the
/// `core`-prefix `.zmpl` files.
fn Core(comptime Docs: type, comptime icons: []const KindIcon) type {
    return struct {
        const DriverResponse = struct {
            drivers: []const Docs.DriverInfo,
            active: Docs.DriverInfo,
        };

        const JsonRender = struct {
            body: []const u8,
        };

        /// The driver-icon card's data: the kind/key plus the `fingerprint` of that kind's
        /// icon, which the template bakes into the favicon URL so it versions per icon.
        const IconCard = struct {
            kind: []const u8,
            key: []const u8,
            fingerprint: []const u8,
        };

        /// The URL fingerprint for a kind's icon (the embedded backend default, else generic).
        fn fingerprintFor(kind: []const u8) []const u8 {
            inline for (icons) |ic| {
                if (std.mem.eql(u8, ic.kind, kind)) return ic.fp;
            }
            return default_fp;
        }

        pub fn @"GET _introspect @introspectIndex"(_: http.data.Request(null)) http.data.Html(
            struct { title: []const u8 },
            &.{200},
        ) {
            return .{ .value = .{ .ok = .{ .title = "KW-IntrospectUI" } } };
        }

        pub fn @"GET _introspect/{kind}/{key} @introspectDriver"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { kind: []const u8, key: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(Docs.DriverInfo, &.{ 200, 404 }) {
            inline for (Docs.drivers) |D| {
                if (std.mem.eql(u8, D.key, body.captures.key) and std.mem.eql(u8, D.kind, body.captures.kind)) {
                    return .{ .value = .{ .ok = .{ .kind = D.kind, .key = D.key } } };
                }
            }

            const properties = try depctx.require(core.event.Properties);
            const instance = try std.fmt.allocPrint(allocator.value, "{d}", .{properties.correlation_id});

            return .{
                .value = .{
                    .not_found = .{
                        .instance = instance,
                        .type = error.NotFound,
                        .title = "Driver not found",
                        .details = "No driver matches the given kind and key.",
                    },
                },
            };
        }

        pub fn @"GET _introspect/{kind}/{key}/icon @driverIcon"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { kind: []const u8, key: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(IconCard, &.{ 200, 404 }) {
            inline for (Docs.drivers) |D| {
                if (std.mem.eql(u8, D.key, body.captures.key) and std.mem.eql(u8, D.kind, body.captures.kind)) {
                    return .{ .value = .{ .ok = .{
                        .kind = D.kind,
                        .key = D.key,
                        .fingerprint = fingerprintFor(D.kind),
                    } } };
                }
            }

            const properties = try depctx.require(core.event.Properties);
            const instance = try std.fmt.allocPrint(allocator.value, "{d}", .{properties.correlation_id});

            return .{
                .value = .{
                    .not_found = .{
                        .instance = instance,
                        .type = error.NotFound,
                        .title = "Icon not found",
                        .details = "An icon for the given kind and key could not be found.",
                    },
                },
            };
        }

        pub fn @"GET _introspect/drivers @getDrivers"(
            rq: http.data.FullRequest(null, struct {
                key: []const u8 = "internal",
                kind: []const u8 = "internal",
            }),
        ) http.data.Json(DriverResponse, &.{200}) {
            var active: Docs.DriverInfo = .{ .kind = "internal", .key = "internal" };
            inline for (Docs.drivers) |D| {
                if (std.mem.eql(u8, D.key, rq.query.key) and std.mem.eql(u8, D.kind, rq.query.kind)) {
                    active = .{ .kind = D.kind, .key = D.key };
                }
            }

            return .{ .value = .{ .ok = .{ .drivers = Docs.drivers, .active = active } } };
        }

        pub fn @"POST _introspect/render/application/json @renderJson"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
            },
            allocator: core.mem.ScopedAllocator,
        ) http.data.Html(JsonRender, &.{200}) {
            const raw = body.request.body() orelse "";
            const pretty = prettyJson(allocator.value, raw) catch raw;
            return .{ .value = .{ .ok = .{ .body = pretty } } };
        }
    };
}

/// One driver kind's embedded default icon, with both validators baked at comptime: `tag`
/// (quoted, for the `ETag` header) and `fp` (bare hex, for the fingerprinted URL).
const KindIcon = struct { kind: []const u8, bytes: []const u8, tag: []const u8, fp: []const u8 };

/// The generic fallback icon, embedded with comptime validators.
const default_icon: []const u8 = @embedFile("assets/default.svg");
const default_tag: []const u8 = http.data.etag(default_icon);
const default_fp: []const u8 = http.data.fingerprint(default_icon);

/// Collect each backend's embedded icon (with its comptime validators) into a table the
/// favicon route matches on. Backends without an `icon` simply don't contribute one.
fn iconList(comptime backends: anytype) []const KindIcon {
    comptime {
        var list: []const KindIcon = &.{};
        for (backends) |m| {
            if (@hasDecl(m, "icon") and @hasDecl(m, "introspected_kind"))
                list = list ++ &[_]KindIcon{.{
                    .kind = m.introspected_kind,
                    .bytes = m.icon,
                    .tag = http.data.etag(m.icon),
                    .fp = http.data.fingerprint(m.icon),
                }};
        }
        return list;
    }
}

/// The favicon route, generated with the backend icon table baked in. The URL carries the
/// icon's content fingerprint (`{fp}`), so it versions per icon and we can serve it
/// `immutable` with a long max-age — a changed icon means a changed URL, never a stale cache.
/// `{fp}` is only a cache key; the route resolves bytes purely from `{kind}` (the matching
/// backend's embedded icon, else the generic default).
fn Favicon(comptime icons: []const KindIcon) type {
    return struct {
        pub fn @"GET _introspect/{kind}/{key}/{fp}/favicon.svg"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { kind: []const u8, key: []const u8, fp: []const u8 },
            },
        ) http.data.InternalFile("image/svg+xml") {
            body.response.header("Cache-Control", "public, max-age=31536000, immutable");

            inline for (icons) |ic| {
                if (std.mem.eql(u8, ic.kind, body.captures.kind))
                    return .{ .value = ic.bytes, .tag = ic.tag };
            }

            return .{ .value = default_icon, .tag = default_tag };
        }
    };
}

/// Build the generic core routes (always contributed once). Returns a kind-keyed struct; the
/// UI is served over HTTP, so everything lands under `.http`. The favicon is excluded from
/// templating (it's a raw `image/svg+xml` asset).
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn coreRoutes(comptime Docs: type, comptime backends: anytype) struct { http: []const type } {
    const icons = iconList(backends);
    const all = http.From(Core(Docs, icons), void) ++ http.From(Favicon(icons), void);
    return .{ .http = http_template.WithTemplates("core", all, &.{"image/svg+xml"}) };
}
