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
const klib = @import("klib");

pub fn Keyed(comptime Data: type, comptime key: anytype) type {
    _ = key;
    return struct {
        value: Data,
    };
}

pub const InternalArena = klib.mem.InstrumentedArena;

pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;
pub const ScopedAllocator = Keyed(std.mem.Allocator, .scoped);

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(Keyed(u8, .ref));
}
