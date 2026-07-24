//! The opinionated, hardcoded introspection mount: a second HTTP driver (`.private`) that serves
//! the assembled introspection UI, plus its registry/dependency wiring. This is the baked-in
//! default for the common case — the generic `Assemble` primitive (see `assemble.zig`) stays
//! exported for anyone who needs the non-opinionated path.
//!
//! Everything is hardcoded except `docs` and `backends`, which are threaded in by the consumer:
//! `kw-introspect` must never `@import` `kw-gen--docs` (that forms a build cycle through the
//! docgen tool — see `assemble.zig`), and importing the `kw-introspect--http` backend directly
//! would force a cycle too (the backend already depends on this package for docschema/docexample),
//! so both come in as comptime arguments — no extra build edge.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const kwatcher = @import("kwatcher");
const auth_oidc = @import("kw-auth-oidc");
const assemble = @import("assemble.zig");
const introspect_routes = @import("routes.zig");

const kwd = kwatcher.default;

/// Unprotected mount — kept as the compatibility surface. Prefer
/// `MountWith(docs, backends, .{ .auth = "<scheme>" })` for anything
/// reachable beyond localhost.
pub fn Mount(comptime docs: type, comptime backends: anytype) type {
    return MountWith(docs, backends, .{ .auth = null });
}

/// Build the hardcoded private introspection mount over `docs`/`backends` and expose its
/// registry/dep wiring. `docs` is named once here; `driver`/`register`/`deps` all close over it.
///
/// `opts.auth: ?[]const u8` — when set, every inner route (core fragments,
/// actions, renderers + all backend-generated routes) is wrapped in
/// kw-auth-oidc's bearer middleware under that scheme name, and the UI's own
/// `/_introspect/login` page is served. The open group (shell pages, both
/// login flows, static assets — all browser navigations that cannot carry a
/// bearer header) stays outside. Grouping is purely structural:
/// `open ++ WithAuth(protected)` — there is no route filtering or exemption
/// mechanism anywhere. The consumer still registers the DI side: the auth
/// extension for its settings config path, plus the `security.*Ctx`
/// registries (see the example app).
pub fn MountWith(comptime docs: type, comptime backends: anytype, comptime opts: anytype) type {
    return struct {
        /// Route composition, lazily analysed (only referenced from `driver`,
        /// itself only referenced from `register`'s non-docgen branch) — so
        /// neither template lookups nor route generation run during docgen.
        const http_routes = blk: {
            const auth_scheme: ?[]const u8 = opts.auth;
            const backend_assembly = assemble.AssembleBackends(docs, backends);
            const open = introspect_routes.openRoutes(docs, backends, auth_scheme != null);
            const inner = introspect_routes.innerRoutes(docs, backends);
            const protected = inner.http ++ backend_assembly(.http);
            const wrapped = if (auth_scheme) |scheme|
                auth_oidc.WithAuth(protected, .{ .scheme = scheme })
            else
                protected;
            break :blk open.http ++ wrapped;
        };

        /// The cors-wrapped, assembled introspection mount (a built `http.Driver` factory).
        /// Only referenced from `register`'s non-docgen branch, so it is never analysed (or
        /// cors-wrapped over the empty docgen route set) during docgen.
        const driver = http.Driver
            .new(.private)
            .config("driver.private")
            .listen(true)
            .jobs(1)
            .routes(http.middleware.cors(http_routes))
            .error_handler(http.DefaultErrorHandler)
            .build();

        /// Append the private introspection mount to the registry — a no-op during docgen, since
        /// the UI is generated *from* the docs and must not be in the graph that produces them.
        pub fn register(comptime base: core.DriverRegistry) core.DriverRegistry {
            return if (docs.isDocgen) base else base.registerHandler(driver);
        }

        /// Dephub extension for the mount's dependencies — a no-op during docgen. Registers, in
        /// order: the cors config; one keyed `http.Config` per http mount in the manifest except
        /// this one (so the Try-it form can target any served mount); and this mount's own
        /// `http.Config`. Wire it with `.with(.private, Mount(docs).deps, allocator)`.
        pub const deps = struct {
            pub fn apply(
                dephub: anytype,
                comptime category: anytype,
                allocator: std.mem.Allocator,
                comptime Config: type,
            ) Return(category, Config, @TypeOf(dephub)) {
                if (comptime docs.isDocgen) return dephub;
                const with_cors = dephub.with(category, kwd.config(http.middleware.Cors.Config, "middleware.cors"), allocator);
                const with_keyed = keyedMounts(with_cors, category, allocator, Config, 0);
                return with_keyed.with(category, kwd.config(http.Config, "driver.private"), allocator);
            }

            pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
                if (docs.isDocgen) return DH;
                const Cors = kwd.config(http.middleware.Cors.Config, "middleware.cors").Return(category, Config, DH);
                const Keyed = KeyedMounts(category, Config, Cors, 0);
                return kwd.config(http.Config, "driver.private").Return(category, Config, Keyed);
            }

            // Recurse over docs.drivers — recursion, not inline-for, because each `.with` changes
            // the dephub type — registering configKeyed(d.key, http.Config, "driver." ++ d.key)
            // for every http mount except `.private`. `KeyedMounts` is the type-level twin used by
            // `Return`. Mirrors `amqp.defaultFor`'s recursion and `hub.zig`'s `next`/`Extended`.
            fn keyedMounts(
                dephub: anytype,
                comptime category: anytype,
                allocator: std.mem.Allocator,
                comptime Config: type,
                comptime i: usize,
            ) KeyedMounts(category, Config, @TypeOf(dephub), i) {
                if (comptime i >= docs.drivers.len) return dephub;
                const d = docs.drivers[i];
                if (comptime !std.mem.eql(u8, d.kind, "http") or std.mem.eql(u8, d.key, "private"))
                    return keyedMounts(dephub, category, allocator, Config, i + 1);
                return keyedMounts(
                    dephub.with(category, kwd.configKeyed(d.key, http.Config, "driver." ++ d.key), allocator),
                    category,
                    allocator,
                    Config,
                    i + 1,
                );
            }

            fn KeyedMounts(comptime category: anytype, comptime Config: type, comptime DH: type, comptime i: usize) type {
                if (i >= docs.drivers.len) return DH;
                const d = docs.drivers[i];
                if (!std.mem.eql(u8, d.kind, "http") or std.mem.eql(u8, d.key, "private"))
                    return KeyedMounts(category, Config, DH, i + 1);
                const Next = kwd.configKeyed(d.key, http.Config, "driver." ++ d.key).Return(category, Config, DH);
                return KeyedMounts(category, Config, Next, i + 1);
            }
        };
    };
}
