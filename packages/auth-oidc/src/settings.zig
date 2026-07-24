const std = @import("std");

/// Static auth settings, resolved from a section of the application config
/// (see `di.extension`'s `config_path`). Strictly about token verification —
/// UI concerns (e.g. the IntrospectUI login client) are configured on the UI
/// side (`http.security.LoginClients`), not here.
pub const Settings = struct {
    /// OIDC discovery document URL
    /// (`https://idp/.../.well-known/openid-configuration`).
    well_known: []const u8,
    /// Expected `aud` claim; also matched against `azp` when present.
    audience: []const u8,
};

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
