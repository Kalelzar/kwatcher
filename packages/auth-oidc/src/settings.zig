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

const std = @import("std");

/// Static auth settings, resolved from a section of the application config
/// (see `di.extension`'s `config_path`). Strictly about token verification —
/// UI concerns (e.g. the IntrospectUI login client) are configured on the UI
/// side (kw-introspect's `security` registries), not here.
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
