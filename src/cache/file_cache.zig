const std = @import("std");
const cache = @import("cache.zig");
const serializer = @import("byte_serializer.zig");

/// A simple filesystem backed cache.
/// NOTE: This should be converted to a vtable so that the implementation can be swapped by the user.
pub fn FileContext(comptime Data: type) type {
    return struct {
        pub const id = "file";
        dir: std.fs.Dir,
        allocator: std.mem.Allocator,

        pub fn get(self: *@This(), key: []const u8) !?Data {
            const pre = key[0..2];
            const post = key[2..4];
            const rest = key[4..];
            var buf: [8]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}/", .{ pre, post });
            var low = try self.dir.makeOpenPath(path, .{});
            defer low.close();
            var file = low.openFile(rest, .{ .mode = .read_only }) catch |e| switch (e) {
                error.FileNotFound => return null,
                else => return e,
            };
            defer file.close();
            var rbuf: [@sizeOf(Data)]u8 = undefined;
            var r = file.reader(&rbuf);
            const reader = &r.interface;
            return try serializer.deserialize(reader, Data, self.allocator, 1);
        }

        pub fn put(self: *@This(), key: []const u8, data: Data) !void {
            const pre = key[0..2];
            const post = key[2..4];
            const rest = key[4..];
            var buf: [8]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}/", .{ pre, post });
            var low = try self.dir.makeOpenPath(path, .{});
            defer low.close();
            var file = try low.createFile(rest, .{});
            defer file.close();
            var wbuf: [@sizeOf(Data)]u8 = undefined;
            var w = file.writer(&wbuf);
            const writer = &w.interface;
            try serializer.serialize(writer, data, 1);
            try writer.flush();
        }

        pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
            const env = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |e| blk: switch (e) {
                error.EnvironmentVariableNotFound => {
                    const home = try std.process.getEnvVarOwned(allocator, "HOME");
                    defer allocator.free(home);
                    break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
                },
                else => return e,
            };
            defer allocator.free(env);
            const dir = try std.fs.path.join(allocator, &.{ env, path });
            defer allocator.free(dir);

            return .{
                .dir = try std.fs.cwd().makeOpenPath(dir, .{}),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.dir.close();
        }
    };
}

pub fn File(comptime Data: type, comptime Invariant: anytype) cache.SetBuilder(Data, Invariant) {
    return cache.SetBuilder(Data, Invariant)
        .new()
        .hotRaw(cache.autoCacheWithContexts(Data, Invariant, .{FileContext(Data)}));
}
