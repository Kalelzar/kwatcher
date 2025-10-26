const std = @import("std");
const log = std.log.scoped(.replay);

const schema = @import("../schema.zig");
const metrics = @import("../utils/metrics.zig");

const Client = @import("../client/client.zig");

const AmqpOps = @import("ops.zig").Ops;
const Header = @import("recorder.zig").RecordingHeader;

pub fn Reader(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const OpTag = @typeInfo(Ops).@"enum".tag_type;
        const OpLength = @sizeOf(OpTag);

        buffer: []const u8,
        allocator: std.mem.Allocator,
        point: u64 = 0,

        pub fn atEnd(self: *Self) bool {
            return self.point >= self.buffer.len;
        }

        pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
            if (std.fs.path.dirname(path)) |d| {
                try std.fs.cwd().makePath(d);
            }

            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const buffer = try file.readToEndAlloc(allocator, 128 * 1024 * 1024 * 1024);
            errdefer allocator.free(buffer);
            return .{
                .buffer = buffer,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        fn readBytes(self: *Self, n: u64) []const u8 {
            const slice = self.buffer[self.point .. self.point + n];
            self.point += n;
            return slice;
        }

        pub fn checkpoint(self: *Self) u64 {
            return self.point;
        }

        pub fn restore(self: *Self, mark: u64) void {
            self.point = mark;
        }

        pub fn header(self: *Self) !Header {
            const hsig = self.readBytes(4);
            if (!std.mem.eql(u8, hsig, "KWRC")) return error.InvalidRecording;
            const version = self.byte(u8);
            const timestamp = self.byte(i64);
            return Header{
                .version = version,
                .timestamp = timestamp,
            };
        }

        pub fn op(self: *Self) Ops {
            const bytes = self.readBytes(OpLength);
            const value = std.mem.bytesAsValue(OpTag, bytes.ptr);
            return @enumFromInt(value.*);
        }

        pub fn str(self: *Self) []const u8 {
            const length = self.readBytes(@sizeOf(usize));
            const len_ptr = std.mem.bytesAsValue(usize, length);
            const len: usize = len_ptr.*;

            const body = self.readBytes(len);
            return body;
        }

        pub fn strOpt(self: *Self) ?[]const u8 {
            const length = self.readBytes(@sizeOf(usize));
            const len_ptr = std.mem.bytesAsValue(usize, length);
            const len: usize = len_ptr.*;
            if (len != 0) {
                const body = self.readBytes(len);
                return body;
            } else {
                return null;
            }
        }

        pub fn byte(self: *Self, comptime SizedBytes: type) SizedBytes {
            const bytes = self.readBytes(@sizeOf(SizedBytes));
            const value = std.mem.bytesAsValue(SizedBytes, bytes.ptr);
            return value.*;
        }

        pub fn byteOpt(self: *Self, comptime SizedBytes: type) ?SizedBytes {
            const exists = self.readBytes(@sizeOf(u1));
            const exists_ptr = std.mem.bytesAsValue(u1, exists);
            const exists_v = exists_ptr.*;

            if (exists_v == 1) {
                const bytes = self.readBytes(@sizeOf(SizedBytes));
                const value = std.mem.bytesAsValue(SizedBytes, bytes.ptr);
                return value.*;
            }

            return null;
        }
    };
}

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

    fn nextRecording(self: *ReplayManager) !?[]const u8 {
        log.debug("Obtaining next recording.", .{});
        var it = self.replay_dir.iterate();
        var oldest: ?[]const u8 = null;
        var oldest_timestamp: ?i64 = null;
        log.debug("Beginning iteration.", .{});
        while (try it.next()) |entry| {
            log.debug("Trying {s}: {}", .{ entry.name, entry.kind });
            if (entry.kind != .file) continue; // We might want to follow symlinks here but this is fine for now
            if (!std.mem.endsWith(u8, entry.name, ".rcd")) continue;

            const name = entry.name[0..(entry.name.len - 4)];
            const timestamp = std.fmt.parseInt(i64, name, 10) catch continue;
            const isOlder = if (oldest_timestamp) |ot| ot > timestamp else true;
            log.debug("Oldest: {?}, Current: {} | {}", .{ oldest_timestamp, timestamp, isOlder });
            if (isOlder) {
                if (oldest) |o| self.allocator.free(o);
                oldest = try self.allocator.dupe(u8, entry.name);
                oldest_timestamp = timestamp;
            }
        }

        log.debug("Found: {?s}", .{oldest});

        return oldest;
    }

    fn getResumePoint(self: *ReplayManager, path: []const u8) !u64 {
        const file = self.replay_dir.openFile(path, .{}) catch |e| switch (e) {
            std.fs.File.OpenError.FileNotFound => return 0,
            else => return e,
        };

        var buf: [8]u8 = undefined;
        const bytes = try file.read(&buf);
        if (bytes != 8) return error.InvalidCheckpoint;
        const slice = buf[0..];
        const value = std.mem.bytesAsValue(u64, slice);
        return value.*;
    }

    pub fn replay(self: *ReplayManager) !void {
        log.debug("Replaying from '{s}'", .{self.replay_dir_path});
        while (try self.nextRecording()) |recording| {
            defer self.allocator.free(recording);

            const path = try std.fs.path.resolve(self.allocator, &.{ self.replay_dir_path, recording });
            defer self.allocator.free(path);

            log.info("Replaying {s} from '{s}'", .{ recording, path });

            const start_time = std.time.microTimestamp();

            try self.client.connect();
            defer self.client.disconnect() catch {};

            var player = try Player.init(self.allocator, self.client, path);
            const prog = try std.mem.concat(self.allocator, u8, &.{ recording, ".checkpoint" });
            defer self.allocator.free(prog);
            const resumepoint = try self.getResumePoint(prog);

            log.info("Resuming from position: {}", .{resumepoint});

            if (resumepoint > 0) {
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
    reader: *Reader(AmqpOps),
    allocator: std.mem.Allocator,

    string_cache: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, client: Client, path: []const u8) !Player {
        const reader_ptr = try allocator.create(Reader(AmqpOps));
        errdefer allocator.destroy(reader_ptr);
        const client_ptr = try allocator.create(Client);
        errdefer allocator.destroy(client_ptr);
        reader_ptr.* = try Reader(AmqpOps).init(allocator, path);
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
        _ = header;
        while (!self.reader.atEnd()) {
            const mark = self.reader.checkpoint();
            errdefer self.reader.restore(mark);
            if (mark > checkpoint and isResuming) return error.InvalidCheckpoint;
            isResuming = isResuming and mark != checkpoint;

            const op = self.reader.op();
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
        const queue_name = self.reader.strOpt();
        const binding_key = self.reader.str();
        const exchange = self.reader.str();
        const channel = self.reader.strOpt();
        const consumer_tag = self.reader.str();

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
        const channel = self.reader.strOpt();
        const body = self.reader.str();
        const routing_key = self.reader.str();
        const exchange = self.reader.str();
        const reply_to = self.reader.strOpt();
        const correlation_id = self.reader.strOpt();
        const expires_at = self.reader.byteOpt(u64);
        if (!resuming) {
            const message: schema.SendMessage = .{
                .body = body,
                .options = .{
                    .routing_key = routing_key,
                    .exchange = exchange,
                    .norecord = false,
                    .reply_to = reply_to,
                    .correlation_id = correlation_id,
                    .expiration = expires_at,
                },
            };

            try self.client.publish(
                message,
                .{ .channel_name = channel },
            );
        }
    }

    fn readOpenChannel(self: *Player) !void {
        const channel = self.reader.str();
        try self.client.openChannel(channel);
    }

    fn readCloseChannel(self: *Player) !void {
        const channel = self.reader.str();
        try self.client.closeChannel(channel);
    }

    fn readDeclareEphemeralQueue(self: *Player) !void {
        const anchor = self.reader.str();
        const queue_name = try self.client.declareEphemeralQueue();
        try self.link(anchor, queue_name);
    }

    fn readDeclareDurableQueue(self: *Player) !void {
        const queue_name = self.reader.str();
        _ = try self.client.declareDurableQueue(queue_name);
    }

    fn readUnbind(self: *Player) !void {
        const consumer_tag = self.reader.str();
        const channel = self.reader.strOpt();

        const actual_tag = self.follow(consumer_tag);

        try self.client.unbind(actual_tag, .{ .channel_name = channel });
    }
};
