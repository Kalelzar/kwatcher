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
