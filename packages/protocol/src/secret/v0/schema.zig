const std = @import("std");
const schema = @import("kw-core").schema;

pub const SecretRegister = struct {
    /// The encryption scheme this key is registered for.
    /// v0 defines exactly one value: "kw.sealed-box.v0".
    scheme: []const u8,
    /// The client's Ed25519 public key, standard base64 with padding.
    public_key: []const u8,
    /// Blake2b-256 of the raw public key, lowercase hex.
    /// Derivable from public_key; included for transparency.
    kid: []const u8,
    /// Client information.
    client: schema.Client.V2,
};

pub const SecretGet = struct {
    /// The encryption scheme the response must use.
    scheme: []const u8,
    /// The key id the response must be encrypted to.
    kid: []const u8,
    /// The identifier of the requested secret. Opaque UTF-8;
    /// namespacing is the application's business.
    secret_identifier: []const u8,
    /// Client information.
    client: schema.Client.V2,
};

pub const SecretResponse = struct {
    /// The encryption scheme used to seal the secret.
    scheme: []const u8,
    /// The key id the secret is encrypted to.
    kid: []const u8,
    /// The identifier of the delivered secret.
    secret_identifier: []const u8,
    /// The responding store's client information. Self-asserted;
    /// informational only in v0.
    store: schema.Client.V2,
    /// The ephemeral X25519 public key of the sealed box,
    /// standard base64 with padding.
    ephemeral_public_key: []const u8,
    /// The sealed secret: ciphertext followed by the 16-byte
    /// Poly1305 tag, standard base64 with padding.
    ciphertext: []const u8,
};

pub const Secret = struct {
    pub const Register = struct {
        /// A secret-store key registration v0.
        /// Broadcast to any listening store; fire-and-forget.
        pub const V0 = schema.Schema(
            0,
            "secret.register",
            SecretRegister,
        );
    };

    pub const Get = struct {
        /// A secret request v0.
        /// Carries reply_to = secret.v0.{client_id}; any store holding
        /// the secret may answer on that route over amq.topic. Silence
        /// is the only negative signal.
        pub const V0 = schema.Schema(
            0,
            "secret.get",
            SecretGet,
        );
    };

    pub const Response = struct {
        /// A secret response v0.
        /// The secret is sealed to the public key registered for kid.
        pub const V0 = schema.Schema(
            0,
            "secret.response",
            SecretResponse,
        );
    };

    pub const Reannounce = struct {
        pub const Request = struct {
            /// A registration request v0.
            /// Empty; clients answer by re-broadcasting their
            /// registration on the canonical route.
            pub const V0 = schema.Schema(
                0,
                "secret.reannounce.request",
                struct {},
            );
        };
    };
};

test "secret.get v0 wire shape" {
    const allocator = std.testing.allocator;
    const msg = Secret.Get.V0{
        .scheme = "kw.sealed-box.v0",
        .kid = "abc123",
        .secret_identifier = "api/example",
        .client = .{ .id = "client-1", .version = "1.0.0", .name = "example" },
    };

    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    var json = std.json.fmt(msg, .{});
    try json.format(&allocating.writer);
    const body = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_name\":\"secret.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_version\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret_identifier\":\"api/example\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"kid\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_name\":\"client\"") != null);
}
