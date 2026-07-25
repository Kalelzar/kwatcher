//! `kw-introspect--sqlite` — the sqlite introspection backend.
//!
//! A plugin for `kw-introspect`'s `Assemble`: it declares the driver kind it documents, an
//! embedded default icon for that kind, and a `generate` that returns the sqlite
//! queries/tables/console/migrations routes (already template-wrapped).

const routes = @import("routes.zig");

/// The driver kind this backend documents.
pub const introspected_kind: []const u8 = "sqlite";

/// Embedded default icon for the sqlite kind (consumer `static/icons/sqlite/<key>.svg` overrides).
pub const icon: []const u8 = @embedFile("assets/sqlite.svg");

/// Kind-level route generator
pub const generate = routes.generate;
