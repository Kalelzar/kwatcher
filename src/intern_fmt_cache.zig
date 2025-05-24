const std = @import("std");

const InternFmtCache = @This();

const InternEntry = struct {
    id: u64,
    string: []const u8,
};

table: std.StringHashMapUnmanaged(InternEntry),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) InternFmtCache {
    return .{
        .table = .{},
        .allocator = allocator,
    };
}

pub fn deinit(self: *InternFmtCache) void {
    var it = self.table.valueIterator();
    while (it.next()) |v| {
        self.allocator.free(v.string);
    }
    self.table.deinit(self.allocator);
}

pub const Lease = struct {
    new: []const u8,
    old: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Lease) void {
        if (self.old) |old|
            self.allocator.free(old);
    }

    pub fn updated(self: *const Lease) bool {
        return if (self.old) |_| true else false;
    }
};

pub fn intern(self: *InternFmtCache, comptime string: []const u8) ![]const u8 {
    if (self.table.get(string)) |entry| {
        return entry.string;
    }

    const value = .{ .id = 0, .string = try self.allocator.dupe(u8, string) };
    errdefer self.allocator.free(value.string);
    try self.table.put(self.allocator, string, value);
    return value.string;
}

pub fn internFmt(self: *InternFmtCache, comptime key: []const u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var lease = try self.internFmtWithLease(key, fmt, args);
    defer lease.deinit();
    return lease.new;
}

pub fn internFmtWithLease(self: *InternFmtCache, comptime key: []const u8, comptime fmt: []const u8, args: anytype) !Lease {
    var hasher = std.hash.Fnv1a_64.init();
    std.hash.autoHashStrat(&hasher, args, .DeepRecursive);

    const hash = hasher.final();
    if (self.table.getPtr(key)) |entry| {
        if (entry.id == hash) {
            return .{
                .new = entry.string,
                .old = null,
                .allocator = self.allocator,
            };
        } else {
            std.log.debug("++ Replacing {s}: {s} [{}]", .{ key, fmt, hash });
            const new = try std.fmt.allocPrint(self.allocator, fmt, args);
            const old = entry.string;
            entry.id = hash;
            entry.string = new;
            return .{
                .new = new,
                .old = old,
                .allocator = self.allocator,
            };
        }
    } else {
        std.log.debug("++ Interning {s}: {s} [{}]", .{ key, fmt, hash });
        const out = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(out);

        try self.table.put(
            self.allocator,
            key,
            .{ .id = hash, .string = out },
        );
        return .{
            .new = out,
            .old = null,
            .allocator = self.allocator,
        };
    }
}

pub fn willReintern(self: *InternFmtCache, comptime key: []const u8, args: anytype) bool {
    var hasher = std.hash.Fnv1a_64.init();
    std.hash.autoHashStrat(&hasher, args, .DeepRecursive);

    const hash = hasher.final();

    if (self.table.get(key)) |entry| {
        if (entry.id == hash) {
            return false;
        }
    }
    return true;
}
