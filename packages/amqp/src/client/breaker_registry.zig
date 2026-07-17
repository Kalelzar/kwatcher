const std = @import("std");

const Client = @import("client.zig");
const CircuitBreakingClient = @import("circuit_breaker_client.zig");

/// Ties a primary Client to a fallback Client through a persistent
/// CircuitBreakingClient, tracked by the primary's id.
///
/// Breaker state (failure count, open/half-open timers) has to outlive the
/// short-lived dependency scopes that lease clients, or the failure
/// threshold could never be reached; this registry owns that state. The
/// fallback is swapped in on every wrap, so callers may pass scope-local
/// fallbacks (logging, recording, an alternate broker) — the previous
/// fallback is never referenced again after the swap.
const BreakerRegistry = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
breakers: std.StringHashMapUnmanaged(*CircuitBreakingClient) = .{},

pub fn init(allocator: std.mem.Allocator) BreakerRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *BreakerRegistry) void {
    var it = self.breakers.valueIterator();
    while (it.next()) |breaker| {
        breaker.*.deinit();
        self.allocator.destroy(breaker.*);
    }
    self.breakers.deinit(self.allocator);
}

/// Returns a Client routing through the persistent breaker for `primary`,
/// keyed by `primary.id()`. The same primary always resolves to the same
/// breaker, so failures accumulate across scopes. `primary` must be stable
/// for the registry's lifetime (pool clients are); `fallback` only needs to
/// outlive the caller's use of the returned Client.
pub fn wrap(self: *BreakerRegistry, primary: Client, fallback: Client) !Client {
    self.mutex.lock();
    defer self.mutex.unlock();

    const gop = try self.breakers.getOrPut(self.allocator, primary.id());
    if (!gop.found_existing) {
        errdefer _ = self.breakers.remove(primary.id());
        const breaker = try self.allocator.create(CircuitBreakingClient);
        errdefer self.allocator.destroy(breaker);
        breaker.* = try CircuitBreakingClient.init(self.allocator, primary, fallback, .{});
        gop.value_ptr.* = breaker;
    } else {
        const breaker = gop.value_ptr.*;
        breaker.mutex.lock();
        defer breaker.mutex.unlock();
        breaker.main_client = primary;
        breaker.fallback_client = fallback;
    }

    return gop.value_ptr.*.client();
}
