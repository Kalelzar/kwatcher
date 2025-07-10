const std = @import("std");

pub const RecordingHeader = struct {
    version: u8 = 1,
    timestamp: i64,
};

pub fn Recorder(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const OpLength = @sizeOf(@typeInfo(Ops).@"enum".tag_type);

        file: std.fs.File,
        filepath: []const u8,
        temppath: []const u8,
        allocator: std.mem.Allocator,
        anchor_key: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, filepath: []const u8) !Self {
            const path = try std.mem.concat(allocator, u8, &.{ filepath, ".part" });
            errdefer allocator.free(path);

            if (std.fs.path.dirname(filepath)) |d| {
                try std.fs.cwd().makePath(d);
            }

            var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
            errdefer file.close();
            var self: Self = .{
                .file = file,
                .filepath = try allocator.dupe(u8, filepath),
                .temppath = path,
                .allocator = allocator,
            };

            try self.header();

            return self;
        }

        pub fn anchor(self: *Self) ![]const u8 {
            const buf = try std.fmt.allocPrint(self.allocator, "anchor #{}", .{self.anchor_key});
            self.anchor_key += 1;
            return buf;
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
            std.fs.cwd().rename(self.temppath, self.filepath) catch |e| {
                std.log.err("Failed to rename part file '{s}' to '{s}' with '{}'", .{ self.temppath, self.filepath, e });
            };
            self.allocator.free(self.filepath);
            self.allocator.free(self.temppath);
        }

        fn writeBytes(self: *Self, bytes: anytype) !void {
            const arr = std.mem.toBytes(bytes);
            _ = try self.file.write(arr[0..]);
        }

        fn header(self: *Self) !void {
            _ = try self.file.write("KWRC");
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
