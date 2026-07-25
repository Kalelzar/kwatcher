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

/// A hot/cold cache that will either retrieve from cache or retrieve the element from the cold path
/// and automatically cache it.
pub fn HotCold(comptime Data: type) type {
    return struct {
        action_name: []const u8,
        key: []const u8,
        hot: ?*const fn (*dep.DepCtx, *anyopaque) anyerror!Data = null,
        cold: ?*const fn (*dep.DepCtx, *anyopaque) anyerror!Data = null,
        push: ?*const fn (*dep.DepCtx, Data, *anyopaque) anyerror!?Data = null,

        pub inline fn interface(self: *const @This()) HotCold(Data) {
            return self.*;
        }
    };
}
