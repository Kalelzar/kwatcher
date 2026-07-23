/// Expiration (ms) for registration broadcasts. Registrations are
/// fire-and-forget; stale ones should not queue up on the broker.
register_message_expiration: u64 = 5 * 1000,

/// Expiration (ms) for secret requests. Silence is the only negative
/// signal in v0, so requests must not outlive the client's patience.
request_message_expiration: u64 = 30 * 1000,

/// Where the client's Ed25519 identity seed lives (32 raw bytes,
/// created with mode 0600 on first use). Defaults to
/// $XDG_CONFIG_HOME/kwatcher/secret.ed25519 (or ~/.config/kwatcher/...).
key_path: ?[]const u8 = null,
