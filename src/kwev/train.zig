//! `kwev train` — train a zstd dictionary from every event record in the
//! inputs and write it to a standalone kwev file (HDRA + DICT + EOF!) meant
//! to be shared via LINK chunks (`consolidate --dict=<this file>`).

const std = @import("std");

const kwev = @import("kw-kwev");

const archive = @import("archive.zig");
const inspection = @import("inspection.zig");

pub fn run(
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
    dict_id: u16,
    dict_version: u16,
    max_size: usize,
) !void {
    const files = try archive.collectInputs(allocator, inputs);

    // Samples are the per-event wire bytes (header + data + properties),
    // mirroring the byte stream EVNC compresses.
    var samples = std.ArrayList([]const u8){};
    var corpus_bytes: usize = 0;
    var header: ?kwev.structures.HeaderA = null;
    for (files) |path| {
        const insp = try inspection.loadValidated(allocator, gpa, path);
        if (header == null) header = insp.header;
        for (insp.batches.items) |b| {
            for (b.records) |r| {
                const sample = try allocator.alloc(u8, 6 + r.data.len + r.properties.len);
                std.mem.writeInt(u16, sample[0..2], r.event_id, .big);
                std.mem.writeInt(u16, sample[2..4], @intCast(r.data.len), .big);
                std.mem.writeInt(u16, sample[4..6], @intCast(r.properties.len), .big);
                @memcpy(sample[6..][0..r.data.len], r.data);
                @memcpy(sample[6 + r.data.len ..], r.properties);
                try samples.append(allocator, sample);
                corpus_bytes += sample.len;
            }
        }
    }
    if (samples.items.len == 0) {
        std.log.err("no event records in the inputs", .{});
        return error.NoSamples;
    }

    const dict = try kwev.compress.trainDict(allocator, samples.items, max_size);

    const chunks = [_]kwev.structures.ChunkData{
        .{ .header_a = header.? },
        .{ .dict = .{
            .id = dict_id,
            .version = dict_version,
            .algorithm = .zstd,
            .dictionary = dict,
        } },
    };
    _ = try archive.writeArchive(allocator, output, &chunks, dict.len + 4096);

    try stdout.print("trained dictionary {d} version {d}: {d} sample(s), {d} corpus byte(s) -> {d} dictionary byte(s) -> {s}\n", .{
        dict_id,
        dict_version,
        samples.items.len,
        corpus_bytes,
        dict.len,
        output,
    });
}
