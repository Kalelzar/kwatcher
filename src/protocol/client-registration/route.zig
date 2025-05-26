const std = @import("std");
const BaseConfig = @import("../../config.zig").BaseConfig;
const Client = @import("../../client.zig");

const base_schema = @import("../../schema.zig");
const InternFmtCache = @import("../../intern_fmt_cache.zig");
const schema = @import("schema.zig");
const ClientRegistry = @import("registry.zig");

pub fn @"publish:announce amq.direct/client.announce"(
    user_info: base_schema.UserInfo,
    client_info: base_schema.ClientInfo,
    strings: *InternFmtCache,
    config: BaseConfig,
    reg: *ClientRegistry,
    client: Client,
) !base_schema.Message(schema.Client.Announce.V1) {
    reg.state = .announcing;

    const reply_to = try strings.internFmt("client_ack_id", "client.ack.{s}", .{client.id()});

    return .{
        .schema = .{
            .id = client.id(),
            .client = client_info.v1(),
            .host = user_info.hostname,
        },
        .options = .{
            .reply_to = reply_to,
            .expiration = std.time.ms_per_min * config.protocol.client.announce_message_expiration,
        },
    };
}

pub fn @"consume amq.direct/client.ack.{client.id}/client.ack"(
    ack: schema.Client.Ack.V1,
    arena: *std.heap.ArenaAllocator,
    reg: *ClientRegistry,
) !void {
    const alloc = arena.allocator();
    reg.assigned_id = try alloc.dupe(u8, ack.id);
    reg.state = .registered;
}

pub fn @"reply amq.topic/client.requests.reannounce"(
    req: schema.Client.Reannounce.Request.V1,
    user_info: base_schema.UserInfo,
    client_info: base_schema.ClientInfo,
    strings: *InternFmtCache,
    config: BaseConfig,
    reg: *ClientRegistry,
    client: Client,
) !base_schema.Message(schema.Client.Announce.V1) {
    _ = req;
    reg.state = .announcing;

    const reply_to = try strings.internFmt("client_ack_id", "client.ack.{s}", .{reg.id(client)});

    return .{
        .schema = .{
            .client = client_info.v1(),
            .host = user_info.hostname,
            .id = reg.id(client),
        },
        .options = .{
            .reply_to = reply_to,
            .expiration = std.time.ms_per_min * config.protocol.client.announce_message_expiration,
        },
    };
}

pub fn @"publish:heartbeat amq.direct/client.heartbeat"(reg: *ClientRegistry, client: Client) schema.Client.Heartbeat.V1 {
    return .{ .id = reg.id(client) };
}
