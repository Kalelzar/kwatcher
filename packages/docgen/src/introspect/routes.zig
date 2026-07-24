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
const auth = @import("auth.zig");

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

        fn findDriver(kind: []const u8, key: []const u8) bool {
            inline for (Docs.drivers) |D| {
                if (std.mem.eql(u8, D.key, key) and std.mem.eql(u8, D.kind, kind)) {
                    return true;
                }
            }
            return false;
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
            if (findDriver(body.captures.kind, body.captures.key)) {
                return .{ .value = .{ .ok = .{ .kind = body.captures.kind, .key = body.captures.key } } };
            }

            const properties = try depctx.require(core.event.Properties);
            const instance = try std.fmt.allocPrint(allocator.value, "{f}", .{properties.correlation_id});

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
            if (findDriver(body.captures.kind, body.captures.key)) {
                return .{ .value = .{ .ok = .{
                    .kind = body.captures.kind,
                    .key = body.captures.key,
                    .fingerprint = fingerprintFor(body.captures.kind),
                } } };
            }

            const properties = try depctx.require(core.event.Properties);
            const instance = try std.fmt.allocPrint(allocator.value, "{f}", .{properties.correlation_id});

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
            if (findDriver(rq.query.kind, rq.query.key)) {
                active = .{ .kind = rq.query.kind, .key = rq.query.key };
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

/// One vendored frontend bundle, embedded into the binary so the UI loads its JS from this
/// app's own origin instead of a public CDN. The embedded bytes are gzip-compressed (the
/// `assets/vendor/*.gz` files), served verbatim under `Content-Encoding: gzip` — so there is no
/// comptime or per-request compression. `tag` is the comptime `ETag` over those compressed bytes,
/// which makes it a correct per-encoding validator with no extra bookkeeping. `name` is the
/// *logical* (uncompressed) name the URL/`_head` partial uses, e.g. `htmx.min.js`.
const Asset = struct { name: []const u8, bytes: []const u8, tag: []const u8 };

/// The vendored frontend libraries the introspection UI's `_head` partial loads, stored
/// pre-gzipped. All are JavaScript bundles, so they share one content type and one serving route.
/// Versions are pinned by the vendored file contents; bump by re-vendoring under `assets/vendor/`
/// (download piped through `gzip -n -9` so the bytes — and thus the `ETag` — stay deterministic).
const assets: []const Asset = &.{
    .{ .name = "htmx.min.js", .bytes = @embedFile("assets/vendor/htmx.min.js.gz"), .tag = http.data.etag(@embedFile("assets/vendor/htmx.min.js.gz")) },
    .{ .name = "idiomorph-ext.min.js", .bytes = @embedFile("assets/vendor/idiomorph-ext.min.js.gz"), .tag = http.data.etag(@embedFile("assets/vendor/idiomorph-ext.min.js.gz")) },
    .{ .name = "tailwind-browser.js", .bytes = @embedFile("assets/vendor/tailwind-browser.js.gz"), .tag = http.data.etag(@embedFile("assets/vendor/tailwind-browser.js.gz")) },
    .{ .name = "alpine.min.js", .bytes = @embedFile("assets/vendor/alpine.min.js.gz"), .tag = http.data.etag(@embedFile("assets/vendor/alpine.min.js.gz")) },
};

/// Serves the vendored frontend bundles from this app's own origin. The URL is a stable path
/// (not fingerprinted — the `_head` partial that references these takes no asset data), so it
/// carries an `ETag` for cheap revalidation rather than an `immutable` policy: a matching
/// `If-None-Match` short-circuits to a bodyless 304 (the framework does no conditional-GET
/// handling of its own). An unknown `{name}` is a 404 with an empty body.
const Assets = struct {
    pub fn @"GET _introspect/assets/{name}"(
        body: struct {
            request: *http.Request,
            response: *http.Response,
            captures: struct { name: []const u8 },
        },
    ) http.data.InternalFile("text/javascript") {
        inline for (assets) |a| {
            if (std.mem.eql(u8, a.name, body.captures.name)) {
                body.response.header("Cache-Control", "public, max-age=86400");
                // The embedded bytes are gzip; the `Content-Type` stays the JS type (set by
                // `InternalFile`) and `Content-Encoding` advertises the wire format.
                body.response.header("Content-Encoding", "gzip");
                // Conditional GET: if the client already holds this exact build (its
                // `If-None-Match` echoes our `ETag`), skip the body with a 304.
                if (body.request.header("if-none-match")) |inm| {
                    if (std.mem.eql(u8, inm, a.tag)) {
                        body.response.status = 304;
                        return .{ .value = "", .tag = a.tag };
                    }
                }
                return .{ .value = a.bytes, .tag = a.tag };
            }
        }
        body.response.status = 404;
        return .{ .value = "" };
    }
};

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
/// UI is served over HTTP, so everything lands under `.http`. The favicon (`image/svg+xml`)
/// and the vendored frontend bundles (`text/javascript`) are excluded from templating — they
/// are raw assets served straight from embedded bytes.
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn coreRoutes(comptime Docs: type, comptime backends: anytype) struct { http: []const type } {
    const icons = iconList(backends);
    const all = http.From(Core(Docs, icons), void) ++
        http.From(Favicon(icons), void) ++
        http.From(Assets, void) ++
        http.From(auth.Auth(Docs), void);
    // The auth login route stays outside the template pipeline: its useful
    // output is a 302 redirect, not a rendered page.
    return .{
        .http = http_template.WithTemplates("core", all, &.{ "image/svg+xml", "text/javascript" }) ++
            http.From(auth.Login(Docs), void),
    };
}
