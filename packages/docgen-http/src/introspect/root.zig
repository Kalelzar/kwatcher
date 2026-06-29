//! `kw-introspect--http` — the HTTP introspection backend.
//!
//! A plugin for `kw-introspect`'s `Assemble`: it declares the driver kind it documents, an
//! embedded default icon for that kind, and a `generate` that returns the HTTP operation
//! browser routes (already template-wrapped).

const routes = @import("routes.zig");

/// The driver kind this backend documents.
pub const introspected_kind: []const u8 = "http";

/// Embedded default icon for the http kind (consumer `static/icons/http/<key>.svg` overrides).
pub const icon: []const u8 = @embedFile("assets/http.svg");

/// Kind-level route generator
pub const generate = routes.generate;
