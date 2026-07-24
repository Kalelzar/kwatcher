pub const schema = @import("kw-secret-schema").kwatcher.protocol.secret;
pub const route = @import("route.zig");
pub const timers = @import("timers.zig");
pub const registry = @import("registry.zig");
pub const crypto = @import("crypto.zig");
pub const deps = @import("deps.zig");
pub const Config = @import("config.zig");

const amqp = @import("kw-amqp");
const cron = @import("kw-cron");
const client_registry = @import("../../client-registration/registry.zig");

/// Minimal context with just the fields our route templates reference.
/// The response route `secret.v0.{client.id}` resolves `client.id` against
/// the client-registration registry, so apps using the secret protocol
/// must also carry the client registration context field — in practice,
/// use both protocols.
pub const ProtocolContext = struct {
    client: client_registry = .{ .assigned_id = null, .state = .unregistered },
    secrets: registry = .{},
};

/// Protocol routes parsed with our minimal context — enough for template
/// resolution without needing the consumer's full Context.
const protocol_routes = amqp.From(route, ProtocolContext);

/// Type-erased scheduler built from only this protocol's publish routes.
/// Protocol route handlers can inject this type via DI.
pub const Scheduler = amqp.AmqpSchedulerShim(protocol_routes);

pub const SupportedKinds = enum {
    amqp,
    cron,
};

pub fn supports(comptime kind: SupportedKinds) bool {
    return comptime kind == .amqp or kind == .cron;
}

pub fn forKind(comptime Context: type, comptime kind: SupportedKinds) []const type {
    switch (kind) {
        .amqp => return amqp.From(route, Context),
        .cron => return cron.From(timers),
    }
}

test "secret.get v0 wire shape" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const msg = schema.Secret.Get.V0{
        .scheme = "kw.sealed-box.v0",
        .kid = "abc123",
        .secret_identifier = "api/example",
        .client = .{ .id = "client-1", .version = "1.0.0", .name = "example" },
    };

    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    var json = std.json.fmt(msg, .{});
    try json.format(&allocating.writer);
    const body = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_name\":\"secret.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_version\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret_identifier\":\"api/example\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"kid\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_name\":\"client\"") != null);
}
