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

const DepHub = @import("hub.zig").DepHub;
const DepMap = @import("map.zig").DepMap;

pub const DependencyLifetimes = enum { static, scoped };

pub fn DependencyContainer(comptime Config: type) type {
    return DepHub(DepMap(&.{}, DependencyLifetimes).cat(.all), .{}, Config);
}

comptime {
    @import("std").testing.refAllDeclsRecursive(DependencyContainer(struct {}));
}
