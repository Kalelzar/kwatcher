//! File and chunk IO shared by every kwev subcommand.

const std = @import("std");

const kwev = @import("kw-kwev");

pub fn readChunks(allocator: std.mem.Allocator, path: []const u8) ![]const kwev.structures.ChunkData {
    // No size cap: consolidated archives grow without bound and the whole
    // tool is built around whole-file buffers (see the streaming TODO in
    // kwev's writer.zig — a streaming reader is the same future work).
    const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    var fixed = std.Io.Reader.fixed(data);
    var reader = kwev.Reader{ .reader = &fixed };
    return reader.readAll(allocator);
}

/// A .rel link target resolves relative to the linking file, per spec.
pub fn resolveRelative(allocator: std.mem.Allocator, base_file: []const u8, rel: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(base_file) orelse "";
    return if (dir.len == 0) rel else try std.fs.path.join(allocator, &.{ dir, rel });
}

/// Stage as .part and rename so the output name only ever holds a complete
/// file.
pub fn writeAtomic(allocator: std.mem.Allocator, output: []const u8, data: []const u8) !void {
    const part = try std.fmt.allocPrint(allocator, "{s}.part", .{output});
    try std.fs.cwd().writeFile(.{ .sub_path = part, .data = data });
    try std.fs.cwd().rename(part, output);
}

/// Serialize chunks into a `capacity`-byte buffer and atomically write the
/// result to `output`. Returns the serialized size.
pub fn writeArchive(
    allocator: std.mem.Allocator,
    output: []const u8,
    chunks: []const kwev.structures.ChunkData,
    capacity: usize,
) !usize {
    const buf = try allocator.alloc(u8, capacity);
    var w = std.Io.Writer.fixed(buf);
    var writer = kwev.Writer{ .writer = &w };
    const size = try writer.writeAll(chunks);
    try writeAtomic(allocator, output, buf[0..size]);
    return size;
}

/// Expand files/directories into a flat input list. Directories are scanned
/// (non-recursively) for .kwev/.kwev.part files, sorted by name (run stamps
/// are fixed-width milliseconds, so name order = run order). Inputs are not
/// deduplicated.
pub fn collectInputs(allocator: std.mem.Allocator, inputs: []const []const u8) ![]const []const u8 {
    var files = std.ArrayList([]const u8){};
    for (inputs) |input| {
        if (std.fs.cwd().openDir(input, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close();
            var names = std.ArrayList([]const u8){};
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".kwev") and
                    !std.mem.endsWith(u8, entry.name, ".kwev.part")) continue;
                try names.append(allocator, try std.fs.path.join(allocator, &.{ input, entry.name }));
            }
            std.mem.sort([]const u8, names.items, {}, stringLessThan);
            try files.appendSlice(allocator, names.items);
        } else |_| {
            try files.append(allocator, input);
        }
    }
    if (files.items.len == 0) {
        std.log.err("no input files", .{});
        return error.NoInputs;
    }
    return files.items;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
