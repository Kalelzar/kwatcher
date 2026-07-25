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

// kwatcher-core: foundation layer (DI, types, comptime machinery, shared contracts).
// Nothing here depends on the runtime or any driver.

// types & DI
pub const schema = @import("schema_companion.zig");
pub const event = @import("event.zig");
pub const correlation = @import("correlation.zig");
pub const deps = @import("dep.zig");
pub const driver = @import("driver.zig");
pub const scheduler = @import("scheduler.zig");
pub const DriverRegistry = @import("driver.zig").Drivers;
pub const mem = @import("mem/mem.zig");

// utils
pub const config = @import("utils/config.zig");
pub const metrics = @import("utils/metrics.zig");
pub const InternFmtCache = @import("utils/intern_fmt_cache.zig");
pub const recorder = @import("utils/recorder.zig");
pub const reader = @import("utils/reader.zig");
pub const meta = @import("utils/meta.zig");
pub const shared = @import("utils/shared.zig");
pub const queue = @import("utils/queue.zig");
pub const resolver = @import("utils/resolver.zig");
pub const arc = @import("utils/arc.zig");
pub const pool = @import("utils/pool.zig");

/// Event-block membership predicate, shared by every driver. Lives in core so
/// drivers need not import the runtime.
pub const genAccepts = @import("event.zig").genAccepts;

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
