//! Client-side secret protocol state: the persisted identity keypair, the
//! secrets delivered so far, and the events awaiting a delivery. Lives on
//! the app Context under `secrets`.
//!
//! Apps read delivered secrets by injecting `*SecretRegistry` and polling
//! `get(identifier)`. When the secret may not have arrived yet, they can
//! register a callback instead: build an app event with a driver
//! scheduler's "later" primitive (ActionScheduler.callLater, amqp
//! publishLater), heap-allocate it with the persistent allocator (the
//! `std.mem.Allocator` DI injects), and hand it to `getOrRequest`:
//!
//! ```zig
//! const ev = try allocator.create(App.E);
//! ev.* = try action_sched.callLater(.{ ... }, .{ .inj = inj });
//! if (try reg.getOrRequest(allocator, "api/token", ev, secret_sched, .{ .inj = inj })) |secret| {
//!     allocator.destroy(ev); // cache hit: we still own the event
//!     // ... use secret now
//! }
//! // null: ev handed off; it fires when the secret arrives.
//! ```
//!
//! Ownership rule: a null return from `getOrRequest` (or a successful
//! `request`) hands the event pointer off to the registry; a non-null
//! return or an error leaves it with the caller — only the caller can
//! free it, since the registry sees `*anyopaque`. Handed-off events are
//! consumed unconditionally when the secret arrives (queued, or dropped
//! on a saturated queue, then freed). Events still pending at shutdown
//! intentionally leak: `deinit` frees only its own bookkeeping.
const SecretRegistry = @This();

const std = @import("std");
const dep = @import("kw-core").deps;
const InternalSchedulerShim = @import("kw-core").scheduler.InternalSchedulerShim;
const Scheduler = @import("secret.zig").Scheduler;
const crypto = @import("crypto.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const AnnounceState = enum {
    unannounced,
    announced,
};

state: AnnounceState = .unannounced,
/// Lazily loaded so a plain `.{}` default works in ProtocolContext.
keypair: ?Ed25519.KeyPair = null,
/// Wire forms cached alongside the keypair; valid once keypair != null.
kid_hex: [crypto.kid_hex_len]u8 = undefined,
public_key_b64: [crypto.public_key_b64_len]u8 = undefined,
/// identifier -> plaintext, both owned. Duplicate deliveries: last wins.
secrets: std.StringHashMapUnmanaged([]u8) = .empty,
/// identifier -> app events awaiting delivery. Keys are owned (duped with
/// the persistent allocator); values are type-erased heap `*E` pointers
/// owned by the pending mechanism once accepted.
pending: std.StringHashMapUnmanaged(std.ArrayList(*anyopaque)) = .empty,

/// Loads (or creates, on first ever run) the persisted identity seed and
/// caches the keypair plus its wire forms. `key_path` overrides the
/// default XDG location. A present-but-unreadable or malformed seed file
/// is an error rather than a silently minted new identity.
pub fn ensureKeys(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    key_path: ?[]const u8,
) !*const Ed25519.KeyPair {
    if (self.keypair != null) return &self.keypair.?;

    const path = if (key_path) |p|
        try allocator.dupe(u8, p)
    else
        try defaultKeyPath(allocator);
    defer allocator.free(path);

    var seed = try loadOrCreateSeed(path);
    defer std.crypto.secureZero(u8, &seed);

    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch
        return error.InvalidKeyFile;
    const kid = crypto.deriveKid(kp.public_key.bytes);

    self.keypair = kp;
    self.kid_hex = crypto.kidHex(kid);
    self.public_key_b64 = crypto.encodeKey(kp.public_key.bytes);
    return &self.keypair.?;
}

/// Stores a delivered secret, taking ownership of `plaintext`.
/// A previous value for the same identifier is zeroized and replaced.
pub fn put(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    plaintext: []u8,
) !void {
    if (self.secrets.getEntry(identifier)) |entry| {
        std.crypto.secureZero(u8, entry.value_ptr.*);
        allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = plaintext;
        return;
    }
    const key = try allocator.dupe(u8, identifier);
    errdefer allocator.free(key);
    try self.secrets.put(allocator, key, plaintext);
}

/// The app-facing read API. Null until a store has answered.
pub fn get(self: *const SecretRegistry, identifier: []const u8) ?[]const u8 {
    return self.secrets.get(identifier);
}

pub const RequestExtra = struct { inj: ?*dep.DepCtx = null };

/// Returns the cached secret, or registers `ev` to fire when it arrives.
/// Cached: the secret is returned and the caller KEEPS ownership of `ev`.
/// Not cached: `ev` is handed off to the pending map, a `secret-get` is
/// scheduled, and null is returned. On error the caller keeps ownership.
/// `identifier` must be long-lived (a literal in practice): it is duped
/// for the pending key but travels by reference through the secret-get
/// scheduler — the same contract as scheduling `secret-get` directly.
/// `scheduler` is anything whose `publish` takes `.{ .@"secret-get" =
/// .{identifier} }`: the app's concrete AMQP scheduler, or the secret
/// shim where only DI is available (protocol-internal routes).
pub fn getOrRequest(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    ev: *anyopaque,
    scheduler: anytype,
    extra: RequestExtra,
) !?[]const u8 {
    if (self.secrets.get(identifier)) |secret| return secret;
    try self.request(allocator, identifier, ev, scheduler, extra);
    return null;
}

/// Like getOrRequest but never consults the cache: always registers the
/// callback and forces a fresh request (e.g. refreshing a secret believed
/// stale). The event is mandatory — a plain fire-and-forget request is
/// already covered by scheduling `secret-get` directly.
pub fn request(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    ev: *anyopaque,
    scheduler: anytype,
    extra: RequestExtra,
) !void {
    // Pending before publish: the response must never be able to overtake
    // the callback registration.
    try self.addPending(allocator, identifier, ev);
    errdefer self.rollbackPending(allocator, identifier);
    try scheduler.publish(.{ .@"secret-get" = .{identifier} }, .{ .inj = extra.inj });
}

/// Drains every pending event for `identifier` onto the server queue via
/// the internal scheduler shim. Each pointer is consumed unconditionally
/// (copied, or warn-dropped on a full queue, then freed with `allocator`).
/// Kept separate from `put` so `put` stays a pure value store; the consume
/// route calls this after a successful put.
pub fn dispatchPending(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    scheduler: InternalSchedulerShim,
) void {
    var kv = self.pending.fetchRemove(identifier) orelse return;
    for (kv.value.items) |ptr| {
        scheduler.enqueueIndirect(ptr, .{ .allocator = allocator });
    }
    kv.value.deinit(allocator);
    allocator.free(kv.key);
}

fn addPending(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    ev: *anyopaque,
) !void {
    if (self.pending.getPtr(identifier)) |list| {
        try list.append(allocator, ev);
        return;
    }
    const key = try allocator.dupe(u8, identifier);
    errdefer allocator.free(key);
    var list: std.ArrayList(*anyopaque) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, ev);
    try self.pending.put(allocator, key, list);
}

/// Undo the most recent addPending for `identifier` (publish failed;
/// ownership of the event returns to the caller).
fn rollbackPending(
    self: *SecretRegistry,
    allocator: std.mem.Allocator,
    identifier: []const u8,
) void {
    const list = self.pending.getPtr(identifier) orelse return;
    _ = list.pop();
    if (list.items.len == 0) {
        var kv = self.pending.fetchRemove(identifier).?;
        kv.value.deinit(allocator);
        allocator.free(kv.key);
    }
}

pub fn deinit(self: *SecretRegistry, allocator: std.mem.Allocator) void {
    var it = self.secrets.iterator();
    while (it.next()) |entry| {
        std.crypto.secureZero(u8, entry.value_ptr.*);
        allocator.free(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    self.secrets.deinit(allocator);
    var pit = self.pending.iterator();
    while (pit.next()) |entry| {
        // The type-erased events cannot be freed here — only their creator
        // knows E. They intentionally leak at shutdown.
        std.log.scoped(.secret).debug(
            "Dropping {d} pending event(s) for '{s}' at shutdown (leaked).",
            .{ entry.value_ptr.items.len, entry.key_ptr.* },
        );
        entry.value_ptr.deinit(allocator);
        allocator.free(entry.key_ptr.*);
    }
    self.pending.deinit(allocator);
    self.keypair = null;
}

fn defaultKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const basename = "secret.ed25519";
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "kwatcher", basename });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.NoKeyLocation,
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "kwatcher", basename });
}

fn loadOrCreateSeed(path: []const u8) ![Ed25519.KeyPair.seed_length]u8 {
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    // Two attempts so losing a create race falls back to reading the
    // winner's seed.
    for (0..2) |_| {
        if (std.fs.cwd().openFile(path, .{})) |file| {
            defer file.close();
            const len = try file.readAll(&seed);
            var overflow: [1]u8 = undefined;
            if (len != seed.len or try file.readAll(&overflow) != 0)
                return error.InvalidKeyFile;
            return seed;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        std.crypto.random.bytes(&seed);
        const file = std.fs.cwd().createFile(path, .{
            .mode = 0o600,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close();
        try file.writeAll(&seed);
        return seed;
    }
    return error.InvalidKeyFile;
}

test "put/get replaces and owns values" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    defer reg.deinit(allocator);

    try std.testing.expect(reg.get("api/example") == null);

    try reg.put(allocator, "api/example", try allocator.dupe(u8, "first"));
    try std.testing.expectEqualStrings("first", reg.get("api/example").?);

    try reg.put(allocator, "api/example", try allocator.dupe(u8, "second"));
    try std.testing.expectEqualStrings("second", reg.get("api/example").?);

    try reg.put(allocator, "api/other", try allocator.dupe(u8, "third"));
    try std.testing.expectEqualStrings("second", reg.get("api/example").?);
    try std.testing.expectEqualStrings("third", reg.get("api/other").?);
}

test "ensureKeys creates and reloads a persisted seed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const key_path = try std.fs.path.join(allocator, &.{ dir_path, "keys", "secret.ed25519" });
    defer allocator.free(key_path);

    var first = SecretRegistry{};
    defer first.deinit(allocator);
    const kp = try first.ensureKeys(allocator, key_path);
    // Cached: same pointer on the second call.
    try std.testing.expectEqual(kp, try first.ensureKeys(allocator, key_path));

    // A second registry reloads the same identity from disk.
    var second = SecretRegistry{};
    defer second.deinit(allocator);
    _ = try second.ensureKeys(allocator, key_path);
    try std.testing.expectEqualStrings(&first.kid_hex, &second.kid_hex);
    try std.testing.expectEqualStrings(&first.public_key_b64, &second.public_key_b64);
}

const TestEvent = struct { tag: u32 };

const FakeInternal = struct {
    received: std.ArrayList(*anyopaque) = .empty,

    fn shutdownImpl(_: *anyopaque, _: InternalSchedulerShim.ShutdownExtra) anyerror!void {}

    fn enqueueIndirectImpl(
        ctx: *anyopaque,
        ptr: *anyopaque,
        extra: InternalSchedulerShim.EnqueueExtra,
    ) void {
        const self: *FakeInternal = @ptrCast(@alignCast(ctx));
        self.received.append(std.testing.allocator, ptr) catch @panic("oom");
        // Honor the "always consumes" contract.
        extra.allocator.destroy(@as(*TestEvent, @ptrCast(@alignCast(ptr))));
    }

    fn shim(self: *FakeInternal) InternalSchedulerShim {
        return .{
            ._shutdownFn = &shutdownImpl,
            ._enqueueIndirectFn = &enqueueIndirectImpl,
            ._ctx = @ptrCast(self),
        };
    }

    fn deinit(self: *FakeInternal) void {
        self.received.deinit(std.testing.allocator);
    }
};

const FakeSecretSched = struct {
    published: usize = 0,
    last_identifier: ?[]const u8 = null,

    fn publishImpl(
        ctx: *anyopaque,
        data: Scheduler.PublishData,
        _: Scheduler.PublishExtra,
    ) anyerror!void {
        const self: *FakeSecretSched = @ptrCast(@alignCast(ctx));
        switch (data) {
            .@"secret-get" => |req| {
                self.published += 1;
                self.last_identifier = req[0];
            },
            else => {},
        }
    }

    fn shim(self: *FakeSecretSched) Scheduler {
        return .{ ._publishFn = &publishImpl, ._ctx = @ptrCast(self) };
    }
};

test "getOrRequest returns a cached secret without consuming the event" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    defer reg.deinit(allocator);
    var sched = FakeSecretSched{};

    try reg.put(allocator, "api/example", try allocator.dupe(u8, "hunter2"));

    const ev = try allocator.create(TestEvent);
    defer allocator.destroy(ev); // non-null return: we still own it
    ev.* = .{ .tag = 1 };

    const secret = try reg.getOrRequest(allocator, "api/example", @ptrCast(ev), sched.shim(), .{});
    try std.testing.expectEqualStrings("hunter2", secret.?);
    try std.testing.expectEqual(@as(usize, 0), sched.published);
    try std.testing.expectEqual(@as(usize, 0), reg.pending.count());
}

test "getOrRequest miss stores the event, schedules secret-get, and drains on delivery" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    defer reg.deinit(allocator);
    var sched = FakeSecretSched{};
    var internal = FakeInternal{};
    defer internal.deinit();

    const ev = try allocator.create(TestEvent);
    ev.* = .{ .tag = 7 };

    const miss = try reg.getOrRequest(allocator, "api/example", @ptrCast(ev), sched.shim(), .{});
    try std.testing.expectEqual(@as(?[]const u8, null), miss);
    try std.testing.expectEqual(@as(usize, 1), sched.published);
    try std.testing.expectEqualStrings("api/example", sched.last_identifier.?);
    try std.testing.expectEqual(@as(usize, 1), reg.pending.count());

    try reg.put(allocator, "api/example", try allocator.dupe(u8, "hunter2"));
    reg.dispatchPending(allocator, "api/example", internal.shim());

    try std.testing.expectEqual(@as(usize, 1), internal.received.items.len);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(ev)), internal.received.items[0]);
    try std.testing.expectEqual(@as(usize, 0), reg.pending.count());
}

test "request always schedules even when cached" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    defer reg.deinit(allocator);
    var sched = FakeSecretSched{};
    var internal = FakeInternal{};
    defer internal.deinit();

    try reg.put(allocator, "api/example", try allocator.dupe(u8, "stale"));

    const ev = try allocator.create(TestEvent);
    ev.* = .{ .tag = 9 };
    try reg.request(allocator, "api/example", @ptrCast(ev), sched.shim(), .{});
    try std.testing.expectEqual(@as(usize, 1), sched.published);

    reg.dispatchPending(allocator, "api/example", internal.shim());
    try std.testing.expectEqual(@as(usize, 1), internal.received.items.len);
}

test "multiple pending events for one identifier drain together in order" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    defer reg.deinit(allocator);
    var sched = FakeSecretSched{};
    var internal = FakeInternal{};
    defer internal.deinit();

    const a = try allocator.create(TestEvent);
    a.* = .{ .tag = 1 };
    const b = try allocator.create(TestEvent);
    b.* = .{ .tag = 2 };

    _ = try reg.getOrRequest(allocator, "api/example", @ptrCast(a), sched.shim(), .{});
    _ = try reg.getOrRequest(allocator, "api/example", @ptrCast(b), sched.shim(), .{});
    try std.testing.expectEqual(@as(usize, 2), sched.published);

    // Unknown identifier: no-op.
    reg.dispatchPending(allocator, "api/other", internal.shim());
    try std.testing.expectEqual(@as(usize, 0), internal.received.items.len);

    reg.dispatchPending(allocator, "api/example", internal.shim());
    try std.testing.expectEqual(@as(usize, 2), internal.received.items.len);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(a)), internal.received.items[0]);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(b)), internal.received.items[1]);
}

test "deinit releases pending bookkeeping; events intentionally leak" {
    const allocator = std.testing.allocator;
    var reg = SecretRegistry{};
    var sched = FakeSecretSched{};

    const ev = try allocator.create(TestEvent);
    ev.* = .{ .tag = 3 };
    _ = try reg.getOrRequest(allocator, "api/example", @ptrCast(ev), sched.shim(), .{});

    reg.deinit(allocator);
    // deinit freed only its keys/lists; the event is ours to free — do so
    // to keep the testing allocator's leak check clean.
    allocator.destroy(ev);
}

test "ensureKeys rejects a malformed seed file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "secret.ed25519", .data = "too short" });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const key_path = try std.fs.path.join(allocator, &.{ dir_path, "secret.ed25519" });
    defer allocator.free(key_path);

    var reg = SecretRegistry{};
    defer reg.deinit(allocator);
    try std.testing.expectError(error.InvalidKeyFile, reg.ensureKeys(allocator, key_path));
}
