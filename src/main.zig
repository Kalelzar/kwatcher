const std = @import("std");
const builtin = @import("builtin");

const kwatcher = @import("kwatcher");
const klib = @import("klib");

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = allocator;
}

var slot: *anyopaque = undefined;

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        try juicyMain(allocator);
    } else {
        const alloc = std.heap.smp_allocator;
        try juicyMain(alloc);
    }
}
