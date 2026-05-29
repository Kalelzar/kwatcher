const std = @import("std");
const builtin = @import("builtin");

const kwev = @import("kw-kwev");

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
        const alloc = std.heap.smp_allocator;
        try juicyMain(alloc);
    }
}

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch unreachable;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch unreachable;

    _ = arg_it.skip();

    const file = arg_it.next() orelse {
        try stderr.print("Usage: <relative_filepath>", .{});
        return error.BadArguments;
    };

    // This writes. Perhaps just a regular mapped file will do.
    var fd = try std.fs.cwd().openFile(file, .{
        .lock = .none,
        .mode = .read_only,
    });
    defer fd.close();

    const stat = try fd.stat();

    const buf = try std.posix.mmap(
        null,
        @intCast(stat.size),
        std.posix.PROT.READ,
        std.posix.MAP{
            .TYPE = .SHARED,
        },
        fd.handle,
        0,
    );
    defer std.posix.munmap(buf);

    var fixed = std.Io.Reader.fixed(buf);

    var kwev_reader = kwev.Reader{ .reader = &fixed };

    const chunks = try kwev_reader.readAll(arena.allocator());
    for (chunks, 0..) |c, i| {
        try stdout.print("[{d}] {t}", .{ i, std.meta.activeTag(c) });
    }
}
