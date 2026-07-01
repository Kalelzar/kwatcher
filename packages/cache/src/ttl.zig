const std = @import("std");
const metrics = @import("kw-core").metrics;
const cache = @import("cache.zig");

fn Node(comptime Data: type) type {
    return struct {
        data: Data,
        expires_at: u64,
        pub fn underlying(self: @This()) Data {
            return self.data;
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
                pub const key_type = StorageContext.key_type;
                const StorageContext = StorageContextType(DataType);
                const DataType = Node(Data);

                name: []const u8,
                buf: StorageContext,
                timer: std.time.Timer,
                allocator: std.mem.Allocator,

                inline fn touch(self: *@This(), node: *DataType, time: u64) void {
                    _ = self;
                    switch (Exp) {
                        .absolute, .unlimited => {},
                        .sliding => |r| node.expires_at = time + r,
                    }
                }

                pub inline fn ensure(self: *@This(), size: usize) !void {
                    return self.buf.ensure(size);
                }

                pub inline fn len(self: *@This()) usize {
                    return self.buf.len();
                }

                pub inline fn remove(self: *@This(), key: u64) bool {
                    return self.buf.remove(key);
                }

                pub fn get(self: *@This(), key: u64) !?Data {
                    const cached = try self.buf.getPtr(key);
                    if (cached == null) return null;

                    const v = cached.?;

                    const time = self.timer.read() / std.time.ns_per_s;

                    if (v.expires_at < time) {
                        if (self.buf.remove(key)) {
                            // TODO: deinit the value if needed.
                        }
                        return null;
                    }

                    self.touch(v, time);

                    return v.data;
                }

                pub fn getPtr(self: *@This(), key: u64) !?*Data {
                    const cached = try self.buf.getPtr(key);
                    if (cached == null) return null;

                    const v = cached.?;

                    const time = self.timer.read() / std.time.ns_per_s;

                    if (v.expires_at < time) {
                        if (self.buf.remove(key)) {
                            // TODO: deinit the value if needed.
                        }
                        return null;
                    }

                    self.touch(v, time);

                    return &v.data;
                }

                pub inline fn put(self: *@This(), key: u64, data: Data) !void {
                    return self.putBorrowed(key, data);
                }

                pub fn putBorrowed(self: *@This(), key: u64, data: Data) !void {
                    const v: DataType = .{
                        .data = data,
                        .expires_at = switch (Exp) {
                            .absolute, .sliding => |r| self.timer.read() / std.time.ns_per_s + r,
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
                        .timer = std.time.Timer.start() catch unreachable, // FIXME: Lying to the compiler
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
