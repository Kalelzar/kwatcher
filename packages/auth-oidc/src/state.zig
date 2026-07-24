//! Runtime auth state: cached OIDC discovery + JWKS, and the DI contexts
//! that carry it.
//!
//! The DI hub registers every non-optional field of a context struct and
//! every pub fn decl as a factory, so the registered contexts here are thin
//! field-carriers; behavior lives on the payload types.
const std = @import("std");
const discovery = @import("discovery.zig");
const jwk = @import("jwk.zig");
const settings_mod = @import("settings.zig");
const Identity = @import("identity.zig").Identity;

/// Process-wide auth state. Thread-safe: the HTTP driver dispatches requests
/// on a worker pool.
///
/// Superseded key sets are retained (not freed) on refresh: a concurrent
/// request may still be verifying against the old set, and rotations are
/// rare enough that the leak is bounded and harmless.
pub const AuthState = struct {
    /// Persistent allocator, set by `di.extension.apply`.
    alloc: ?std.mem.Allocator = null,
    mutex: std.Thread.Mutex = .{},
    well_known: ?std.json.Parsed(discovery.WellKnown) = null,
    keysets: std.ArrayList(std.json.Parsed(jwk.KeySet)) = .empty,

    pub fn discoveryData(self: *AuthState, settings: *const settings_mod.Settings) !discovery.WellKnown {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.discoveryLocked(settings);
    }

    pub fn keys(
        self: *AuthState,
        settings: *const settings_mod.Settings,
        opts: struct { force: bool = false },
    ) !jwk.KeySet {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!opts.force and self.keysets.items.len != 0) {
            return self.keysets.items[self.keysets.items.len - 1].value;
        }

        const alloc = self.alloc orelse return error.NotInitialized;
        const wk = try self.discoveryLocked(settings);
        const parsed = try discovery.fetchKeySet(alloc, wk.jwks_uri);
        errdefer parsed.deinit();
        try self.keysets.append(alloc, parsed);
        return parsed.value;
    }

    fn discoveryLocked(self: *AuthState, settings: *const settings_mod.Settings) !discovery.WellKnown {
        if (self.well_known) |p| return p.value;
        const alloc = self.alloc orelse return error.NotInitialized;
        self.well_known = try discovery.fetchWellKnown(alloc, settings.well_known);
        return self.well_known.?.value;
    }

    pub fn deinit(self: *AuthState) void {
        const alloc = self.alloc orelse return;
        if (self.well_known) |p| p.deinit();
        for (self.keysets.items) |p| p.deinit();
        self.keysets.deinit(alloc);
        self.* = .{};
    }
};

/// Static DI context carrying the process-wide `AuthState`. The field
/// registration makes `*AuthState` requireable.
pub const AuthStateCtx = struct {
    state: AuthState = .{},

    pub fn deconstruct(self: *AuthStateCtx) void {
        self.state.deinit();
    }
};

/// Per-request scoped DI context. The field registration makes `Identity`,
/// `*Identity` and `*const Identity` requireable by downstream handlers and
/// middleware; the auth wrapper fills it before calling inward.
///
/// `identity` is deliberately non-optional — the hub skips optional fields
/// entirely, and a fresh instance is zero-inited to `Identity`'s defaults
/// each request. `arena` is deliberately optional for the same reason (it
/// must NOT be registered): it backs the parsed token, because the request's
/// pooled scoped allocator is a single 4KiB bump block — far too small for
/// JWT parsing. The middleware creates it lazily from `AuthState`'s
/// allocator; the hub tears it down via `deconstruct` after the response is
/// written.
pub const AuthCtx = struct {
    identity: Identity = .{},
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deconstruct(self: *AuthCtx) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }
};

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
