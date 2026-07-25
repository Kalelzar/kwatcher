// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

//! OIDC discovery (`.well-known/openid-configuration`) and JWKS fetching.
//!
//! Plain fetch functions — caching and locking live in `state.AuthState`.
const std = @import("std");
const log = std.log.scoped(.auth);
const jwk = @import("jwk.zig");

pub const WellKnown = struct {
    issuer: []const u8,
    jwks_uri: []const u8,
    /// Optional because a bare resource server only needs issuer + jwks_uri;
    /// the introspection UI's login flow requires both endpoints.
    authorization_endpoint: ?[]const u8 = null,
    token_endpoint: ?[]const u8 = null,
};

pub fn fetchWellKnown(allocator: std.mem.Allocator, well_known_uri: []const u8) !std.json.Parsed(WellKnown) {
    return fetchJson(WellKnown, allocator, well_known_uri) catch |e| {
        log.err(
            "Failed to acquire the .well-known configuration of the OIDC provider.\n Url: {s}",
            .{well_known_uri},
        );
        return e;
    };
}

pub fn fetchKeySet(allocator: std.mem.Allocator, jwks_uri: []const u8) !std.json.Parsed(jwk.KeySet) {
    return fetchJson(jwk.KeySet, allocator, jwks_uri) catch |e| {
        log.err(
            "Failed to acquire the jwk key set of the OIDC provider.\n Url: {s}",
            .{jwks_uri},
        );
        return e;
    };
}

fn fetchJson(comptime T: type, allocator: std.mem.Allocator, url: []const u8) !std.json.Parsed(T) {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var w = std.io.Writer.Allocating.init(allocator);
    defer w.deinit();

    const request = try client.fetch(.{
        .location = .{ .url = url },
        .keep_alive = false,
        .response_writer = &w.writer,
    });

    if (request.status != .ok) return error.BadRequest;

    return std.json.parseFromSlice(T, allocator, w.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// Ref all decls — non-recursive: fetchJson is generic and network-bound.
comptime {
    std.testing.refAllDecls(@This());
}
