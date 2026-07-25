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

const std = @import("std");
const version = @import("version.zig");
const bindings = @import("bindings.zig");
const docschema = @import("kw-docschema");

/// A version-neutral, in-memory description of an event-driven (AsyncAPI) API.
///
/// A driver backend (`kw-docgen--amqp`, and later mqtt/kafka) builds one of these
/// from its routes; `kw-docschema`'s reflection fills in payload schemas; a
/// version-selected emitter (`emit/<v>.zig`) renders it. Nothing here is specific
/// to a single protocol — protocol detail lives in `bindings.Bindings`.
///
/// All slices/strings are owned by the allocator passed to the backend's
/// `buildDocument` (typically an arena), so there is no per-node deinit.
pub const Document = struct {
    asyncapi_version: version.AsyncApiVersion,
    info: Info,
    channels: []const Channel,
    operations: []const Operation,
    components: Components,
};

pub const Info = struct {
    title: []const u8,
    version: []const u8,
};

pub const Bindings = bindings.Bindings;
pub const Schema = docschema.Schema;

/// An addressable point on the broker (an exchange/routing-key pair, a topic, …).
/// `messages` are the names of every message that flows over this channel, keyed
/// into `Components.messages`.
pub const Channel = struct {
    id: []const u8,
    /// The routing key / topic. `null` when the address is dynamic/unknown.
    address: ?[]const u8,
    description: ?[]const u8 = null,
    messages: []const []const u8 = &.{},
    bindings: Bindings = .{},
};

/// `send` = the application publishes; `receive` = the application consumes.
pub const Action = enum { send, receive };

pub const Operation = struct {
    id: []const u8,
    action: Action,
    /// Id of the `Channel` this operation acts on.
    channel_id: []const u8,
    summary: []const u8,
    /// From the route handler's `///` doc comment, when available.
    description: ?[]const u8 = null,
    /// Subset of the channel's messages this operation involves (by name).
    messages: []const []const u8 = &.{},
    bindings: Bindings = .{},
};

pub const Message = struct {
    name: []const u8,
    content_type: []const u8 = "application/json",
    payload: Schema,
    bindings: Bindings = .{},
};

pub const Components = struct {
    /// Message name -> message, referenced as `#/components/messages/<name>`.
    messages: std.StringArrayHashMapUnmanaged(Message) = .empty,
    /// Payload schemas, referenced as `#/components/schemas/<name>`. This is the
    /// same registry `kw-docschema`'s reflection writes into, so a backend points
    /// its `reflect.Ctx.components` straight at `&doc.components.schemas`.
    schemas: docschema.Components = .{},
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
