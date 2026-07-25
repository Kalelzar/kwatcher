// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

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
