const std = @import("std");

pub fn Recorder(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const OpLength = @sizeOf(@typeInfo(Ops).@"enum".tag_type);

        file: *std.fs.File,
        allocator: std.mem.Allocator,
        anchor_key: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, file: std.fs.File) !Self {
            const self: Self = .{
                .file = try allocator.create(std.fs.File),
                .allocator = allocator,
            };

            self.file.* = file;
            return self;
        }

        pub fn anchor(self: *Self) ![]const u8 {
            const buf = try std.fmt.allocPrint(self.allocator, "anchor #{}", .{self.anchor_key});
            self.anchor_key += 1;
            return buf;
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
            self.allocator.destroy(self.file);
        }

        fn writeBytes(self: *Self, bytes: anytype) !void {
            const arr = std.mem.toBytes(bytes);
            _ = try self.file.write(arr[0..]);
        }

        pub fn op(self: *Self, operation: Ops) !void {
            const value = @intFromEnum(operation);
            try self.writeBytes(value);
        }

        pub fn str(self: *Self, s: []const u8) !void {
            try self.writeBytes(s.len);
            _ = try self.file.write(s);
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
