//! JSON Web Key types and signature verification.
//!
//! RSA verification is backed by `std.crypto.Certificate.rsa` — no external
//! crypto dependency. The alg dispatch is structured so EC (ES256 via
//! `std.crypto.sign.ecdsa`) can slot in later without reshaping the API.
const std = @import("std");
const rsa = std.crypto.Certificate.rsa;

pub const KeyType = enum {
    EC,
    RSA,
    oct,
    OKP,
};

/// Signature algorithms we can verify. Unknown algs are rejected at
/// `RawJWK.toKey` time with `error.UnsupportedAlgorithm`.
pub const Alg = enum {
    RS256,
    RS384,
    RS512,

    pub fn parse(s: []const u8) ?Alg {
        return std.meta.stringToEnum(Alg, s);
    }
};

/// A JWK as it appears in a JWKS document; unknown fields are ignored by the
/// JSON parser, unused ones (x5*, EC coordinates) are kept for completeness.
pub const RawJWK = struct {
    kty: KeyType,
    use: ?[]const u8 = null,
    alg: ?[]const u8 = null,
    kid: []const u8,
    x5u: ?[]const u8 = null,
    x5c: ?[][]const u8 = null,
    x5t: ?[]const u8 = null,
    @"x5t#S256": ?[]const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
    x: ?[]const u8 = null,
    y: ?[]const u8 = null,
    crv: ?[]const u8 = null,

    pub fn toKey(self: *const RawJWK) !JWK {
        return switch (self.kty) {
            .RSA => self.toRSA(),
            else => error.Unsupported,
        };
    }

    pub fn toRSA(self: *const RawJWK) !JWK {
        const alg_name = self.alg orelse return error.MissingAlg;
        return .{
            .RSA = .{
                .alg = Alg.parse(alg_name) orelse return error.UnsupportedAlgorithm,
                .kid = self.kid,
                .n = self.n orelse return error.NoModulus,
                .e = self.e orelse return error.NoExponent,
            },
        };
    }
};

pub const KeySet = struct {
    keys: []RawJWK,

    pub fn findKid(self: *const KeySet, kid: []const u8) ?*const RawJWK {
        for (self.keys) |*key| {
            if (std.mem.eql(u8, key.kid, kid)) return key;
        }
        return null;
    }
};

pub const VerifyError = error{
    InvalidKey,
    UnsupportedKeySize,
    BadSignature,
};

pub const JWK = union(KeyType) {
    EC: void,
    RSA: Rsa,
    oct: void,
    OKP: void,

    pub fn alg(self: *const JWK) ?Alg {
        return switch (self.*) {
            .RSA => |r| r.alg,
            else => null,
        };
    }

    /// Verify `signature` over `msg`. Errors instead of returning bool so a
    /// forgotten result check fails loudly.
    pub fn verify(self: *const JWK, msg: []const u8, signature: []const u8) (VerifyError || error{Unsupported})!void {
        return switch (self.*) {
            .RSA => |*r| r.verify(msg, signature),
            else => error.Unsupported,
        };
    }

    pub const Rsa = struct {
        kid: []const u8,
        alg: Alg,
        /// base64url(no pad) big-endian modulus, as it appears in the JWK.
        n: []const u8,
        /// base64url(no pad) big-endian public exponent.
        e: []const u8,

        pub fn verify(self: *const Rsa, msg: []const u8, signature: []const u8) VerifyError!void {
            const b64d = std.base64.url_safe_no_pad.Decoder;

            // 4096-bit modulus max — same ceiling as std.crypto's rsa.
            var nb: [512]u8 = undefined;
            const nlen = b64d.calcSizeForSlice(self.n) catch return error.InvalidKey;
            if (nlen > nb.len) return error.UnsupportedKeySize;
            b64d.decode(nb[0..nlen], self.n) catch return error.InvalidKey;

            // fromBytes rejects exponents above 32 bits anyway.
            var eb: [4]u8 = undefined;
            const elen = b64d.calcSizeForSlice(self.e) catch return error.InvalidKey;
            if (elen > eb.len) return error.InvalidKey;
            b64d.decode(eb[0..elen], self.e) catch return error.InvalidKey;

            const key = rsa.PublicKey.fromBytes(eb[0..elen], nb[0..nlen]) catch return error.InvalidKey;

            // PKCS#1 v1.5 needs the modulus length at comptime; JWKS keys in
            // the wild are 2048/3072/4096-bit, so dispatch on signature size.
            switch (signature.len) {
                inline 256, 384, 512 => |modulus_len| return verifySized(modulus_len, self.alg, key, msg, signature),
                else => return error.UnsupportedKeySize,
            }
        }

        fn verifySized(
            comptime modulus_len: usize,
            algo: Alg,
            key: rsa.PublicKey,
            msg: []const u8,
            signature: []const u8,
        ) VerifyError!void {
            const sig = rsa.PKCS1v1_5Signature.fromBytes(modulus_len, signature);
            const sha2 = std.crypto.hash.sha2;
            switch (algo) {
                .RS256 => rsa.PKCS1v1_5Signature.verify(modulus_len, sig, msg, key, sha2.Sha256) catch return error.BadSignature,
                .RS384 => rsa.PKCS1v1_5Signature.verify(modulus_len, sig, msg, key, sha2.Sha384) catch return error.BadSignature,
                .RS512 => rsa.PKCS1v1_5Signature.verify(modulus_len, sig, msg, key, sha2.Sha512) catch return error.BadSignature,
            }
        }
    };
};

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
