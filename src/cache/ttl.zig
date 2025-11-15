const std = @import("std");
const metrics = @import("../utils/metrics.zig");
const cache = @import("cache.zig");

fn Node(comptime Data: type) type {
    return struct {
        data: Data,
        expires_at: i64,
        pub fn underlying(self: @This()) Data {
            return self;
        }
    };
}

pub fn Context(
    comptime StorageContextType: anytype,
    comptime Exp: cache.Expiration,
) *const fn (type) type {
    const H = struct {
        pub fn f(comptime Data: type) type {
            return struct {
                pub const id = StorageContext.id ++ ":ttl";
                pub const data_ownership = StorageContext.data_ownership;
                const StorageContext = StorageContextType(DataType);
                const DataType = Node(Data);

                name: []const u8,
                buf: StorageContext,
                allocator: std.mem.Allocator,

                inline fn touch(self: *@This(), node: *DataType) void {
                    _ = self;
                    switch (Exp) {
                        .absolute, .unlimited => {},
                        .sliding => |r| node.expires_at = std.time.timestamp() + r,
                    }
                }

                pub inline fn ensure(self: *@This(), size: usize) !void {
                    return self.buf.ensure(size);
                }

                pub inline fn len(self: *@This()) usize {
                    return self.buf.len();
                }

                pub inline fn remove(self: *@This(), key: []const u8) bool {
                    return self.buf.remove(key);
                }

                pub fn get(self: *@This(), key: []const u8) !?Data {
                    const cached = try self.buf.getPtr(key);
                    if (cached == null) return null;

                    const v = cached.?;

                    if (v.expires_at < std.time.timestamp()) {
                        if (self.buf.remove(key)) {
                            // TODO: deinit the value if needed.
                        }
                        return null;
                    }

                    self.touch(v);

                    return v.data;
                }

                pub fn getPtr(self: *@This(), key: []const u8) !?*Data {
                    const cached = try self.buf.getPtr(key);
                    if (cached == null) return null;

                    const v = cached.?;

                    if (v.expires_at < std.time.timestamp()) {
                        if (self.buf.remove(key)) {
                            // TODO: deinit the value if needed.
                        }
                        return null;
                    }

                    self.touch(v);

                    return &v.data;
                }

                pub inline fn put(self: *@This(), key: []const u8, data: Data) !void {
                    const owned_key = try self.allocator.dupe(u8, key);

                    return self.putBorrowed(owned_key, data);
                }

                pub fn putBorrowed(self: *@This(), key: []const u8, data: Data) !void {
                    const v: DataType = .{
                        .data = data,
                        .expires_at = switch (Exp) {
                            .absolute, .sliding => |r| std.time.timestamp() + r,
                            .unlimited => @compileError("Cannot construct a TTL context with unlimited time-to-live"),
                        },
                    };

                    return self.buf.putBorrowed(
                        key,
                        v,
                    );
                }

                pub fn init(allocator: std.mem.Allocator, name: []const u8) @This() {
                    return .{
                        .name = name,
                        .buf = .init(allocator, name),
                        .allocator = allocator,
                    };
                }

                pub fn deinit(self: *@This()) void {
                    self.buf.deinit();
                }
            };
        }
    };

    return H.f;
}
