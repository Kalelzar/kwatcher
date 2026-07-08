//! `kwev consolidate` — merge files/dirs into one flattened archive: links
//! inlined, a single definition set (which must match across ALL inputs),
//! SEVT re-encoded as EVNT chunks, torn chunks salvaged with a warning.

const std = @import("std");

const kwev = @import("kw-kwev");

const archive = @import("archive.zig");
const inspection = @import("inspection.zig");
const Inspection = inspection.Inspection;

pub fn run(
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
    compression: ?kwev.structures.CompressionType,
    dict_path: ?[]const u8,
) !void {
    const dict: ?kwev.structures.Dict = if (dict_path) |p| try loadDictFile(allocator, p) else null;
    const files = try archive.collectInputs(allocator, inputs);

    var reference: ?Inspection = null;
    var chunks = std.ArrayList(kwev.structures.ChunkData){};
    var events = std.ArrayList(kwev.structures.ChunkData){};
    var total_size: usize = 0;
    var total_records: usize = 0;
    var salvaged: usize = 0;

    for (files) |path| {
        total_size += (try std.fs.cwd().statFile(path)).size;
        const insp = try inspection.loadValidated(allocator, gpa, path);
        total_size += insp.expanded_bytes;
        if (reference) |*ref| {
            try expectSameDefs(ref, &insp, path);
        } else {
            reference = insp;
        }

        for (insp.batches.items) |b| {
            if (b.records.len == 0) continue;
            if (!b.sealed) {
                salvaged += b.records.len;
                try stderr.print("warning: {s}: torn chunk, salvaged {d} record(s)\n", .{ path, b.records.len });
            }
            // One EVNT chunk per source chunk, split at the u16 count limit.
            var rest = b.records;
            while (rest.len > 0) {
                const n = @min(rest.len, std.math.maxInt(u16));
                try events.append(allocator, .{ .event = .{ .events = rest[0..n] } });
                total_records += n;
                rest = rest[n..];
            }
        }
    }

    const ref = reference.?;
    try chunks.append(allocator, .{ .header_a = ref.header.? });
    try chunks.append(allocator, .{ .drivers = .{ .drivers = ref.drivers } });
    for (ref.etyps.items) |e| try chunks.append(allocator, .{ .event_type = e });
    for (ref.rophs.items) |r| try chunks.append(allocator, .{ .route_op_hash = r });
    for (ref.dicts.items) |d| {
        // The LINK emitted below supersedes carried copies of the same
        // dictionary (e.g. re-consolidating an archive that linked it):
        // embedding it too would defeat the shared-dictionary point.
        if (dict != null and d.id == dict.?.id) continue;
        try chunks.append(allocator, .{ .dict = d });
    }

    if (dict_path) |p| {
        // The dictionary is shared via LINK, never embedded — rel links
        // resolve relative to the linking file, so store the path relative
        // to where the OUTPUT lives (or absolute if given absolute).
        if (std.fs.path.isAbsolute(p)) {
            try chunks.append(allocator, .{ .link = .{ .abs = p } });
        } else {
            const out_dir = std.fs.path.dirname(output) orelse ".";
            const rel = try std.fs.path.relative(allocator, out_dir, p);
            try chunks.append(allocator, .{ .link = .{ .rel = rel } });
        }
    }

    if (compression) |algo| {
        // One EVNC per group of event chunks, each group bounded by an
        // uncompressed-size budget — a chunk has framing and buffers cap out,
        // so a single unbounded EVNC is only reasonable while it fits.
        // Boundaries are computed up front so the groups (independent zstd
        // jobs) can compress on a thread pool; results append in order, so
        // the output stays byte-identical to the serial path.
        const max_evnc_uncompressed = 4 * 1024 * 1024;
        const Group = struct { start: usize, end: usize };
        var groups = std.ArrayList(Group){};
        var start_idx: usize = 0;
        var group_size: usize = 0;
        for (events.items, 0..) |ec, idx| {
            var chunk_size: usize = 18;
            for (ec.event.events) |ev| chunk_size += 6 + ev.data.len + ev.properties.len;
            if (group_size != 0 and group_size + chunk_size > max_evnc_uncompressed) {
                try groups.append(allocator, .{ .start = start_idx, .end = idx });
                start_idx = idx;
                group_size = 0;
            }
            group_size += chunk_size;
        }
        if (start_idx < events.items.len) {
            try groups.append(allocator, .{ .start = start_idx, .end = events.items.len });
        }

        const results = try allocator.alloc(CompressResult, groups.items.len);
        if (groups.items.len > 1) {
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{
                .allocator = allocator,
                .n_jobs = @min(groups.items.len, std.Thread.getCpuCount() catch 1),
            });
            defer pool.deinit();
            var wg = std.Thread.WaitGroup{};
            for (groups.items, results) |g, *out| {
                pool.spawnWg(&wg, compressOne, .{ events.items[g.start..g.end], algo, dict, gpa, out });
            }
            pool.waitAndWork(&wg);
        } else if (groups.items.len == 1) {
            compressOne(events.items, algo, dict, gpa, &results[0]);
        }
        for (results) |r| try chunks.append(allocator, .{ .evnc = try r });
    } else {
        try chunks.appendSlice(allocator, events.items);
    }

    // The output is strictly smaller than its inputs (SEVT framing and
    // per-file definitions collapse); the slack covers framing and defs.
    const size = try archive.writeArchive(allocator, output, chunks.items, total_size + 64 * 1024);

    try stdout.print("consolidated {d} file(s), {d} record(s)", .{ files.len, total_records });
    if (compression) |algo| try stdout.print(" ({t}-compressed)", .{algo});
    if (dict) |d| try stdout.print(" (dictionary {d} version {d})", .{ d.id, d.version });
    if (salvaged != 0) try stdout.print(" ({d} salvaged from torn chunks)", .{salvaged});
    try stdout.print(" -> {s} ({d} bytes)\n", .{ output, size });
}

/// All consolidated inputs must describe their events identically: same
/// HDRA, same driver table, same event type mappings.
fn expectSameDefs(reference: *const Inspection, insp: *const Inspection, path: []const u8) !void {
    const a = reference.header.?;
    const b = insp.header.?;
    const header_match = a.version == b.version and
        a.min_version == b.min_version and
        std.mem.eql(u8, &a.conf_by, &b.conf_by) and
        std.mem.eql(u8, a.client_name, b.client_name) and
        a.client_version == b.client_version and
        a.min_client_version == b.min_client_version;
    if (!header_match) {
        std.log.err("{s}: HDRA differs from the first input's", .{path});
        return error.DefinitionMismatch;
    }

    if (reference.drivers.len != insp.drivers.len) {
        std.log.err("{s}: driver table differs from the first input's", .{path});
        return error.DefinitionMismatch;
    }
    for (reference.drivers, insp.drivers, 0..) |rd, id, i| {
        if (!std.mem.eql(u8, rd.name, id.name) or !std.mem.eql(u8, rd.type, id.type)) {
            std.log.err("{s}: driver {d} differs from the first input's", .{ path, i });
            return error.DefinitionMismatch;
        }
    }

    if (reference.etyps.items.len != insp.etyps.items.len) {
        std.log.err("{s}: event type set differs from the first input's", .{path});
        return error.DefinitionMismatch;
    }
    for (reference.etyps.items, insp.etyps.items) |re, ie| {
        var match = re.driver_id == ie.driver_id and re.mappings.len == ie.mappings.len;
        if (match) for (re.mappings, ie.mappings) |rm, im| {
            if (rm.value != im.value or !std.mem.eql(u8, rm.identifier, im.identifier)) {
                match = false;
                break;
            }
        };
        if (!match) {
            std.log.err("{s}: event types for driver {d} differ from the first input's", .{ path, ie.driver_id });
            return error.DefinitionMismatch;
        }
    }

    if (reference.dicts.items.len != insp.dicts.items.len) {
        std.log.err("{s}: dictionary set differs from the first input's", .{path});
        return error.DefinitionMismatch;
    }
    for (reference.dicts.items, insp.dicts.items) |rd, id| {
        if (rd.id != id.id or rd.version != id.version or rd.algorithm != id.algorithm or
            !std.mem.eql(u8, rd.dictionary, id.dictionary))
        {
            std.log.err("{s}: dictionary {d} differs from the first input's", .{ path, id.id });
            return error.DefinitionMismatch;
        }
    }

    if (reference.rophs.items.len != insp.rophs.items.len) {
        std.log.err("{s}: route op hash set differs from the first input's", .{path});
        return error.DefinitionMismatch;
    }
    for (reference.rophs.items, insp.rophs.items) |rr, ir| {
        var match = rr.driver_id == ir.driver_id and rr.mappings.len == ir.mappings.len;
        if (match) for (rr.mappings, ir.mappings) |rm, im| {
            if (rm.hash != im.hash or !std.mem.eql(u8, rm.identifier, im.identifier)) {
                match = false;
                break;
            }
        };
        if (!match) {
            std.log.err("{s}: route op hashes for driver {d} differ from the first input's", .{ path, ir.driver_id });
            return error.DefinitionMismatch;
        }
    }
}

/// Load a standalone dictionary file (produced by `kwev train`): exactly one
/// dictionary id must be present; the highest version of it wins.
fn loadDictFile(allocator: std.mem.Allocator, path: []const u8) !kwev.structures.Dict {
    const chunks = try archive.readChunks(allocator, path);
    var best: ?kwev.structures.Dict = null;
    for (chunks) |c| {
        switch (c) {
            .dict => |d| {
                if (best) |b| {
                    if (d.id != b.id) {
                        std.log.err("{s}: contains multiple dictionary ids ({d}, {d})", .{ path, b.id, d.id });
                        return error.AmbiguousDictionary;
                    }
                    if (d.version > b.version) best = d;
                } else {
                    best = d;
                }
            },
            else => {},
        }
    }
    return best orelse {
        std.log.err("{s}: contains no DICT chunk", .{path});
        return error.MissingDictionary;
    };
}

const CompressResult = anyerror!kwev.structures.Evnc;

/// Pool worker: compressed groups must come from the caller's thread-safe
/// allocator — the shared arena is not thread-safe.
fn compressOne(
    group: []const kwev.structures.ChunkData,
    algo: kwev.structures.CompressionType,
    dict: ?kwev.structures.Dict,
    gpa: std.mem.Allocator,
    out: *CompressResult,
) void {
    out.* = kwev.compress.compressChunks(
        gpa,
        group,
        algo,
        if (dict) |d| d.id else 0,
        if (dict) |d| d.version else 0,
        if (dict) |d| d.dictionary else null,
    );
}
