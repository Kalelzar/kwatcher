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

/// Read a kind's routes off an assembled result; `&.{}` when that kind received none — so a
/// consumer never has to name a kind that no backend contributed to.
pub fn get(comptime g: anytype, comptime kind: []const u8) []const type {
    return if (@hasField(@TypeOf(g), kind)) @field(g, kind) else &.{};
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

fn entriesOf(comptime Docs: type, comptime backends: anytype) []const Entry {
    var entries: []const Entry = collect(&.{}, routes.coreRoutes(Docs, backends));

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

/// The result type of `Assemble`: the kind-keyed `Build` struct, or — during docgen — an
/// empty struct. The `Docs.isDocgen` branch is short-circuited at comptime so the dummy
/// manifest (which has no `drivers`/`http_documents`) never reaches `entriesOf`. This keeps
/// the docgen hedge here instead of every consumer call site.
fn AssembleResult(comptime Docs: type, comptime backends: anytype) type {
    if (Docs.isDocgen) return struct {};
    return Build(entriesOf(Docs, backends));
}

/// Assemble every backend's introspection routes into one kind-keyed struct.
///
/// `Docs` is the generated manifest module (`@import("kw-gen--docs")` in the consumer);
/// `backends` is a tuple of backend modules, each declaring its own `introspected_kind`/`generate`.
/// (Routes carry no app routing context — each generator picks its own; the introspection routes
/// don't use one.) Read the result with `get(result, "<kind>")` — which yields `&.{}` for any
/// kind, so the empty docgen-time result needs no special-casing.
pub fn Assemble(
    comptime Docs: type,
    comptime backends: anytype,
) AssembleResult(Docs, backends) {
    if (comptime Docs.isDocgen) return .{};
    return build(entriesOf(Docs, backends));
}
