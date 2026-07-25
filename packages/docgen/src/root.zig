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
const builtin = @import("builtin");
const build_config = @import("build_config");

pub const generator = @import("docgen.zig");

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const out_dir = args.next() orelse return error.NoOutput;
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots.deinit(allocator);
    while (args.next()) |arg| try roots.append(allocator, arg);

    try generator.generate(allocator, out_dir, roots.items);
}

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        const allocator = gpa.allocator();
        juicyMain(allocator) catch |e| {
            std.log.err("Application error: {}", .{e});
        };
        _ = gpa.detectLeaks();
    } else {
        const allocator = std.heap.smp_allocator;

        try juicyMain(allocator);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
