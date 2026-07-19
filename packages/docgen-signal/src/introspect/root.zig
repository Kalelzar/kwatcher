//! `kw-introspect--signal` — the signal introspection backend.
//!
//! A plugin for `kw-introspect`'s `Assemble`: it declares the driver kind it documents, an
//! embedded default icon for that kind, and a `generate` that returns the signal list
//! routes (already template-wrapped).

const routes = @import("routes.zig");

/// The driver kind this backend documents.
pub const introspected_kind: []const u8 = "signal";

/// Embedded default icon for the signal kind (consumer `static/icons/signal/<key>.svg` overrides).
pub const icon: []const u8 = @embedFile("assets/signal.svg");

/// Kind-level route generator
pub const generate = routes.generate;
