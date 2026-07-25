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

// kwatcher: the runtime engine. Generic over the driver set, which the consumer
// assembles. Nothing depends on this package — it is a peer leaf of the drivers.

pub const server = @import("server.zig");
pub const default = @import("default.zig");

/// Driver-agnostic middleware shipped with the runtime. (HTTP-specific
/// middleware like CORS lives in the http package.)
pub const middleware = struct {
    pub const latency = @import("latency.zig").WithLatency;
    pub const Latency = @import("latency.zig");
    pub const enable_if = @import("middleware/enable.zig").EnableIf;
};

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
