const std = @import("std");
const builtin = @import("builtin");

const kwev = @import("kw-kwev");

const dump = @import("dump.zig");
const inspect = @import("inspect.zig");
const consolidate = @import("consolidate.zig");
const train = @import("train.zig");
const graph = @import("graph.zig");

pub fn main() void {
    const result = if (comptime builtin.mode == .Debug) blk: {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        const r = juicyMain(gpa.allocator());
        _ = gpa.detectLeaks();
        break :blk r;
    } else juicyMain(std.heap.smp_allocator);

    result catch |e| {
        // usage() already printed its own diagnostic.
        if (e != error.BadArguments) std.log.err("Application error: {}", .{e});
        std.process.exit(1);
    };
}

const Cmd = enum {
    dump,
    inspect,
    consolidate,
    train,
    graph,
};

const commands = std.StaticStringMap(Cmd).initComptime(&.{
    .{ "dump", .dump },
    .{ "inspect", .inspect },
    .{ "consolidate", .consolidate },
    .{ "train", .train },
    .{ "graph", .graph },
});

const Ctx = struct {
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    _ = arg_it.skip();

    const command = arg_it.next() orelse return usage(stderr);
    const file = arg_it.next() orelse return usage(stderr);
    const cmd = commands.get(command) orelse return usage(stderr);

    const ctx = Ctx{ .arena = arena.allocator(), .stdout = stdout, .stderr = stderr };
    const args = try collectArgs(ctx.arena, &arg_it, file);

    switch (cmd) {
        .dump => try dump.run(ctx.arena, stdout, args[0]),
        .inspect => try inspect.run(ctx.arena, stdout, args[0]),
        .consolidate => try cmdConsolidate(ctx, args),
        .train => try cmdTrain(ctx, args),
        .graph => try cmdGraph(ctx, args),
    }
}

fn collectArgs(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    first: []const u8,
) ![]const []const u8 {
    var args = std.ArrayList([]const u8){};
    try args.append(allocator, first);
    while (arg_it.next()) |arg| {
        try args.append(allocator, arg);
    }
    return args.items;
}

/// "--name=value" -> "value"; null if `arg` is anything else.
fn flagValue(arg: []const u8, comptime flag: []const u8) ?[]const u8 {
    const prefix = flag ++ "=";
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

fn cmdConsolidate(ctx: Ctx, args: []const []const u8) !void {
    var compression: ?kwev.structures.CompressionType = null;
    var dict_path: ?[]const u8 = null;
    var inputs = std.ArrayList([]const u8){};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--compress")) {
            compression = .zstd;
        } else if (flagValue(arg, "--compress")) |mode| {
            compression = std.meta.stringToEnum(kwev.structures.CompressionType, mode) orelse
                return usage(ctx.stderr);
            if (compression == .xz or compression == .lz4) {
                std.log.err("writing {s} is not supported (use zstd or none)", .{mode});
                return error.UnsupportedCompression;
            }
        } else if (flagValue(arg, "--dict")) |path| {
            dict_path = path;
        } else {
            try inputs.append(ctx.arena, arg);
        }
    }
    if (dict_path != null) {
        // A dictionary is only meaningful for a compressed archive.
        if (compression == null) compression = .zstd;
        if (compression == .none) {
            std.log.err("--dict requires compression (drop --compress=none)", .{});
            return error.BadArguments;
        }
    }
    if (inputs.items.len < 2) return usage(ctx.stderr);
    try consolidate.run(ctx.arena, ctx.stdout, ctx.stderr, inputs.items[0], inputs.items[1..], compression, dict_path);
}

fn cmdTrain(ctx: Ctx, args: []const []const u8) !void {
    var dict_id: u16 = 1;
    var dict_version: u16 = 1;
    var max_size: usize = 112640;
    var inputs = std.ArrayList([]const u8){};
    for (args) |arg| {
        if (flagValue(arg, "--dict-id")) |v| {
            dict_id = try std.fmt.parseInt(u16, v, 10);
        } else if (flagValue(arg, "--dict-version")) |v| {
            dict_version = try std.fmt.parseInt(u16, v, 10);
        } else if (flagValue(arg, "--max-size")) |v| {
            max_size = try std.fmt.parseInt(usize, v, 10);
        } else {
            try inputs.append(ctx.arena, arg);
        }
    }
    if (dict_id == 0 or dict_version == 0) {
        std.log.err("dictionary id and version must be non-zero (0 is reserved)", .{});
        return error.BadArguments;
    }
    if (inputs.items.len < 2) return usage(ctx.stderr);
    try train.run(ctx.arena, ctx.stdout, inputs.items[0], inputs.items[1..], dict_id, dict_version, max_size);
}

fn cmdGraph(ctx: Ctx, args: []const []const u8) !void {
    if (args.len < 2) return usage(ctx.stderr);
    try graph.run(ctx.arena, ctx.stdout, ctx.stderr, args[0], args[1..]);
}

fn usage(stderr: *std.Io.Writer) error{BadArguments} {
    stderr.print(
        \\Usage: kwev <dump|inspect> <filepath>
        \\       kwev consolidate [--compress[=zstd|none]] [--dict=<dict.kwev>] <output> <input...>
        \\       kwev train [--dict-id=N] [--dict-version=N] [--max-size=N] <output.kwev> <input...>
        \\       kwev graph <output.dot> <input...>
        \\
    , .{}) catch {};
    return error.BadArguments;
}
