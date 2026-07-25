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

//! Pre-built signal routes shipped with the driver.
//!
//! Concatenate them into your signal driver's route set to terminate the
//! runtime gracefully on SIGINT/SIGTERM:
//!
//!     .routes(signal.From(MySignals) ++ signal.From(signal.default.Shutdown))
//!
//! Each handler schedules an internal shutdown through the type-erased
//! `InternalSchedulerShim`, which the runtime registers automatically — so this
//! stays agnostic of the concrete (end-user-assembled) driver set.

const dep = @import("kw-core").deps;
const InternalSchedulerShim = @import("kw-core").scheduler.InternalSchedulerShim;
const SignalInfo = @import("signal.zig").SignalInfo;

pub const Shutdown = struct {
    pub fn @"INT @shutdown-int"(_: SignalInfo, inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(InternalSchedulerShim);
        try scheduler.shutdown(.{ .inj = inj });
    }

    pub fn @"TERM @shutdown-term"(_: SignalInfo, inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(InternalSchedulerShim);
        try scheduler.shutdown(.{ .inj = inj });
    }
};
