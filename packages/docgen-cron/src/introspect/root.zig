//! `kw-introspect--cron` — the cron introspection backend.
//!
//! A plugin for `kw-introspect`'s `Assemble`: it declares the driver kind it documents, an
//! embedded default icon for that kind, and a `generate` that returns the static job list
//! routes (already template-wrapped).

const routes = @import("routes.zig");

/// The driver kind this backend documents.
pub const introspected_kind: []const u8 = "cron";

/// Embedded default icon for the cron kind (consumer `static/icons/cron/<key>.svg` overrides).
pub const icon: []const u8 = @embedFile("assets/cron.svg");

/// Kind-level route generator
pub const generate = routes.generate;
