const std = @import("std");

const RecordingHeader = @import("recorder.zig").RecordingHeader;

pub const ReadError = error{ TruncatedRecording, InvalidRecording };

/// The parsing counterpart of `Recorder`: a cursor over one recording's
/// bytes. Hardened against truncated or corrupt input — every read is
/// bounds-checked and returns `error.TruncatedRecording` instead of
/// slicing out of range, and op tags are validated against the enum.
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

        fn readBytes(self: *Self, n: u64) ReadError![]const u8 {
            if (self.point + n > self.buffer.len) return error.TruncatedRecording;
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

        pub fn header(self: *Self) !RecordingHeader {
            const hsig = try self.readBytes(4);
            if (!std.mem.eql(u8, hsig, "KWRC")) return error.InvalidRecording;
            const version = try self.byte(u8);
            const timestamp = try self.byte(i64);
            return RecordingHeader{
                .version = version,
                .timestamp = timestamp,
            };
        }

        pub fn op(self: *Self) ReadError!Ops {
            const bytes = try self.readBytes(OpLength);
            const value = std.mem.bytesToValue(OpTag, bytes);
            return std.meta.intToEnum(Ops, value) catch error.InvalidRecording;
        }

        pub fn str(self: *Self) ReadError![]const u8 {
            const len = std.mem.bytesToValue(usize, try self.readBytes(@sizeOf(usize)));
            return try self.readBytes(len);
        }

        pub fn strOpt(self: *Self) ReadError!?[]const u8 {
            const len = std.mem.bytesToValue(usize, try self.readBytes(@sizeOf(usize)));
            if (len == 0) return null;
            return try self.readBytes(len);
        }

        pub fn byte(self: *Self, comptime SizedBytes: type) ReadError!SizedBytes {
            const bytes = try self.readBytes(@sizeOf(SizedBytes));
            return std.mem.bytesToValue(SizedBytes, bytes);
        }

        pub fn byteOpt(self: *Self, comptime SizedBytes: type) ReadError!?SizedBytes {
            const exists = std.mem.bytesToValue(u1, try self.readBytes(@sizeOf(u1)));
            if (exists != 1) return null;
            return try self.byte(SizedBytes);
        }
    };
}

const TestOps = enum { unknown, ping, note };

test "reader round-trips recorder output" {
    const Recorder = @import("recorder.zig").Recorder;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var rec = try Recorder(TestOps).init(std.testing.allocator, &w);
    try rec.op(.ping);
    try rec.str("hello");
    try rec.strOpt(null);
    try rec.byteOpt(u64, 42);
    try rec.op(.note);

    var r = Reader(TestOps){
        .buffer = buf[0..w.end],
        .allocator = std.testing.allocator,
    };
    const h = try r.header();
    try std.testing.expectEqual(@as(u8, 2), h.version);
    try std.testing.expectEqual(TestOps.ping, try r.op());
    try std.testing.expectEqualStrings("hello", try r.str());
    try std.testing.expectEqual(@as(?[]const u8, null), try r.strOpt());
    try std.testing.expectEqual(@as(?u64, 42), try r.byteOpt(u64));
    try std.testing.expectEqual(TestOps.note, try r.op());
    try std.testing.expect(r.atEnd());
}

test "reader errors on truncated input instead of panicking" {
    const Recorder = @import("recorder.zig").Recorder;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var rec = try Recorder(TestOps).init(std.testing.allocator, &w);
    try rec.op(.ping);
    try rec.str("hello");

    // Cut the stream mid string body.
    var r = Reader(TestOps){
        .buffer = buf[0 .. w.end - 3],
        .allocator = std.testing.allocator,
    };
    _ = try r.header();
    _ = try r.op();
    try std.testing.expectError(error.TruncatedRecording, r.str());
}

test "reader rejects bad magic and bad op tags" {
    var r = Reader(TestOps){
        .buffer = "NOPE" ++ [_]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.InvalidRecording, r.header());

    var r2 = Reader(TestOps){
        .buffer = &[_]u8{0xff},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.InvalidRecording, r2.op());
}

comptime {
    std.testing.refAllDecls(@This());
}
