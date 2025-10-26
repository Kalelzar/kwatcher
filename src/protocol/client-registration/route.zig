const std = @import("std");
const log = std.log.scoped(.client);

const BaseConfig = @import("../../utils/config.zig").BaseConfig;
const InternFmtCache = @import("../../utils/intern_fmt_cache.zig");

const Client = @import("../../client/client.zig");

const base_schema = @import("../../schema.zig");

const schema = @import("schema.zig");
const ClientRegistry = @import("registry.zig");

pub fn @"publish!:announce amq.direct/client.announce"(
    user_info: base_schema.UserInfo,
    client_info: base_schema.ClientInfo,
    strings: *InternFmtCache,
    config: BaseConfig,
    reg: *ClientRegistry,
) !base_schema.Message(schema.Client.Announce.V1) {
    reg.state = .announcing;

    const reply_to = try strings.internFmt(
        "client_ack_id",
        "client.ack.{s}",
        .{client_info.id},
    );

    log.info(
        "Announcing client [{s}:{s}:{s}] to registry.",
        .{ client_info.name, client_info.version, client_info.id },
    );

    return .{
        .schema = .{
            .id = client_info.id,
            .client = client_info.v1(),
            .host = user_info.hostname,
        },
        .options = .{
            .reply_to = reply_to,
            .expiration = std.time.ms_per_min * config.protocol.client.announce_message_expiration,
        },
    };
}

pub fn @"consume amq.direct/client.ack.{client.id}"(
    ack: schema.Client.Ack.V1,
    arena: *std.heap.ArenaAllocator,
    reg: *ClientRegistry,
    client_info: base_schema.ClientInfo,
) !void {
    const alloc = arena.allocator();
    reg.assigned_id = try alloc.dupe(u8, ack.id);
    reg.state = .registered;
    log.info(
        "Client [{s}:{s}] was assigned id '{s}' by [{s}:{s}].",
        .{
            client_info.name,
            client_info.version,
            ack.id,
            ack.client.name,
            ack.client.version,
        },
    );
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

    // TODO: Include registry client in the client.reannounce.request
    log.info(
        "Reannouncing client [{s}:{s}:{s}] to registry.",
        .{ client_info.name, client_info.version, client_info.id },
    );

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

pub fn @"publish!:heartbeat amq.direct/client.heartbeat"(client_info: base_schema.ClientInfo) schema.Client.Heartbeat.V1 {
    log.debug("Heartbeat", .{});
    return .{ .id = client_info.id };
}
