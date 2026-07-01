const std = @import("std");
const kwev = @import("kwev.zig");

pub const Recorder = struct {
    kwfile: kwev.KWEV,
    writer: std.Io.Writer,
    target: []u8,
    index: u64 = 0,
    id: u64 = 0,
    max_len: isize = 0,

    pub fn initPinned(self: *Recorder, id: u64, max_len: isize) !void {
        self.index = 0;
        self.id = id;
        self.max_len = max_len;
        var buf: [128]u8 = undefined;
        const file = try std.fmt.bufPrint(&buf, "thread-{d}.{d}.kwev", .{ self.id, self.index });
        self.kwfile = try kwev.KWEV.init(file, max_len);
        self.writer = self.kwfile.file.writer();
        self.target = try kwev.next(&self.writer, "static.kwev");
    }

    pub fn deinit(self: *Recorder) void {
        self.writer.undo(20); // 4 bytes chunk name + 2*4 bytes crc + 8 bytes size
        kwev.finalize(&self.writer, self.target) catch {};
        self.writer.flush() catch {};
        self.kwfile.finalize(self.writer.end) catch {};
        self.kwfile.deinit();
    }

    pub fn rotate(self: *Recorder) !void {
        self.deinit();
        var buf: [128]u8 = undefined;
        self.index += 1;
        const file = try std.fmt.bufPrint(&buf, "thread-{d}.{d}.kwev", .{ self.id, self.index });
        self.kwfile = try kwev.KWEV.init(file, self.max_len);
        self.writer = self.kwfile.file.writer();
        self.target = try kwev.next(&self.writer, "static.kwev");
    }

    pub fn append(self: *Recorder, event: anytype) !void {
        kwev.append(&self.writer, self.target, event) catch {
            try self.rotate();
            try kwev.append(&self.writer, self.target, event);
        };
    }
};
