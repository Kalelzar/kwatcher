const std = @import("std");
const log = std.log.scoped(.secret);
const dep = @import("kw-core").deps;

const base_schema = @import("kw-core").schema;

const Config = @import("config.zig");
const InternFmtCache = @import("kw-core").InternFmtCache;
const crypto = @import("crypto.zig");
const schema = @import("schema.zig");
const SecretRegistry = @import("registry.zig");
const ClientRegistry = @import("../../client-registration/registry.zig");

/// Broadcasts our public key to any listening secret store.
/// Fire-and-forget: v0 has no acknowledgement. Registration is idempotent
/// (stores upsert on kid), so re-broadcasts are harmless and expected.
pub fn @"publish!:secret-register amq.topic/secret.registration"(
    client_info: base_schema.ClientInfo,
    allocator: std.mem.Allocator,
    reg: *SecretRegistry,
    creg: *ClientRegistry,
    config: *Config,
) !base_schema.Message(schema.Secret.Register.V0) {
    _ = try reg.ensureKeys(allocator, config.key_path);
    reg.state = .announced;

    log.info(
        "Registering key '{s}' for client [{s}:{s}] with any listening secret store.",
        .{ reg.kid_hex, client_info.name, client_info.version },
    );

    return .{
        .schema = .{
            .scheme = crypto.scheme_v0,
            .public_key = &reg.public_key_b64,
            .kid = &reg.kid_hex,
            .client = .{
                .id = creg.id(client_info),
                .name = client_info.name,
                .version = client_info.version,
            },
        },
        .options = .{
            .expiration = config.register_message_expiration,
        },
    };
}

/// Requests a secret by identifier from any store willing to answer.
/// The response arrives sealed on amq.topic/secret.v0.{client.id} — the
/// route named by this message's reply_to property; silence is the only
/// negative signal. Lazily broadcasts a registration first if we have not
/// announced yet this run.
/// The identifier travels through the scheduler by reference — callers
/// should pass string literals or otherwise long-lived slices.
pub fn @"publish!:secret-get amq.topic/secret.request"(
    request: struct { []const u8 },
    client_info: base_schema.ClientInfo,
    allocator: std.mem.Allocator,
    strings: *InternFmtCache,
    reg: *SecretRegistry,
    creg: *ClientRegistry,
    config: *Config,
    inj: *dep.DepCtx,
) !base_schema.Message(schema.Secret.Get.V0) {
    const secret_identifier = request[0];
    _ = try reg.ensureKeys(allocator, config.key_path);

    if (reg.state == .unannounced) {
        const scheduler = try inj.require(@import("secret.zig").Scheduler);
        try scheduler.publish(.{ .@"secret-register" = .{} }, .{ .inj = inj });
    }

    const id = creg.id(client_info);
    const reply_to = try strings.internFmt("secret_response_route", "secret.v0.{s}", .{id});

    log.info("Requesting secret '{s}' for key '{s}'.", .{ secret_identifier, reg.kid_hex });

    return .{
        .schema = .{
            .scheme = crypto.scheme_v0,
            .kid = &reg.kid_hex,
            .secret_identifier = secret_identifier,
            .client = .{
                .id = id,
                .name = client_info.name,
                .version = client_info.version,
            },
        },
        .options = .{
            .reply_to = reply_to,
            .expiration = config.request_message_expiration,
        },
    };
}

/// Receives a sealed secret from a store. The envelope is verified
/// (scheme, kid) and the sealed box authenticated before the plaintext is
/// stored in the SecretRegistry. Anything that does not check out is
/// dropped, not errored: in v0 any AMQP principal can answer a request,
/// so a bad envelope proves nothing beyond "not for us / not authentic".
pub fn @"consume:secret-response amq.topic/secret.v0.{client.id}"(
    res: schema.Secret.Response.V0,
    allocator: std.mem.Allocator,
    reg: *SecretRegistry,
    config: *Config,
    inj: *dep.DepCtx,
) !void {
    const keypair = try reg.ensureKeys(allocator, config.key_path);

    if (!std.mem.eql(u8, res.scheme, crypto.scheme_v0)) {
        log.warn("Dropping secret '{s}': unknown scheme '{s}'.", .{ res.secret_identifier, res.scheme });
        return;
    }
    if (!std.mem.eql(u8, res.kid, &reg.kid_hex)) {
        log.warn("Dropping secret '{s}': foreign kid '{s}'.", .{ res.secret_identifier, res.kid });
        return;
    }
    const eph = crypto.decodeKey(res.ephemeral_public_key) catch {
        log.warn("Dropping secret '{s}': malformed ephemeral key.", .{res.secret_identifier});
        return;
    };

    const ct_len = std.base64.standard.Decoder.calcSizeForSlice(res.ciphertext) catch {
        log.warn("Dropping secret '{s}': malformed ciphertext.", .{res.secret_identifier});
        return;
    };
    const ciphertext = try allocator.alloc(u8, ct_len);
    defer allocator.free(ciphertext);
    std.base64.standard.Decoder.decode(ciphertext, res.ciphertext) catch {
        log.warn("Dropping secret '{s}': malformed ciphertext.", .{res.secret_identifier});
        return;
    };

    const aad = try crypto.buildAad(allocator, &reg.kid_hex, res.secret_identifier);
    defer allocator.free(aad);

    const plaintext = crypto.open(allocator, eph, ciphertext, keypair.*, aad) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn(
                "Dropping secret '{s}' from [{s}:{s}]: seal did not verify.",
                .{ res.secret_identifier, res.store.name, res.store.version },
            );
            return;
        },
    };
    errdefer allocator.free(plaintext);

    try reg.put(allocator, res.secret_identifier, plaintext);
    log.info(
        "Received secret '{s}' from [{s}:{s}].",
        .{ res.secret_identifier, res.store.name, res.store.version },
    );

    // Drain strictly after put, so a drained handler that immediately
    // calls getOrRequest hits the cache.
    const internal = try inj.require(@import("kw-core").scheduler.InternalSchedulerShim);
    reg.dispatchPending(allocator, res.secret_identifier, internal);
}

/// Responds to a store-initiated registration request (e.g. a store that
/// restarted and lost its key map) by re-broadcasting our registration on
/// the canonical route.
pub fn @"consume:secret-reannounce amq.topic/secret.registration.request"(
    _: schema.Secret.Reannounce.Request.V0,
    inj: *dep.DepCtx,
) !void {
    const scheduler = try inj.require(@import("secret.zig").Scheduler);
    try scheduler.publish(.{ .@"secret-register" = .{} }, .{ .inj = inj });
}

/// Receives back a registration that wasn't able to be routed.
/// This means no secret store is listening; the periodic re-broadcast
/// will reach one once it appears. Nothing to do but say so.
pub fn @"unrouted:secret-register"(body: schema.Secret.Register.V0) !void {
    log.warn("No secret store is listening for registrations (kid '{s}').", .{body.kid});
}

/// Receives back a secret request that wasn't able to be routed.
/// This means no secret store is listening at all — a stronger signal
/// than silence, which could still mean "denied". The request is lost;
/// retrying is the caller's business.
pub fn @"unrouted:secret-get"(body: schema.Secret.Get.V0) !void {
    log.warn("No secret store is listening; request for '{s}' was dropped.", .{body.secret_identifier});
}
