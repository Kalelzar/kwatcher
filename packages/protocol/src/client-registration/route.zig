const std = @import("std");
const log = std.log.scoped(.client);
const metrics = @import("kw-core").metrics;
const dep = @import("kw-core").deps;

const Config = @import("config.zig");
const InternFmtCache = @import("kw-core").InternFmtCache;

const Client = @import("kw-amqp").Client;

const base_schema = @import("kw-core").schema;

const schema = @import("schema.zig");
const ClientRegistry = @import("registry.zig");

/// Publish an announcement to a client registry.
/// This message expects a response on client.ack.{client_info.id} over the same exchange.
/// This either uses a temporary id just for this ack or, if already announced previously,
/// The same client_id we were issued last time.
/// The announcement has an expiration in case no registry can pick it up.
pub fn @"publish!:client-announce amq.direct/client.announce"(
    user_info: *base_schema.UserInfo,
    client_info: base_schema.ClientInfo,
    strings: *InternFmtCache,
    config: *Config,
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
            .expiration = std.time.ms_per_min * config.announce_message_expiration,
        },
    };
}

/// Recieves an acknowedgement from a client registry.
/// Dynamically bound to the current client id.
/// This overwrites the previously assigned id.
pub fn @"consume:client-ack amq.direct/client.ack.{client.id}"(
    ack: schema.Client.Ack.V1,
    allocator: std.mem.Allocator,
    reg: *ClientRegistry,
    client_info: base_schema.ClientInfo,
) !void {
    if (reg.assigned_id) |existing| {
        allocator.free(existing);
    }
    reg.assigned_id = try allocator.dupe(u8, ack.id);
    reg.state = .registered;
    metrics.setClientId(reg.assigned_id.?);
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

/// Responds to a reannoucement request from a client registry.
/// This message expects a response on client.ack.{client_info.id} over the same exchange.
/// This either uses a temporary id just for this ack or, if already announced previously,
/// The same client_id we were issued last time.
/// The announcement has an expiration in case no registry can pick it up.
/// Functionally equivalent to @consume:client-announce
pub fn @"reply:client-reannounce amq.topic/client.requests.reannounce"(
    req: schema.Client.Reannounce.Request.V1,
    user_info: *base_schema.UserInfo,
    client_info: base_schema.ClientInfo,
    strings: *InternFmtCache,
    config: *Config,
    reg: *ClientRegistry,
) !base_schema.Message(schema.Client.Announce.V1) {
    _ = req;
    reg.state = .announcing;

    const id = reg.id(client_info);
    const reply_to = try strings.internFmt("client_ack_id", "client.ack.{s}", .{id});

    // TODO: Include registry client in the client.reannounce.request
    log.info(
        "Reannouncing client [{s}:{s}:{s}] to registry.",
        .{ client_info.name, client_info.version, client_info.id },
    );

    return .{
        .schema = .{
            .client = client_info.v1(),
            .host = user_info.hostname,
            .id = id,
        },
        .options = .{
            .reply_to = reply_to,
            .expiration = std.time.ms_per_min * config.announce_message_expiration,
        },
    };
}

/// Publishes a liveliness heartbeat to a registry.
/// This message expires in 15s so as to not clog the broker with stale data.
pub fn @"publish!:client-heartbeat amq.direct/client.heartbeat"(
    client_info: base_schema.ClientInfo,
    reg: *ClientRegistry,
    inj: *dep.DepCtx,
) !?base_schema.Message(schema.Client.Heartbeat.V1) {
    if (reg.state != .registered) {
        const scheduler = try inj.require(@import("client_registration.zig").Scheduler);
        try scheduler.publish(.{ .@"client-announce" = .{} }, .{ .inj = inj });
        return null;
    }
    return .{
        .schema = .{ .id = client_info.id },
        .options = .{
            .expiration = std.time.ms_per_s * 15,
        },
    };
}

// pub fn @"rejected:client-heartbeat"(body: schema.Client.Heartbeat.V1) !void {
//     _ = body;
// }

/// Reads a heartbeat that expired and was dead-lettered.
/// Publishes a new annoucement in case we aren't known to any living registry.
pub fn @"consume:client-heartbeat-dead kw.grave/client.heartbeat"(
    _: schema.Client.Heartbeat.V1,
    inj: *dep.DepCtx,
) !void {
    const scheduler = try inj.require(@import("client_registration.zig").Scheduler);
    try scheduler.publish(.{ .@"client-announce" = .{} }, .{ .inj = inj });
}

/// Recieves back a client heartbeat that wasn't able to be routed.
/// This typically means that there is no living client registry.
/// There is nothing we can do here.
pub fn @"unrouted:client-heartbeat"(body: schema.Client.Heartbeat.V1) !void {
    _ = body;
    std.log.info("Couldn't route heartbeat", .{});
}
