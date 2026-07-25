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

//! JWT parsing, claim validation, and signature-check orchestration.
//!
//! `parse` allocates everything from the caller's allocator and never frees:
//! it is designed for the per-request scoped arena, which reclaims wholesale.
const std = @import("std");
const jwk = @import("jwk.zig");

pub const JWTHeader = struct {
    alg: []const u8 = "",
    kid: ?[]const u8 = null,
    typ: ?[]const u8 = null,
};

/// RFC 7519 allows `aud` to be either a single string or an array of
/// strings; providers use both, so parse both into one shape.
pub const Audience = struct {
    entries: []const []const u8 = &.{},

    pub fn contains(self: *const Audience, audience: []const u8) bool {
        for (self.entries) |aud| {
            if (std.mem.eql(u8, aud, audience)) return true;
        }
        return false;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Audience {
        switch (try source.peekNextTokenType()) {
            .string => {
                const single = try std.json.innerParse([]const u8, allocator, source, options);
                const entries = try allocator.alloc([]const u8, 1);
                entries[0] = single;
                return .{ .entries = entries };
            },
            .array_begin => {
                return .{ .entries = try std.json.innerParse([]const []const u8, allocator, source, options) };
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Claims = struct {
    scope: ?[]const u8 = null,
    exp: u64 = 0,
    iat: u64 = 0,
    auth_time: ?u64 = null,
    iss: []const u8 = "",
    jti: ?[]const u8 = null,
    aud: Audience = .{},
    sub: []const u8 = "",
    typ: ?[]const u8 = null,
    azp: ?[]const u8 = null,
    sid: ?[]const u8 = null,
    acr: ?[]const u8 = null,
    @"allowed-origins": ?[][]const u8 = null,
    name: ?[]const u8 = null,
    preferred_username: ?[]const u8 = null,
    given_name: ?[]const u8 = null,
    family_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    email_verified: bool = false,
};

pub const JWT = struct {
    header: JWTHeader,
    claims: Claims,
    /// Every claim in the token as raw JSON, for anything not modeled in
    /// `Claims`. `.null` when the claims object is somehow not an object.
    additional_claims: std.json.Value,
    sig: []const u8,
    /// The compact-form token this was parsed from (no `Bearer ` prefix).
    raw: []const u8,
};

pub const ParseError = error{
    MissingHeader,
    MissingClaims,
    MissingSignature,
    MalformedToken,
    KidRequired,
    InvalidKid,
    UnsupportedAlgorithm,
    AlgorithmMismatch,
    OutOfMemory,
} || jwk.VerifyError || error{Unsupported};

/// Parse a compact-form JWT and verify its signature against `keys`.
/// Claim validation (exp/iss/aud/...) is separate — see `validate`.
pub fn parse(allocator: std.mem.Allocator, token: []const u8, keys: *const jwk.KeySet) ParseError!JWT {
    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next() orelse return error.MissingHeader;
    const claims_b64 = it.next() orelse return error.MissingClaims;
    const sig_b64 = it.next() orelse return error.MissingSignature;
    if (it.next() != null) return error.MalformedToken;
    if (claims_b64.len == 0 or sig_b64.len == 0) return error.MalformedToken;

    const header_buf = decodeSegment(allocator, header_b64) catch return error.MalformedToken;
    const claims_buf = decodeSegment(allocator, claims_b64) catch return error.MalformedToken;
    const sig = decodeSegment(allocator, sig_b64) catch return error.MalformedToken;

    const header = std.json.parseFromSliceLeaky(JWTHeader, allocator, header_buf, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedToken,
    };

    const claims = std.json.parseFromSliceLeaky(Claims, allocator, claims_buf, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedToken,
    };

    const additional = std.json.parseFromSliceLeaky(std.json.Value, allocator, claims_buf, .{
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedToken,
    };

    const kid = header.kid orelse return error.KidRequired;
    const alg = jwk.Alg.parse(header.alg) orelse return error.UnsupportedAlgorithm;

    const raw_key = keys.findKid(kid) orelse return error.InvalidKid;
    const key = raw_key.toKey() catch |e| switch (e) {
        error.UnsupportedAlgorithm => return error.UnsupportedAlgorithm,
        error.Unsupported => return error.Unsupported,
        else => return error.InvalidKey,
    };
    if (key.alg() != alg) return error.AlgorithmMismatch;

    const signed_data = token[0 .. header_b64.len + 1 + claims_b64.len];
    try key.verify(signed_data, sig);

    return .{
        .header = header,
        .claims = claims,
        .additional_claims = additional,
        .sig = sig,
        .raw = token,
    };
}

fn decodeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    const b64d = std.base64.url_safe_no_pad.Decoder;
    const size = try b64d.calcSizeForSlice(segment);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try b64d.decode(buf, segment);
    return buf;
}

pub const ValidationError = error{
    TokenNotYetValid,
    TokenExpired,
    IssuerMismatch,
    AudienceMismatch,
    AuthorizedPartyMismatch,
};

pub const ValidateOptions = struct {
    /// Unix seconds, e.g. `std.time.timestamp()`.
    now: i64,
    issuer: []const u8,
    audience: []const u8,
    /// Clock-skew allowance in seconds, applied to both iat and exp.
    leeway: u64 = 5,
};

pub fn validate(claims: *const Claims, opts: ValidateOptions) ValidationError!void {
    const now: u64 = if (opts.now < 0) 0 else @intCast(opts.now);
    if (claims.iat > now + opts.leeway) return error.TokenNotYetValid;
    if (claims.exp + opts.leeway < now) return error.TokenExpired;
    if (!std.mem.eql(u8, claims.iss, opts.issuer)) return error.IssuerMismatch;
    if (!claims.aud.contains(opts.audience)) return error.AudienceMismatch;
    if (claims.azp) |azp| {
        if (!std.mem.eql(u8, azp, opts.audience)) return error.AuthorizedPartyMismatch;
    }
}

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const vectors = @import("test_vectors.zig");

fn testKeySet(arena: std.mem.Allocator) !jwk.KeySet {
    return std.json.parseFromSliceLeaky(jwk.KeySet, arena, vectors.jwks, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "parse + verify RS256 (array aud)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);
    const token = try parse(arena, vectors.rs256, &keys);

    try std.testing.expectEqualStrings("https://idp.test/realms/kw", token.claims.iss);
    try std.testing.expectEqualStrings("user-1234", token.claims.sub);
    try std.testing.expect(token.claims.aud.contains("kwatcher"));
    try std.testing.expect(token.claims.aud.contains("account"));
    try std.testing.expect(!token.claims.aud.contains("other"));
    try std.testing.expect(token.claims.email_verified);
    try std.testing.expectEqualStrings("kalelzar", token.claims.preferred_username.?);
    try std.testing.expectEqualStrings(
        "custom-value",
        token.additional_claims.object.get("custom_claim").?.string,
    );
}

test "parse + verify RS384 (string aud) and RS512" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);

    const t384 = try parse(arena, vectors.rs384, &keys);
    try std.testing.expect(t384.claims.aud.contains("kwatcher"));
    try std.testing.expectEqual(@as(usize, 1), t384.claims.aud.entries.len);

    _ = try parse(arena, vectors.rs512, &keys);
}

test "tampered signature is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);

    var tampered = try arena.dupe(u8, vectors.rs256);
    // Flip a character in the last (signature) segment.
    const last_dot = std.mem.lastIndexOfScalar(u8, tampered, '.').?;
    tampered[last_dot + 1] = if (tampered[last_dot + 1] == 'A') 'B' else 'A';

    try std.testing.expectError(error.BadSignature, parse(arena, tampered, &keys));
}

test "tampered payload is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);

    // Splice the RS512 claims into the RS256 token: individually valid
    // segments, signature no longer matches.
    var it = std.mem.splitScalar(u8, vectors.rs256, '.');
    const h = it.next().?;
    _ = it.next().?;
    const s = it.next().?;
    var it2 = std.mem.splitScalar(u8, vectors.rs384, '.');
    _ = it2.next().?;
    const c2 = it2.next().?;
    const spliced = try std.mem.join(arena, ".", &.{ h, c2, s });

    try std.testing.expectError(error.BadSignature, parse(arena, spliced, &keys));
}

test "unknown kid and alg mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);

    try std.testing.expectError(error.InvalidKid, parse(arena, vectors.unknown_kid, &keys));
    try std.testing.expectError(error.AlgorithmMismatch, parse(arena, vectors.alg_mismatch, &keys));
}

test "malformed tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = try testKeySet(arena);

    try std.testing.expectError(error.MissingClaims, parse(arena, "onlyonepart", &keys));
    try std.testing.expectError(error.MalformedToken, parse(arena, "a.b.c.d", &keys));
    try std.testing.expectError(error.MalformedToken, parse(arena, "!!!.b64.b64", &keys));
}

test "validate claims table" {
    const base = Claims{
        .exp = 2000,
        .iat = 1000,
        .iss = "https://idp.test/realms/kw",
        .aud = .{ .entries = &.{"kwatcher"} },
        .sub = "user-1234",
        .azp = "kwatcher",
    };
    const opts = ValidateOptions{
        .now = 1500,
        .issuer = "https://idp.test/realms/kw",
        .audience = "kwatcher",
    };

    try validate(&base, opts);

    // Leeway boundaries.
    try validate(&base, .{ .now = 995, .issuer = opts.issuer, .audience = opts.audience });
    try validate(&base, .{ .now = 2005, .issuer = opts.issuer, .audience = opts.audience });

    var c = base;
    c.iat = 1506;
    try std.testing.expectError(error.TokenNotYetValid, validate(&c, opts));

    c = base;
    c.exp = 1494;
    try std.testing.expectError(error.TokenExpired, validate(&c, opts));

    c = base;
    c.iss = "https://evil.test";
    try std.testing.expectError(error.IssuerMismatch, validate(&c, opts));

    c = base;
    c.aud = .{ .entries = &.{"other"} };
    try std.testing.expectError(error.AudienceMismatch, validate(&c, opts));

    c = base;
    c.azp = "other";
    try std.testing.expectError(error.AuthorizedPartyMismatch, validate(&c, opts));

    // azp absent is fine.
    c = base;
    c.azp = null;
    try validate(&c, opts);
}
