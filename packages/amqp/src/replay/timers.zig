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
const dep = @import("kw-core").deps;

const ReplayShim = @import("shim.zig").ReplayShim;

pub const Replay = struct {
    /// Schedule a replay of any recorded amqp messages.
    /// The scheduled event is a noop if the broker is unreachable.
    pub fn @"amqp_replay 0 */15 * * * *"(inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(ReplayShim);
        try scheduler.replay(.{ .inj = inj });
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
