//! `kw-asyncapi` — a reusable, protocol-agnostic AsyncAPI core.
//!
//! It owns the neutral channel/operation/message model, the version enum, the
//! per-protocol bindings, and the version-selected emitters. Driver backends
//! (`kw-docgen--amqp` today, mqtt/kafka later) build a `Document` from their routes
//! and call `serialize`; the payload schemas come from the shared `kw-docschema`
//! kernel. Nothing here is tied to a single broker protocol — that lives in
//! `bindings`.
const std = @import("std");

pub const model = @import("model.zig");
pub const bindings = @import("bindings.zig");
pub const version = @import("version.zig");
const asyncapi = @import("asyncapi.zig");

pub const Document = model.Document;
pub const Info = model.Info;
pub const Channel = model.Channel;
pub const Operation = model.Operation;
pub const Message = model.Message;
pub const Components = model.Components;
pub const Action = model.Action;
pub const Bindings = bindings.Bindings;

pub const AsyncApiVersion = version.AsyncApiVersion;
pub const parseVersion = version.parse;

/// Serialize a neutral `Document` to its selected AsyncAPI version.
pub const serialize = asyncapi.serialize;

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    _ = model;
    _ = bindings;
    _ = version;
    _ = asyncapi;
    _ = @import("emit/v3_0_0.zig");
}
