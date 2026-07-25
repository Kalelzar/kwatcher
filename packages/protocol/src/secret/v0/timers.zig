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

const dep = @import("kw-core").deps;

/// Periodically re-broadcast our registration so stores that started (or
/// lost state) after us still learn our key. Registration is idempotent,
/// so the only cost is a small broadcast every five minutes.
pub fn @"secret_announce 0 */5 * * * *"(inj: *dep.DepCtx) !void {
    const scheduler = try inj.require(@import("secret.zig").Scheduler);
    try scheduler.publish(.{ .@"secret-register" = .{} }, .{ .inj = inj });
}
