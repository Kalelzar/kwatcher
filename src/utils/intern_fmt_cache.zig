//! A facility for interning strings
//! It supports interning a string by a fmt string
//! and replacing the cached string when the parameters change.

const std = @import("std");
const log = std.log.scoped(.intern_fmt_cache);

const InternFmtCache = @This();

/// An entry in the cache
const InternEntry = struct {
    /// The hashed invariant of the interned string.
    /// Used only for the format string parameters so we know to refresh the string.
    id: u64,
    /// The cached string value.
    /// Owned by the cache.
    string: []const u8,
};

/// A map of a key to an entry.
table: std.StringHashMapUnmanaged(InternEntry),
/// The allocator that manages the cache's owned resources.
allocator: std.mem.Allocator,

/// Creates a new cache managed by the given allocator.
pub fn init(allocator: std.mem.Allocator) InternFmtCache {
    return .{
        .table = .{},
        .allocator = allocator,
    };
}

test init {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    defer cache.deinit();
}

/// Frees the allocated resources by the cache.
pub fn deinit(self: *InternFmtCache) void {
    var it = self.table.valueIterator();
    while (it.next()) |v| {
        self.allocator.free(v.string);
    }
    self.table.deinit(self.allocator);
}

test "expect `deinit` to free all memory in normal usage." {
    const a: i32 = 0;
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    defer cache.deinit();
    _ = try cache.intern("test");
    _ = try cache.intern("test2");
    _ = try cache.internFmt("key", "{d}", .{a});
    _ = try cache.internFmt("key2", "d.{s}.l", .{"test"});
    _ = try cache.internFmt("key", "{d}", .{a + 1});
    var f = try cache.internFmtWithLease("key", "d.{s}.l", .{"test2"});
    defer f.deinit();
}

/// A lease from the cache that contains the current value.
/// If the current value bumped a value off the cache
/// it will be passed along, still allocated by the cache.
/// And it MUST be freed by the caller.
pub const Lease = struct {
    /// The current value in the cache.
    new: []const u8,
    /// The previous value that was replaced, if any.
    old: ?[]const u8,
    /// The allocator of the cache that can be used to free the old value
    allocator: ?std.mem.Allocator,

    /// Frees the leased old value if any.
    pub fn deinit(self: *Lease) void {
        if (self.old) |old| {
            const allocator = self.allocator orelse {
                log.warn("Leaking lease: {s}. Invalid lease.", .{old});
                return;
            };
            allocator.free(old);
        }
    }

    test "expect `deinit` to free the old string when available" {
        const allocator = std.testing.allocator;
        var lease = Lease{
            .new = "test",
            .old = try allocator.dupe(u8, "test"),
            .allocator = allocator,
        };
        lease.deinit();
        try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
    }

    test "expect `deinit` to not try to free the old string when it isn't there" {
        const allocator = std.testing.allocator;
        var lease = Lease{
            .new = "test",
            .old = null,
            .allocator = allocator,
        };
        lease.deinit();
        try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
    }

    /// A helper for checking if the lease contains an updated value.
    pub fn updated(self: *const Lease) bool {
        return if (self.old) |_| true else false;
    }

    test "expect `updated` to be true if an old value exists." {
        const allocator = std.testing.allocator;
        var lease = Lease{
            .new = "test",
            .old = try allocator.dupe(u8, "test"),
            .allocator = allocator,
        };
        lease.deinit();
        try std.testing.expect(lease.updated());
    }

    test "expect `updated` to be false if an old value does not exist." {
        const allocator = std.testing.allocator;
        var lease = Lease{
            .new = "test",
            .old = null,
            .allocator = allocator,
        };
        lease.deinit();
        try std.testing.expect(!lease.updated());
    }
};

/// Intern or get a static comptime string into the cache.
/// It goes in with a hash id of 0 and a key equal to the string.
pub fn intern(self: *InternFmtCache, comptime string: []const u8) ![]const u8 {
    if (self.table.get(string)) |entry| {
        return entry.string;
    }

    const value = InternEntry{ .id = 0, .string = try self.allocator.dupe(u8, string) };
    errdefer self.allocator.free(value.string);
    try self.table.put(self.allocator, string, value);
    return value.string;
}

test intern {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    defer cache.deinit();
    const key = "String";
    const string = try cache.intern(key);
    try std.testing.expectEqualStrings(string, key);
}

test "expect 'intern' to not pollute the cache if an allocation fails during interning" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{
            .fail_index = 1,
            .resize_fail_index = 0,
        },
    );
    const allocator = failing_allocator.allocator();
    var cache = InternFmtCache.init(allocator);
    defer cache.deinit();
    const key = "String";
    try std.testing.expectError(error.OutOfMemory, cache.intern(key));
    try std.testing.expectEqual(0, cache.table.size);
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

/// Intern or get a string by a comptime key and a format string with runtime arguments.
/// If a string exists with the same key but different arguments
/// the old string is freed and replaced.
pub fn internFmt(self: *InternFmtCache, comptime key: []const u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var lease = try self.internFmtWithLease(key, fmt, args);
    defer lease.deinit();
    return lease.new;
}

test "expect 'internFmt' to intern the string correctly." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    try std.testing.expectEqualStrings("test 0", string);
    cache.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

test "expect 'internFmt' to return the same string on second call to intern." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    const string2 = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    try std.testing.expectEqual(string.ptr, string2.ptr);
    try std.testing.expectEqual(string.len, string2.len);
    cache.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

test "expect 'internFmt' to reintern the string on second call to intern with different params." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    const string2 = try cache.internFmt("test", "test {d}", .{@as(i64, 20)});
    try std.testing.expect(string.ptr != string2.ptr);
    try std.testing.expect(string.len != string2.len);
    cache.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

/// Intern or get a string by a comptime key and a format string with runtime arguments.
/// If a string exists with the same key but different arguments
/// the old string is returned as part of the lease for the caller to free.
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
            log.debug("Replacing {s}: {s} [{}]", .{ key, fmt, hash });
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
        log.debug("Interning {s}: {s} [{}]", .{ key, fmt, hash });
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

test "expect 'internFmtWithLease' to intern the string correctly and return no old value." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmtWithLease("test", "test {d}", .{@as(i64, 0)});
    try std.testing.expectEqualStrings("test 0", string.new);
    try std.testing.expectEqual(null, string.old);
    try std.testing.expectEqual(allocator, string.allocator);
    cache.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

test "expect 'internFmtWithLease' to return the same string on second call to intern and return no old value." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    const string2 = try cache.internFmtWithLease("test", "test {d}", .{@as(i64, 0)});
    try std.testing.expectEqualStrings("test 0", string2.new);
    try std.testing.expectEqual(null, string2.old);
    try std.testing.expectEqual(allocator, string2.allocator);
    try std.testing.expectEqual(string.ptr, string2.new.ptr);
    try std.testing.expectEqual(string.len, string2.new.len);
    cache.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

test "expect 'internFmtWithLease' to reintern the string on second call to intern with different params and return old value." {
    const allocator = std.testing.allocator;
    var cache = InternFmtCache.init(allocator);
    const string = try cache.internFmt("test", "test {d}", .{@as(i64, 0)});
    var string2 = try cache.internFmtWithLease("test", "test {d}", .{@as(i64, 10)});
    try std.testing.expectEqualStrings("test 10", string2.new);
    try std.testing.expectEqualStrings("test 0", string2.old.?);
    try std.testing.expectEqual(allocator, string2.allocator);
    try std.testing.expect(string.ptr != string2.new.ptr);
    try std.testing.expect(string.len != string2.new.len);
    cache.deinit();
    string2.deinit();
    try std.testing.expect(!std.testing.allocator_instance.detectLeaks());
}

/// Tests if a set of arguments will reintern the string at the given key.
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
