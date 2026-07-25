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

/// Protocol-specific bindings attached to a channel, operation, or message.
///
/// AsyncAPI bindings are per-protocol, so each protocol gets its own optional,
/// typed field. A future MQTT or Kafka driver adds a sibling (`mqtt: ?Mqtt`) and
/// fills it in its own extractor — existing protocols and emitters are untouched.
pub const Bindings = struct {
    amqp: ?Amqp = null,

    pub fn isEmpty(self: Bindings) bool {
        return self.amqp == null;
    }
};

pub const ExchangeType = enum { topic, direct, fanout, default, headers };

pub const Exchange = struct {
    name: []const u8,
    type: ExchangeType = .direct,
    durable: bool = true,
    auto_delete: bool = false,
    vhost: []const u8 = "/",
};

pub const Queue = struct {
    name: []const u8,
    durable: bool = true,
    exclusive: bool = false,
    auto_delete: bool = false,
    vhost: []const u8 = "/",
};

/// What an AMQP channel represents — a routing key on an exchange, or a queue.
pub const ChannelIs = enum { routingKey, queue };

/// AMQP 0-9-1 bindings (bindingVersion `0.3.0`). Today only the channel-scoped
/// subset (`is` + `exchange`/`queue`) is populated; operation- and message-scoped
/// fields can be added later without reshaping the model.
pub const Amqp = struct {
    is: ?ChannelIs = null,
    exchange: ?Exchange = null,
    queue: ?Queue = null,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
