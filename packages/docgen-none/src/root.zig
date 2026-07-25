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
const docindex = @import("kw-docindex");

pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version: []const u8,
) !void {
    _ = out_dir;
    _ = allocator;
    _ = doc_index;
    _ = name;
    _ = version;
    std.log.info("Skipping docgen for {s} driver: '{s}'.", .{
        @tagName(Driver.kind),
        @tagName(Driver.key),
    });
}
