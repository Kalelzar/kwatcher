const std = @import("std");

pub const RecordingHeader = struct {
    /// Record layouts are consumer-defined; producers bump this when a
    /// layout changes. v1: master-era layouts. v2: amqp publish records
    /// carry the publisher key after the expiration.
    version: u8 = 2,
    timestamp: i64,
};

/// A binary op-stream serializer. Writes the KWRC header on init and then
/// caller-driven op/str/byte records to the given writer. The recorder does
/// not own the writer or any backing file — lifecycle (creation, flushing,
/// finalization) belongs to the caller.
pub fn Recorder(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const OpLength = @sizeOf(@typeInfo(Ops).@"enum".tag_type);

        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
        anchor_key: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) !Self {
            var self: Self = .{
                .writer = writer,
                .allocator = allocator,
            };

            try self.header();

            return self;
        }

        /// Returns a unique placeholder name, owned by the caller.
        pub fn anchor(self: *Self) ![]const u8 {
            const buf = try std.fmt.allocPrint(self.allocator, "anchor #{}", .{self.anchor_key});
            self.anchor_key += 1;
            return buf;
        }

        fn writeBytes(self: *Self, bytes: anytype) !void {
            const arr = std.mem.toBytes(bytes);
            try self.writer.writeAll(arr[0..]);
        }

        fn header(self: *Self) !void {
            try self.writer.writeAll("KWRC");
            const h = RecordingHeader{
                .timestamp = std.time.timestamp(),
            };

            try self.byte(u8, h.version);
            try self.byte(i64, h.timestamp);
        }

        pub fn op(self: *Self, operation: Ops) !void {
            const value = @intFromEnum(operation);
            try self.writeBytes(value);
        }

        pub fn str(self: *Self, s: []const u8) !void {
            try self.writeBytes(s.len);
            try self.writer.writeAll(s);
        }

        pub fn strOpt(self: *Self, s: ?[]const u8) !void {
            if (s) |string| {
                try self.str(string);
            } else {
                try self.writeBytes(@as(usize, 0));
            }
        }

        pub fn byte(self: *Self, comptime SizedBytes: type, b: SizedBytes) !void {
            try self.writeBytes(b);
        }

        pub fn byteOpt(self: *Self, comptime SizedBytes: type, b: ?SizedBytes) !void {
            if (b) |bytes| {
                try self.writeBytes(@as(u1, 1));
                try self.writeBytes(bytes);
            } else {
                try self.writeBytes(@as(u1, 0));
            }
        }
    };
}

test "recorder writes the KWRC header and records through the given writer" {
    const TestOps = enum { unknown, ping };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var r = try Recorder(TestOps).init(std.testing.allocator, &w);
    try r.op(.ping);
    try r.str("hi");
    try std.testing.expectEqualStrings("KWRC", buf[0..4]);
    try std.testing.expectEqual(@as(u8, 2), buf[4]);
    // 4 magic + 1 version + 8 timestamp, then 1 op byte
    try std.testing.expectEqual(@as(u8, @intFromEnum(TestOps.ping)), buf[13]);
    // usize length prefix + payload
    try std.testing.expectEqual(@as(usize, 2), std.mem.bytesToValue(usize, buf[14..22]));
    try std.testing.expectEqualStrings("hi", buf[22..24]);
}

// Ref all decls — Recorder is a generic; it is instantiated concretely by
// the test above and by kw-amqp's DurableCacheClient.
comptime {
    std.testing.refAllDecls(@This());
}
