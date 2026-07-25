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

//! zstd bindings and the EVNC compress/expand helpers. The bindings are
//! extern declarations against the vendored libzstd (vendor/zstd) — no
//! @cImport, so no header dependency.
const std = @import("std");
const kwev = @import("structure.zig");
const Writer = @import("writer.zig").Writer;
const Reader = @import("reader.zig").Reader;

// === libzstd one-shot API surface ===

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_freeCCtx(cctx: ?*anyopaque) usize;
extern fn ZSTD_compress_usingDict(
    cctx: ?*anyopaque,
    dst: [*]u8,
    dst_capacity: usize,
    src: [*]const u8,
    src_size: usize,
    dict: ?[*]const u8,
    dict_size: usize,
    level: c_int,
) usize;
extern fn ZDICT_trainFromBuffer(
    dict_buffer: [*]u8,
    dict_buffer_capacity: usize,
    samples_buffer: [*]const u8,
    samples_sizes: [*]const usize,
    nb_samples: c_uint,
) usize;
extern fn ZDICT_isError(code: usize) c_uint;
extern fn ZDICT_getErrorName(code: usize) [*:0]const u8;

extern fn ZSTD_createDCtx() ?*anyopaque;
extern fn ZSTD_freeDCtx(dctx: ?*anyopaque) usize;
extern fn ZSTD_decompress_usingDict(
    dctx: ?*anyopaque,
    dst: [*]u8,
    dst_capacity: usize,
    src: [*]const u8,
    src_size: usize,
    dict: ?[*]const u8,
    dict_size: usize,
) usize;

pub const default_level: i32 = 3;

pub const Error = error{
    OutOfMemory,
    CompressionFailed,
    DecompressionFailed,
    DictionaryTrainingFailed,
    LengthMismatch,
    UnsupportedCompression,
    FileCorrupt,
};

/// Train a zstd dictionary (ZDICT) from the given samples. Training wants a
/// LOT of small samples — roughly 100x the dictionary size in corpus bytes;
/// with too few it fails, which surfaces here with the ZDICT error logged.
pub fn trainDict(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    max_size: usize,
) Error![]u8 {
    var total: usize = 0;
    for (samples) |s| total += s.len;

    const corpus = try allocator.alloc(u8, total);
    defer allocator.free(corpus);
    const sizes = try allocator.alloc(usize, samples.len);
    defer allocator.free(sizes);
    var off: usize = 0;
    for (samples, sizes) |s, *size| {
        @memcpy(corpus[off .. off + s.len], s);
        off += s.len;
        size.* = s.len;
    }

    const dict = try allocator.alloc(u8, max_size);
    errdefer allocator.free(dict);
    const written = ZDICT_trainFromBuffer(
        dict.ptr,
        dict.len,
        corpus.ptr,
        sizes.ptr,
        @intCast(samples.len),
    );
    if (ZDICT_isError(written) != 0) {
        std.log.warn(
            "dictionary training failed: {s} (training wants many samples — record more data)",
            .{ZDICT_getErrorName(written)},
        );
        return error.DictionaryTrainingFailed;
    }
    return try allocator.realloc(dict, written);
}

/// One-shot zstd compression, optionally against a raw content dictionary.
pub fn zstdCompress(
    allocator: std.mem.Allocator,
    src: []const u8,
    dict: ?[]const u8,
    level: i32,
) Error![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeCCtx(cctx);

    const bound = ZSTD_compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);

    const d = dict orelse &.{};
    const written = ZSTD_compress_usingDict(
        cctx,
        dst.ptr,
        dst.len,
        src.ptr,
        src.len,
        if (d.len == 0) null else d.ptr,
        d.len,
        @intCast(level),
    );
    if (ZSTD_isError(written) != 0) return error.CompressionFailed;
    return try allocator.realloc(dst, written);
}

/// One-shot zstd decompression into exactly `expected_len` bytes (the
/// EVNC chunk's uncompressed_size); any other outcome is an error.
pub fn zstdDecompress(
    allocator: std.mem.Allocator,
    src: []const u8,
    expected_len: usize,
    dict: ?[]const u8,
) Error![]u8 {
    const dctx = ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeDCtx(dctx);

    const dst = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(dst);

    const d = dict orelse &.{};
    const written = ZSTD_decompress_usingDict(
        dctx,
        dst.ptr,
        dst.len,
        src.ptr,
        src.len,
        if (d.len == 0) null else d.ptr,
        d.len,
    );
    if (ZSTD_isError(written) != 0) return error.DecompressionFailed;
    if (written != expected_len) return error.LengthMismatch;
    return dst;
}

/// Serialize the given event chunks (framed, no magic/EOF) and compress them
/// into an EVNC payload. Only EVNT chunks are legal inside an EVNC.
pub fn compressChunks(
    allocator: std.mem.Allocator,
    chunks: []const kwev.ChunkData,
    compression: kwev.CompressionType,
    dictionary_id: u16,
    dictionary_version: u16,
    dict: ?[]const u8,
) (Error || std.Io.Writer.Error)!kwev.Evnc {
    var size: usize = 0;
    for (chunks) |c| {
        std.debug.assert(std.meta.activeTag(c) == .event);
        // Frame overhead (16) + payload upper bound.
        size += 16 + 2;
        for (c.event.events) |e| size += 6 + e.data.len + e.properties.len;
    }

    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    var w = std.Io.Writer.fixed(buf);
    var writer = Writer{ .writer = &w };
    for (chunks) |c| try writer.writeChunk(c);
    const raw = w.buffered();

    const data = switch (compression) {
        .none => try allocator.dupe(u8, raw),
        .zstd => try zstdCompress(allocator, raw, dict, default_level),
        .xz, .lz4 => return error.UnsupportedCompression,
    };

    return .{
        .compression = compression,
        .dictionary_id = dictionary_id,
        .dictionary_version = dictionary_version,
        .uncompressed_size = raw.len,
        .compressed_data = data,
    };
}

/// Decompress an EVNC chunk and parse its contents back into the event
/// chunks it carries. Per spec only EVNT (later EMTA/EDAT) chunks are legal
/// inside; anything else is corruption.
pub fn expandEvnc(
    allocator: std.mem.Allocator,
    evnc: kwev.Evnc,
    dict: ?[]const u8,
) anyerror![]const kwev.ChunkData {
    const raw: []const u8 = switch (evnc.compression) {
        .none => blk: {
            if (evnc.compressed_data.len != evnc.uncompressed_size) return error.LengthMismatch;
            break :blk evnc.compressed_data;
        },
        .zstd => try zstdDecompress(
            allocator,
            evnc.compressed_data,
            evnc.uncompressed_size,
            dict,
        ),
        .xz, .lz4 => return error.UnsupportedCompression,
    };

    var chunks = std.ArrayList(kwev.ChunkData){};
    errdefer chunks.deinit(allocator);
    var r = std.Io.Reader.fixed(raw);
    var reader = Reader{ .reader = &r };
    while (r.bufferedLen() != 0) {
        const next = try chunks.addOne(allocator);
        try reader.readChunk(next, allocator);
        switch (std.meta.activeTag(next.*)) {
            .event => {},
            else => return error.FileCorrupt,
        }
    }
    return chunks.toOwnedSlice(allocator);
}

const test_chunks: []const kwev.ChunkData = &.{
    .{ .event = .{ .events = &.{
        .{ .event_id = 0, .data = "hello", .properties = ".{}" },
        .{ .event_id = 1, .data = "world!", .properties = ".{.a=1}" },
    } } },
    .{ .event = .{ .events = &.{
        .{ .event_id = 2, .data = "again", .properties = ".{}" },
    } } },
};

fn expectExpanded(expanded: []const kwev.ChunkData) !void {
    try std.testing.expectEqual(2, expanded.len);
    try std.testing.expectEqual(2, expanded[0].event.events.len);
    try std.testing.expectEqualStrings("hello", expanded[0].event.events[0].data);
    try std.testing.expectEqualStrings(".{.a=1}", expanded[0].event.events[1].properties);
    try std.testing.expectEqual(1, expanded[1].event.events.len);
    try std.testing.expectEqualStrings("again", expanded[1].event.events[0].data);
}

test "compress/expand roundtrip: none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const evnc = try compressChunks(a, test_chunks, .none, 0, 0, null);
    try std.testing.expectEqual(evnc.uncompressed_size, evnc.compressed_data.len);
    try expectExpanded(try expandEvnc(a, evnc, null));
}

test "compress/expand roundtrip: zstd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const evnc = try compressChunks(a, test_chunks, .zstd, 0, 0, null);
    try expectExpanded(try expandEvnc(a, evnc, null));
}

test "compress/expand roundtrip: zstd with a raw content dictionary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Any byte blob works as a raw content dictionary; resembling the
    // payload is what a trained dictionary would do better.
    const dict = "hello world! again .{.a=1} EVNT";
    const evnc = try compressChunks(a, test_chunks, .zstd, 7, 1, dict);
    try std.testing.expectEqual(7, evnc.dictionary_id);
    try expectExpanded(try expandEvnc(a, evnc, dict));
    // The wrong dictionary must fail somewhere: raw content dictionaries
    // carry no id, so zstd may "succeed" and produce garbage — which the
    // inner chunk CRCs then reject. Either layer erroring is correct.
    if (expandEvnc(a, evnc, "a completely different dictionary")) |_| {
        return error.TestExpectedFailure;
    } else |_| {}
}

test "expand rejects a wrong uncompressed_size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var evnc = try compressChunks(a, test_chunks, .zstd, 0, 0, null);
    evnc.uncompressed_size += 1;
    try std.testing.expectError(error.LengthMismatch, expandEvnc(a, evnc, null));
}

test "expand rejects garbage data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const evnc = kwev.Evnc{
        .compression = .zstd,
        .dictionary_id = 0,
        .dictionary_version = 0,
        .uncompressed_size = 64,
        .compressed_data = "certainly not a zstd frame",
    };
    try std.testing.expectError(error.DecompressionFailed, expandEvnc(a, evnc, null));
}

test "expand rejects non-event chunks inside" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    try writer.writeChunk(.{ .link = .{ .rel = "defs.kwev" } });
    const evnc = kwev.Evnc{
        .compression = .none,
        .dictionary_id = 0,
        .dictionary_version = 0,
        .uncompressed_size = w.buffered().len,
        .compressed_data = w.buffered(),
    };
    try std.testing.expectError(error.FileCorrupt, expandEvnc(a, evnc, null));
}

test "trainDict: trains on a repetitive corpus and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Synthetic zon-ish records, the shape the recorder produces.
    var samples = std.ArrayList([]const u8){};
    for (0..1000) |i| {
        try samples.append(a, try std.fmt.allocPrint(
            a,
            ".{{.route=.heartbeat_tick,.n={d}}}.{{.correlation_id=.{{.timestamp={d},.version=1,.root_op_id=130683285}}}}",
            .{ i % 7, 1783244680203810191 + i },
        ));
    }

    const dict = try trainDict(a, samples.items, 4 * 1024);
    try std.testing.expect(dict.len > 0);
    try std.testing.expect(dict.len <= 4 * 1024);

    // The trained dictionary must actually work for EVNC roundtrips.
    const evnc = try compressChunks(a, test_chunks, .zstd, 1, 1, dict);
    try expectExpanded(try expandEvnc(a, evnc, dict));
}

test "trainDict: too few samples fails cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const samples: []const []const u8 = &.{ "one", "two" };
    try std.testing.expectError(
        error.DictionaryTrainingFailed,
        trainDict(a, samples, 4 * 1024),
    );
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
