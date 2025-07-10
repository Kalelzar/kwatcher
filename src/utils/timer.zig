const std = @import("std");

const Timer = @This();

const TimerEntry = struct { interval: u64, last_activation: std.time.Instant };
store: std.StringHashMap(TimerEntry),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Timer {
    const map = std.StringHashMap(TimerEntry).init(allocator);
    return .{
        .store = map,
        .allocator = allocator,
    };
}

pub fn register(self: *Timer, name: []const u8, interval: u64) !void {
    const current_time = try std.time.Instant.now();
    const entry = TimerEntry{
        .interval = interval,
        .last_activation = current_time,
    };
    try self.store.put(name, entry);
}

pub fn ready(self: *const Timer, name: []const u8) !bool {
    const entry = self.store.get(name) orelse return error.NotFound;

    const current_time = try std.time.Instant.now();
    if (current_time.since(entry.last_activation) >= entry.interval) {
        return true;
    }
    return false;
}

pub fn step(self: *Timer) !void {
    const current_time = try std.time.Instant.now();
    var iter = self.store.valueIterator();
    while (iter.next()) |entry_ptr| {
        if (current_time.since(entry_ptr.last_activation) >= entry_ptr.interval) {
            entry_ptr.last_activation = current_time;
        }
    }
}

pub fn deinit(self: *Timer) void {
    self.store.deinit();
}
