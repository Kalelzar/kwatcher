//! Kind-agnostic assembly of introspection routes from a set of backend plugins.
//!
//! No code here names any driver kind. Each backend's `generate`/`generateFor` returns an
//! anonymous struct whose FIELD NAMES are the driver kinds its routes target; we flatten
//! those into a kind-keyed `Entry` list (discovering names via `std.meta.fields`), then build
//! a result struct from the union of kinds seen — all by reflection. The framework never
//! enumerates a fixed kind universe, so arbitrary third-party drivers compose for free.
//!
//! The generated `kw-gen--docs` manifest is threaded in as the comptime `Docs` parameter
//! rather than `@import`ed, so these modules carry no static edge to docgen's own output —
//! that would form a build cycle through the host-target docgen entrypoint. The consumer
//! (which already imports `kw-gen--docs`, overridable to a dummy at docgen time) supplies it.

const std = @import("std");
const routes = @import("routes.zig");

/// One kind-keyed bundle of routes. `kind` is the driver kind that serves these routes; it
/// is `[:0]const u8` because it becomes a struct field name in `Build`.
pub const Entry = struct { kind: [:0]const u8, routes: []const type };

/// Flatten a generator-result struct into `entries`, one `Entry` per field (field name =
/// target driver kind). `entries` stays `[]const Entry` — type-stable across the fold.
pub fn collect(comptime entries: []const Entry, comptime g: anytype) []const Entry {
    comptime {
        var out = entries;
        for (std.meta.fields(@TypeOf(g))) |f|
            out = out ++ &[_]Entry{.{ .kind = f.name, .routes = @field(g, f.name) }};
        return out;
    }
}

/// A struct type whose fields are exactly the distinct kinds in `entries`, each a
/// `[]const type` defaulting to `&.{}`. Built with `@Type`, never an enumerated literal.
pub fn Build(comptime entries: []const Entry) type {
    comptime {
        var names: []const [:0]const u8 = &.{};
        outer: for (entries) |e| {
            for (names) |n| if (std.mem.eql(u8, n, e.kind)) continue :outer;
            names = names ++ &[_][:0]const u8{e.kind};
        }

        const empty: []const type = &.{};
        var fields: [names.len]std.builtin.Type.StructField = undefined;
        for (names, 0..) |n, i| {
            fields[i] = .{
                .name = n,
                .type = []const type,
                .default_value_ptr = @ptrCast(&empty),
                .is_comptime = false,
                .alignment = @alignOf([]const type),
            };
        }

        return @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }
}

/// Fold `entries` into the `Build` struct, concatenating routes that share a kind.
pub fn build(comptime entries: []const Entry) Build(entries) {
    comptime {
        var out: Build(entries) = .{};
        for (entries) |e|
            @field(out, e.kind) = @field(out, e.kind) ++ e.routes;
        return out;
    }
}

/// The distinct driver kinds present in the manifest — the set generation is keyed on, so a
/// backend's kind-level routes are produced once no matter how many driver instances share a
/// kind. Discovered from `Docs.drivers`, never a hardcoded list.
fn uniqueKinds(comptime Docs: type) []const []const u8 {
    comptime {
        var kinds: []const []const u8 = &.{};
        outer: for (Docs.drivers) |d| {
            for (kinds) |k| if (std.mem.eql(u8, k, d.kind)) continue :outer;
            kinds = kinds ++ &[_][]const u8{d.kind};
        }
        return kinds;
    }
}

/// Backend-contributed entries only (no core routes) — the slice the
/// opinionated mount wraps in auth wholesale.
fn backendEntriesOf(comptime Docs: type, comptime backends: anytype) []const Entry {
    var entries: []const Entry = &.{};

    // Kind-level: once per UNIQUE introspected kind present in the manifest.
    inline for (uniqueKinds(Docs)) |kind| {
        inline for (backends) |m| {
            if (comptime std.mem.eql(u8, m.introspected_kind, kind))
                entries = collect(entries, m.generate(Docs));
        }
    }

    // Driver-level: per instance (no backend implements `generateFor` yet).
    inline for (Docs.drivers) |d| {
        inline for (backends) |m| {
            if (comptime std.mem.eql(u8, m.introspected_kind, d.kind) and @hasDecl(m, "generateFor"))
                entries = collect(entries, m.generateFor(Docs, d));
        }
    }

    return entries;
}

fn entriesOf(comptime Docs: type, comptime backends: anytype) []const Entry {
    return collect(&.{}, routes.coreRoutes(Docs, backends)) ++ backendEntriesOf(Docs, backends);
}

const AccessFn = *const fn (@Type(.enum_literal)) []const type;

pub fn Assembly(comptime g: anytype) AccessFn {
    const Cache = struct {
        /// Read a kind's routes off an assembled result; `&.{}` when that kind received none — so a
        /// consumer never has to name a kind that no backend contributed to.
        pub fn get(comptime kind: @Type(.enum_literal)) []const type {
            return if (@hasField(@TypeOf(g), @tagName(kind))) @field(g, @tagName(kind)) else &.{};
        }
    };
    return &Cache.get;
}

/// Assemble every backend's introspection routes into a kind-keyed accessor.
///
/// @param `Docs` is the generated manifest module (`@import("kw-gen--docs")` in the consumer);
/// @param `backends` is a tuple of backend modules, each declaring its own `introspected_kind`/`generate`.
pub fn Assemble(
    comptime Docs: type,
    comptime backends: anytype,
) AccessFn {
    if (comptime Docs.isDocgen) return noopAccess;
    return Assembly(build(entriesOf(Docs, backends)));
}

/// Assemble ONLY the backend-contributed routes (no core chrome). Used by the
/// opinionated mount to compose `open_core ++ wrap(inner_core ++ backends)`.
pub fn AssembleBackends(
    comptime Docs: type,
    comptime backends: anytype,
) AccessFn {
    if (comptime Docs.isDocgen) return noopAccess;
    return Assembly(build(backendEntriesOf(Docs, backends)));
}

fn noopAccess(comptime _: @Type(.enum_literal)) []const type {
    return &.{};
}
