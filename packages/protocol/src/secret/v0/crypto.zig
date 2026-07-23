//! Wire cryptography for the secret v0 protocol (scheme "kw.sealed-box.v0").
//!
//! A client's identity is an Ed25519 keypair. For encryption both sides
//! derive X25519 keys from it (RFC 8032 -> birational map to Montgomery).
//! Secrets travel in a libsodium-*style* sealed box built entirely from
//! std.crypto primitives (not libsodium-compatible: XChaCha20-Poly1305 and
//! Blake2b replace crypto_box's XSalsa20/HSalsa20):
//!
//!   recipient_x = X25519(recipient ed25519 public key)
//!   (eph_sk, eph_pk) = fresh X25519 keypair, never reused
//!   shared = X25519.scalarmult(eph_sk, recipient_x)
//!   key    = Blake2b-256("kwatcher.secret.v0.key" || shared || eph_pk || recipient_x)
//!   nonce  = Blake2b-192(eph_pk || recipient_x)
//!   ct     = XChaCha20-Poly1305.encrypt(key, nonce, plaintext, aad) || tag
//!
//! The AAD binds the ciphertext to the recipient and the secret name:
//!   "kwatcher.secret.v0" || 0x00 || kid_hex || 0x00 || secret_identifier
//!
//! Both seal (store side) and open (client side) live here so the store
//! implementation reuses the exact construction the client verifies against.
const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const Blake2b192 = std.crypto.hash.blake2.Blake2b(192);

/// The only scheme defined by v0. Receivers ignore messages carrying
/// anything else; v1 negotiation will add values next to it.
pub const scheme_v0 = "kw.sealed-box.v0";

pub const public_key_len = 32;
/// base64(standard, padded) of a 32-byte key.
pub const public_key_b64_len = std.base64.standard.Encoder.calcSize(public_key_len);
pub const kid_len = Blake2b256.digest_length;
pub const kid_hex_len = kid_len * 2;
pub const nonce_len = XChaCha20Poly1305.nonce_length;
pub const tag_len = XChaCha20Poly1305.tag_length;

const key_domain = "kwatcher.secret.v0.key";
const aad_domain = "kwatcher.secret.v0";

/// kid = Blake2b-256 of the raw Ed25519 public key.
pub fn deriveKid(ed_pub: [public_key_len]u8) [kid_len]u8 {
    var out: [kid_len]u8 = undefined;
    Blake2b256.hash(&ed_pub, &out, .{});
    return out;
}

/// The wire form of a kid: 64 lowercase hex characters.
pub fn kidHex(kid: [kid_len]u8) [kid_hex_len]u8 {
    return std.fmt.bytesToHex(kid, .lower);
}

/// The wire form of a public key: standard base64 with padding.
pub fn encodeKey(key: [public_key_len]u8) [public_key_b64_len]u8 {
    var out: [public_key_b64_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &key);
    return out;
}

/// Decodes a wire-form 32-byte key. Any length or alphabet mismatch is
/// error.InvalidEncoding.
pub fn decodeKey(b64: []const u8) error{InvalidEncoding}![public_key_len]u8 {
    var out: [public_key_len]u8 = undefined;
    const len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch
        return error.InvalidEncoding;
    if (len != public_key_len) return error.InvalidEncoding;
    std.base64.standard.Decoder.decode(&out, b64) catch return error.InvalidEncoding;
    return out;
}

/// AAD = "kwatcher.secret.v0" \x00 kid_hex \x00 secret_identifier.
/// Caller owns the returned slice.
pub fn buildAad(
    allocator: std.mem.Allocator,
    kid_hex: []const u8,
    secret_identifier: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        aad_domain ++ "\x00{s}\x00{s}",
        .{ kid_hex, secret_identifier },
    );
}

fn deriveKey(
    shared: [X25519.shared_length]u8,
    eph_pk: [public_key_len]u8,
    recipient_x: [public_key_len]u8,
) [XChaCha20Poly1305.key_length]u8 {
    var h = Blake2b256.init(.{});
    h.update(key_domain);
    h.update(&shared);
    h.update(&eph_pk);
    h.update(&recipient_x);
    var out: [XChaCha20Poly1305.key_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn deriveNonce(
    eph_pk: [public_key_len]u8,
    recipient_x: [public_key_len]u8,
) [nonce_len]u8 {
    var h = Blake2b192.init(.{});
    h.update(&eph_pk);
    h.update(&recipient_x);
    var out: [nonce_len]u8 = undefined;
    h.final(&out);
    return out;
}

/// A sealed box ready for the wire (after base64-encoding both parts).
pub const Sealed = struct {
    ephemeral_public_key: [public_key_len]u8,
    /// ciphertext || 16-byte tag; caller owns.
    ciphertext: []u8,
};

/// Store side: seal a secret to a registered Ed25519 public key.
/// A fresh ephemeral keypair is generated per call.
pub fn seal(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    recipient_ed_pub: [public_key_len]u8,
    aad: []const u8,
) !Sealed {
    const recipient_pk = Ed25519.PublicKey.fromBytes(recipient_ed_pub) catch
        return error.InvalidPublicKey;
    const recipient_x = X25519.publicKeyFromEd25519(recipient_pk) catch
        return error.InvalidPublicKey;

    const eph = X25519.KeyPair.generate();
    var shared = X25519.scalarmult(eph.secret_key, recipient_x) catch
        return error.InvalidPublicKey;
    defer std.crypto.secureZero(u8, &shared);

    var key = deriveKey(shared, eph.public_key, recipient_x);
    defer std.crypto.secureZero(u8, &key);
    const nonce = deriveNonce(eph.public_key, recipient_x);

    const ct = try allocator.alloc(u8, plaintext.len + tag_len);
    errdefer allocator.free(ct);
    XChaCha20Poly1305.encrypt(
        ct[0..plaintext.len],
        ct[plaintext.len..][0..tag_len],
        plaintext,
        aad,
        nonce,
        key,
    );

    return .{
        .ephemeral_public_key = eph.public_key,
        .ciphertext = ct,
    };
}

/// Client side: open a sealed box with our Ed25519 identity keypair.
/// Returns the caller-owned plaintext, or error.AuthenticationFailed if the
/// tag (and thus the AAD binding) does not verify.
pub fn open(
    allocator: std.mem.Allocator,
    ephemeral_public_key: [public_key_len]u8,
    ciphertext: []const u8,
    keypair: Ed25519.KeyPair,
    aad: []const u8,
) ![]u8 {
    if (ciphertext.len < tag_len) return error.AuthenticationFailed;

    var x = X25519.KeyPair.fromEd25519(keypair) catch return error.InvalidKeyPair;
    defer std.crypto.secureZero(u8, &x.secret_key);
    var shared = X25519.scalarmult(x.secret_key, ephemeral_public_key) catch
        return error.AuthenticationFailed;
    defer std.crypto.secureZero(u8, &shared);

    var key = deriveKey(shared, ephemeral_public_key, x.public_key);
    defer std.crypto.secureZero(u8, &key);
    const nonce = deriveNonce(ephemeral_public_key, x.public_key);

    const msg_len = ciphertext.len - tag_len;
    const plaintext = try allocator.alloc(u8, msg_len);
    errdefer allocator.free(plaintext);
    const tag: [tag_len]u8 = ciphertext[msg_len..][0..tag_len].*;
    try XChaCha20Poly1305.decrypt(
        plaintext,
        ciphertext[0..msg_len],
        tag,
        aad,
        nonce,
        key,
    );
    return plaintext;
}

test "seal/open round-trip" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();

    const aad = try buildAad(allocator, &kidHex(deriveKid(kp.public_key.bytes)), "api/example");
    defer allocator.free(aad);

    const sealed = try seal(allocator, "hunter2", kp.public_key.bytes, aad);
    defer allocator.free(sealed.ciphertext);

    const plaintext = try open(allocator, sealed.ephemeral_public_key, sealed.ciphertext, kp, aad);
    defer allocator.free(plaintext);
    try std.testing.expectEqualStrings("hunter2", plaintext);
}

test "open rejects a mismatched aad" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();

    const sealed = try seal(allocator, "hunter2", kp.public_key.bytes, "aad-one");
    defer allocator.free(sealed.ciphertext);

    try std.testing.expectError(
        error.AuthenticationFailed,
        open(allocator, sealed.ephemeral_public_key, sealed.ciphertext, kp, "aad-two"),
    );
}

test "open rejects tampered ciphertext" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();

    const sealed = try seal(allocator, "hunter2", kp.public_key.bytes, "aad");
    defer allocator.free(sealed.ciphertext);
    sealed.ciphertext[0] ^= 0x01;

    try std.testing.expectError(
        error.AuthenticationFailed,
        open(allocator, sealed.ephemeral_public_key, sealed.ciphertext, kp, "aad"),
    );
}

test "open rejects a foreign keypair" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();
    const other = Ed25519.KeyPair.generate();

    const sealed = try seal(allocator, "hunter2", kp.public_key.bytes, "aad");
    defer allocator.free(sealed.ciphertext);

    try std.testing.expectError(
        error.AuthenticationFailed,
        open(allocator, sealed.ephemeral_public_key, sealed.ciphertext, other, "aad"),
    );
}

test "seal generates a fresh ephemeral keypair per call" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();

    const a = try seal(allocator, "hunter2", kp.public_key.bytes, "aad");
    defer allocator.free(a.ciphertext);
    const b = try seal(allocator, "hunter2", kp.public_key.bytes, "aad");
    defer allocator.free(b.ciphertext);

    try std.testing.expect(!std.mem.eql(u8, &a.ephemeral_public_key, &b.ephemeral_public_key));
    try std.testing.expect(!std.mem.eql(u8, a.ciphertext, b.ciphertext));
}

// Pins the kid construction (Blake2b-256 of the raw public key, lowercase
// hex). The same vector appears in the RFC appendix (SECRET.md) — keep the
// two in sync.
test "deterministic kid vector" {
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const kid = kidHex(deriveKid(kp.public_key.bytes));
    try std.testing.expectEqualStrings(
        "26e88ab5574ac2e825b8747d05aeca98c53e4457da600e43e77164fd768d84c1",
        &kid,
    );
}

// Pins the full sealed-box construction (X25519 conversion, key/nonce
// derivation, AEAD, AAD layout). The same vector appears in the RFC
// appendix (SECRET.md) — keep the two in sync.
test "deterministic sealed-box vector opens" {
    const allocator = std.testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);

    const eph = try decodeKey("BLzS4NAPLM5f6PHGwvvsXAf6VuOqXIilaJl12Is/zgU=");
    var ciphertext: [7 + tag_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(&ciphertext, "lle80YDrmro7AfekjEiDRwdlTNgwpa8=");

    const aad = try buildAad(
        allocator,
        "26e88ab5574ac2e825b8747d05aeca98c53e4457da600e43e77164fd768d84c1",
        "api/example",
    );
    defer allocator.free(aad);

    const plaintext = try open(allocator, eph, &ciphertext, kp, aad);
    defer allocator.free(plaintext);
    try std.testing.expectEqualStrings("hunter2", plaintext);
}

test "key wire encoding round-trips" {
    const kp = Ed25519.KeyPair.generate();
    const b64 = encodeKey(kp.public_key.bytes);
    const decoded = try decodeKey(&b64);
    try std.testing.expectEqualSlices(u8, &kp.public_key.bytes, &decoded);

    try std.testing.expectError(error.InvalidEncoding, decodeKey("too-short"));
    try std.testing.expectError(error.InvalidEncoding, decodeKey("!" ** public_key_b64_len));
}
