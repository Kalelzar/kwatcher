const std = @import("std");
const log = std.log.scoped(.replay);

const core = @import("kw-core");
const schema = core.schema;
const metrics = core.metrics;
const Reader = core.reader.Reader;

const Client = @import("../client/client.zig");
const AmqpOps = @import("ops.zig").Ops;

const OpsReader = Reader(AmqpOps);

const replay_errors = error{
    TruncatedRecording,
    InvalidRecording,
    InvalidCheckpoint,
    UnsupportedOp,
};

/// Replays every finished recording in a directory, oldest first, against
/// the given client. The caller owns the client's connection lifecycle —
/// it must arrive connected and is never connected or disconnected here
/// (it is typically a pooled client whose connection belongs to the pool).
///
/// A recording interrupted by `error.Disconnected` gets a `.checkpoint`
/// sidecar (byte offset) and is resumed on the next replay pass; corrupt
/// recordings are quarantined as `<name>.bad` so one bad file can never
/// wedge the queue. Successfully replayed recordings are deleted.
pub const ReplayManager = struct {
    replay_dir_path: []const u8,
    replay_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, replay_dir_path: []const u8, client: Client) !ReplayManager {
        try std.fs.cwd().makePath(replay_dir_path);
        var dir = try std.fs.cwd().openDir(replay_dir_path, .{ .iterate = true });
        errdefer dir.close();
        return .{
            .replay_dir = dir,
            .client = client,
            .replay_dir_path = try allocator.dupe(u8, replay_dir_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReplayManager) void {
        self.replay_dir.close();
        self.allocator.free(self.replay_dir_path);
    }

    fn nextRecording(self: *ReplayManager, skip: *const std.StringHashMapUnmanaged(void)) !?[]const u8 {
        var it = self.replay_dir.iterate();
        var oldest: ?[]const u8 = null;
        errdefer if (oldest) |o| self.allocator.free(o);
        var oldest_timestamp: ?i64 = null;
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            // Also intentionally skips `.rcd.part` (still being written),
            // `.rcd.checkpoint` sidecars, `.rcd.lock` claims, and
            // `.rcd.bad` quarantined files.
            if (!std.mem.endsWith(u8, entry.name, ".rcd")) continue;
            if (skip.contains(entry.name)) continue;

            // Names are `<unix_ts>_dcc_<hex>.rcd`; order by the timestamp.
            const stem = entry.name[0..(entry.name.len - 4)];
            const ts_end = std.mem.indexOfScalar(u8, stem, '_') orelse stem.len;
            const timestamp = std.fmt.parseInt(i64, stem[0..ts_end], 10) catch continue;

            const isOlder = if (oldest_timestamp) |ot| ot > timestamp else true;
            if (isOlder) {
                if (oldest) |o| self.allocator.free(o);
                oldest = try self.allocator.dupe(u8, entry.name);
                oldest_timestamp = timestamp;
            }
        }

        return oldest;
    }

    fn getResumePoint(self: *ReplayManager, path: []const u8) !u64 {
        const file = self.replay_dir.openFile(path, .{}) catch |e| switch (e) {
            std.fs.File.OpenError.FileNotFound => return 0,
            else => return e,
        };
        defer file.close();

        var buf: [8]u8 = undefined;
        const bytes = try file.read(&buf);
        if (bytes != 8) return error.InvalidCheckpoint;
        return std.mem.bytesToValue(u64, buf[0..]);
    }

    /// A claim older than this belongs to a crashed replayer and may be
    /// broken. Rotation bounds recording size (`recording_max_bytes`), so a
    /// healthy replay of one file never takes anywhere near this long.
    const lock_stale_ns: i128 = 5 * std.time.ns_per_min;

    /// Try to claim one recording via an atomically-created `<name>.lock`
    /// sentinel — `O_CREAT|O_EXCL` is respected on every platform and
    /// filesystem, unlike advisory flock-style locks. Returns null when
    /// another replayer holds a live claim on this file; concurrent
    /// replayers cooperate by claiming different files.
    fn claimRecording(self: *ReplayManager, lock_path: []const u8) !?std.fs.File {
        var attempt: u2 = 0;
        while (attempt < 2) : (attempt += 1) {
            const file = self.replay_dir.createFile(lock_path, .{ .exclusive = true }) catch |e| switch (e) {
                error.PathAlreadyExists => {
                    const stat = self.replay_dir.statFile(lock_path) catch |se| switch (se) {
                        // The holder released it between our create and stat.
                        error.FileNotFound => continue,
                        else => return se,
                    };
                    const age = std.time.nanoTimestamp() - stat.mtime;
                    if (age < lock_stale_ns) return null;
                    log.warn("Breaking stale claim '{s}' (age {d}s).", .{ lock_path, @divTrunc(age, std.time.ns_per_s) });
                    self.replay_dir.deleteFile(lock_path) catch |de| switch (de) {
                        error.FileNotFound => {},
                        else => return de,
                    };
                    continue;
                },
                else => return e,
            };
            return file;
        }
        return null;
    }

    /// Move a recording that can never replay out of the queue.
    fn quarantine(self: *ReplayManager, recording: []const u8, prog: []const u8) !void {
        const bad = try std.mem.concat(self.allocator, u8, &.{ recording, ".bad" });
        defer self.allocator.free(bad);
        log.warn("Quarantining corrupt recording '{s}' as '{s}'.", .{ recording, bad });
        try self.replay_dir.rename(recording, bad);
        self.replay_dir.deleteFile(prog) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn replay(self: *ReplayManager) !void {
        log.debug("Replaying from '{s}'", .{self.replay_dir_path});
        // Recordings claimed by other replayers this pass; skipped rather
        // than retried so the pass always makes progress.
        var skip: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = skip.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            skip.deinit(self.allocator);
        }
        while (try self.nextRecording(&skip)) |recording| {
            defer self.allocator.free(recording);

            const path = try std.fs.path.resolve(self.allocator, &.{ self.replay_dir_path, recording });
            defer self.allocator.free(path);

            const lock_path = try std.mem.concat(self.allocator, u8, &.{ recording, ".lock" });
            defer self.allocator.free(lock_path);
            const lock = (try self.claimRecording(lock_path)) orelse {
                log.debug("'{s}' is claimed by another replayer; moving on.", .{recording});
                try skip.put(self.allocator, try self.allocator.dupe(u8, recording), {});
                continue;
            };
            defer {
                lock.close();
                self.replay_dir.deleteFile(lock_path) catch {};
            }

            log.info("Replaying {s} from '{s}'", .{ recording, path });

            const start_time = std.time.microTimestamp();

            var player = try Player.init(self.allocator, self.client, path);
            defer player.deinit();
            const prog = try std.mem.concat(self.allocator, u8, &.{ recording, ".checkpoint" });
            defer self.allocator.free(prog);
            const resumepoint = self.getResumePoint(prog) catch |e| switch (e) {
                // A corrupt checkpoint shouldn't doom the recording:
                // drop it and replay from the top.
                error.InvalidCheckpoint => blk: {
                    log.warn("Corrupt checkpoint for '{s}'; replaying from the start.", .{recording});
                    self.replay_dir.deleteFile(prog) catch {};
                    break :blk 0;
                },
                else => return e,
            };

            if (resumepoint > 0) {
                log.info("Resuming from position: {}", .{resumepoint});
                metrics.replayResumption() catch {};
            }

            player.resumeFromCheckpoint(resumepoint) catch |e| switch (e) {
                error.Disconnected => {
                    const checkpoint = player.reader.checkpoint();
                    var file = try self.replay_dir.createFile(prog, .{});
                    defer file.close();
                    _ = try file.write(std.mem.toBytes(checkpoint)[0..]);
                    metrics.replayFailure() catch {};
                    return e;
                },
                error.TruncatedRecording,
                error.InvalidRecording,
                error.InvalidCheckpoint,
                error.UnsupportedOp,
                => {
                    log.warn("Recording '{s}' is corrupt: {t}", .{ recording, e });
                    metrics.replayFailure() catch {};
                    try self.quarantine(recording, prog);
                    continue;
                },
                else => {
                    log.err("Replay failed with: {}", .{e});
                    metrics.replayFailure() catch {};
                    return e;
                },
            };

            const end_time = std.time.microTimestamp();
            const duration = @as(u64, @intCast(end_time - start_time));
            metrics.replayDuration(duration) catch {};
            metrics.recordingReplayed() catch {};

            log.info("Replay successful. Deleting file...", .{});
            try self.replay_dir.deleteFile(recording);
            self.replay_dir.deleteFile(prog) catch |err| switch (err) {
                // It's okay if the checkpoint file didn't exist (for a perfect run)
                error.FileNotFound => {},
                else => return err,
            };
        }
        log.debug("No more recordings available... Exiting.", .{});
    }
};

pub const Player = struct {
    client: *Client,
    reader: *OpsReader,
    allocator: std.mem.Allocator,
    /// KWRC header version of the loaded recording; decides the publish
    /// record layout (v2 appends the publisher key).
    version: u8 = 0,

    string_cache: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, client: Client, path: []const u8) !Player {
        const reader_ptr = try allocator.create(OpsReader);
        errdefer allocator.destroy(reader_ptr);
        const client_ptr = try allocator.create(Client);
        errdefer allocator.destroy(client_ptr);
        reader_ptr.* = try OpsReader.init(allocator, path);
        client_ptr.* = client;

        return .{
            .client = client_ptr,
            .allocator = allocator,
            .reader = reader_ptr,
            .string_cache = .{},
        };
    }

    pub fn deinit(self: *Player) void {
        self.allocator.destroy(self.client);
        self.reader.deinit();
        self.allocator.destroy(self.reader);
        self.string_cache.deinit(self.allocator);
    }

    pub fn read(self: *Player) !void {
        try self.resumeFromCheckpoint(0);
    }

    pub fn resumeFromCheckpoint(self: *Player, checkpoint: u64) !void {
        var isResuming = self.reader.checkpoint() != checkpoint;
        const header = try self.reader.header();
        self.version = header.version;
        while (!self.reader.atEnd()) {
            const mark = self.reader.checkpoint();
            errdefer self.reader.restore(mark);
            if (mark > checkpoint and isResuming) return error.InvalidCheckpoint;
            isResuming = isResuming and mark != checkpoint;

            const op = try self.reader.op();
            switch (op) {
                .bind => try self.readBind(),
                .unbind => try self.readUnbind(),
                .publish => try self.readPublish(isResuming),
                .open_channel => try self.readOpenChannel(),
                .close_channel => try self.readCloseChannel(),
                .declare_ephemeral_queue => try self.readDeclareEphemeralQueue(),
                .declare_durable_queue => try self.readDeclareDurableQueue(),
                else => |other| {
                    log.err("Op '{s}' is not supported yet.", .{@tagName(other)});
                    return error.UnsupportedOp;
                },
            }
        }
    }

    fn link(self: *Player, key: []const u8, val: []const u8) !void {
        try self.string_cache.put(self.allocator, key, val);
    }

    fn follow(self: *Player, key: []const u8) []const u8 {
        return self.string_cache.get(key) orelse key;
    }

    fn readBind(self: *Player) !void {
        const queue_name = try self.reader.strOpt();
        const binding_key = try self.reader.str();
        const exchange = try self.reader.str();
        const channel = try self.reader.strOpt();
        const consumer_tag = try self.reader.str();

        const actual_tag = try self.client.bind(
            if (queue_name) |q| self.follow(q) else null,
            binding_key,
            exchange,
            .{
                .channel_name = channel,
            },
        );

        try self.link(consumer_tag, actual_tag);
    }

    fn readPublish(self: *Player, resuming: bool) !void {
        const channel = try self.reader.strOpt();
        const body = try self.reader.str();
        const routing_key = try self.reader.str();
        const exchange = try self.reader.str();
        const reply_to = try self.reader.strOpt();
        const correlation_id = try self.reader.strOpt();
        const expires_at = try self.reader.byteOpt(u64);
        // KWRC v2: the DurableCacheClient appends the publisher key after
        // the expiration; v1 files predate it. Mandatory to consume for v2
        // or the stream desyncs.
        const publisher_key = if (self.version >= 2) try self.reader.str() else "";
        if (!resuming) {
            const message: schema.SendMessage = .{
                .body = body,
                .options = .{
                    .routing_key = routing_key,
                    .exchange = exchange,
                    // Stays false: replay runs against a raw non-recording
                    // client; if it ever routes through the breaker instead,
                    // false degrades to benign re-recording, true would drop.
                    .norecord = false,
                    .reply_to = reply_to,
                    .correlation_id = correlation_id,
                    .expiration = expires_at,
                    .publisher_key = publisher_key,
                },
            };

            try self.client.publish(
                message,
                .{ .channel_name = channel },
            );
        }
    }

    fn readOpenChannel(self: *Player) !void {
        const channel = try self.reader.str();
        try self.client.openChannel(channel);
    }

    fn readCloseChannel(self: *Player) !void {
        const channel = try self.reader.str();
        try self.client.closeChannel(channel);
    }

    fn readDeclareEphemeralQueue(self: *Player) !void {
        const anchor = try self.reader.str();
        const queue_name = try self.client.declareEphemeralQueue();
        try self.link(anchor, queue_name);
    }

    fn readDeclareDurableQueue(self: *Player) !void {
        const queue_name = try self.reader.str();
        _ = try self.client.declareDurableQueue(queue_name);
    }

    fn readUnbind(self: *Player) !void {
        const consumer_tag = try self.reader.str();
        const channel = try self.reader.strOpt();

        const actual_tag = self.follow(consumer_tag);

        try self.client.unbind(actual_tag, .{ .channel_name = channel });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const LoggingClient = @import("../client/logging_client.zig");
const Recorder = core.recorder.Recorder;

fn writeRecording(dir: std.fs.Dir, name: []const u8, patch_version: ?u8, include_publisher_key: bool, truncate_by: usize) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var rec = try Recorder(AmqpOps).init(std.testing.allocator, &w);

    try rec.op(.open_channel);
    try rec.str("__publish");

    try rec.op(.declare_ephemeral_queue);
    try rec.str("anchor #0");

    try rec.op(.bind);
    try rec.strOpt("anchor #0");
    try rec.str("test.route");
    try rec.str("amq.direct");
    try rec.strOpt(null);
    try rec.str("anchor #1");

    try rec.op(.publish);
    try rec.strOpt(null); // channel
    try rec.str("{\"hello\":true}");
    try rec.str("test.route");
    try rec.str("amq.direct");
    try rec.strOpt(null); // reply_to
    try rec.strOpt("cafebabe"); // correlation_id
    try rec.byteOpt(u64, null); // expiration
    if (include_publisher_key) try rec.str("test-publisher");

    try rec.op(.unbind);
    try rec.str("anchor #1");
    try rec.strOpt(null);

    if (patch_version) |v| buf[4] = v;

    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(buf[0 .. w.end - truncate_by]);
}

fn runReplay(dir_path: []const u8, out: []u8) !usize {
    var w = std.Io.Writer.fixed(out);
    var logging = LoggingClient.init(&w);

    var manager = try ReplayManager.init(std.testing.allocator, dir_path, logging.client());
    defer manager.deinit();
    try manager.replay();
    return w.end;
}

test "replay round-trips a v2 recording and deletes it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try writeRecording(tmp.dir, "1000_dcc_aa.rcd", null, true, 0);

    var out: [4096]u8 = undefined;
    const n = try runReplay(dir_path, &out);
    const logged = out[0..n];

    // Publish went through with its recorded fields.
    try std.testing.expect(std.mem.indexOf(u8, logged, "publish(test.route)") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "cafebabe") != null);
    // Anchor #0 resolved to the logging client's ephemeral queue name.
    try std.testing.expect(std.mem.indexOf(u8, logged, "queue(ephemeral)") != null);
    // Anchor #1 resolved to the logging client's consumer tag on unbind.
    try std.testing.expect(std.mem.indexOf(u8, logged, "unbind(consumer_tag)") != null);

    // Consumed recordings are deleted.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("1000_dcc_aa.rcd"));
}

test "replay accepts v1 recordings without a publisher key" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try writeRecording(tmp.dir, "1000_dcc_v1.rcd", 1, false, 0);

    var out: [4096]u8 = undefined;
    const n = try runReplay(dir_path, &out);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "publish(test.route)") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("1000_dcc_v1.rcd"));
}

test "corrupt recordings are quarantined and later files still replay" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // Oldest file is truncated mid-record; the newer one is fine.
    try writeRecording(tmp.dir, "1000_dcc_bad.rcd", null, true, 7);
    try writeRecording(tmp.dir, "2000_dcc_ok.rcd", null, true, 0);

    var out: [4096]u8 = undefined;
    const n = try runReplay(dir_path, &out);

    _ = try tmp.dir.statFile("1000_dcc_bad.rcd.bad");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("1000_dcc_bad.rcd"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("2000_dcc_ok.rcd"));
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "publish(test.route)") != null);
}

test "a live claim skips the file; other files still replay" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try writeRecording(tmp.dir, "1000_dcc_claimed.rcd", null, true, 0);
    try writeRecording(tmp.dir, "2000_dcc_free.rcd", null, true, 0);
    // Another replayer holds a fresh claim on the oldest file.
    try tmp.dir.writeFile(.{ .sub_path = "1000_dcc_claimed.rcd.lock", .data = "" });

    var out: [4096]u8 = undefined;
    _ = try runReplay(dir_path, &out);

    // The claimed file was left alone; the free one was consumed.
    _ = try tmp.dir.statFile("1000_dcc_claimed.rcd");
    _ = try tmp.dir.statFile("1000_dcc_claimed.rcd.lock");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("2000_dcc_free.rcd"));
}

test "a stale claim is broken and the file replays" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try writeRecording(tmp.dir, "1000_dcc_stale.rcd", null, true, 0);
    const stale_lock = try tmp.dir.createFile("1000_dcc_stale.rcd.lock", .{});
    const past = std.time.nanoTimestamp() - 10 * std.time.ns_per_min;
    try stale_lock.updateTimes(@intCast(past), @intCast(past));
    stale_lock.close();

    var out: [4096]u8 = undefined;
    _ = try runReplay(dir_path, &out);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("1000_dcc_stale.rcd"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("1000_dcc_stale.rcd.lock"));
}

test "replay skips part, checkpoint, and bad files and orders by timestamp" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try writeRecording(tmp.dir, "50_dcc_b.rcd", null, true, 0);
    try writeRecording(tmp.dir, "9_dcc_a.rcd", null, true, 0);
    // Distractors that must never be touched.
    try tmp.dir.writeFile(.{ .sub_path = "77_dcc_c.rcd.part", .data = "garbage" });
    try tmp.dir.writeFile(.{ .sub_path = "50_dcc_b.rcd.bad", .data = "garbage" });

    var out: [8192]u8 = undefined;
    const n = try runReplay(dir_path, &out);
    _ = n;

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("9_dcc_a.rcd"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("50_dcc_b.rcd"));
    _ = try tmp.dir.statFile("77_dcc_c.rcd.part");
    _ = try tmp.dir.statFile("50_dcc_b.rcd.bad");
}

comptime {
    std.testing.refAllDecls(@This());
}
