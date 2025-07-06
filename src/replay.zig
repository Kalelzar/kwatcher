const std = @import("std");
const Client = @import("client.zig");
const AmqpOps = @import("ops.zig").Ops;
const schema = @import("schema.zig");

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
        while (!self.reader.atEnd()) {
            const op = self.reader.op();
            switch (op) {
                .bind => try self.readBind(),
                .unbind => try self.readUnbind(),
                .publish => try self.readPublish(),
                .open_channel => try self.readOpenChannel(),
                .close_channel => try self.readCloseChannel(),
                .declare_ephemeral_queue => try self.readDeclareEphemeralQueue(),
                .declare_durable_queue => try self.readDeclareDurableQueue(),
                else => |other| {
                    std.log.err("Op '{s}' is not supported yet.", .{@tagName(other)});
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

    fn readPublish(self: *Player) !void {
        const channel = self.reader.strOpt();
        const body = self.reader.str();
        const routing_key = self.reader.str();
        const exchange = self.reader.str();
        const reply_to = self.reader.strOpt();
        const correlation_id = self.reader.strOpt();
        const expires_at = self.reader.byteOpt(u64);

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
