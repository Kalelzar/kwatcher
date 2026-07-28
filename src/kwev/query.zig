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

//! `kwev query` — every record belonging to one trace, pulled out of a set of
//! archives. Prints them inspect-style by default; `--out=` writes the
//! selection back out as a new archive instead.
//!
//! Matching is by trace identity, not by exact id: the 22 immutable bytes of
//! the correlation id are shared by every hop of a trace, so any id from the
//! trace selects the whole thing (see `CorrelationID.sameTrace`). That is what
//! makes a single id pulled off a log line or an AMQP header enough to
//! reconstruct a flow spanning several services.

const std = @import("std");

const core = @import("kw-core");
const kwev = @import("kw-kwev");

const archive = @import("archive.zig");
const consolidate = @import("consolidate.zig");
const inspection = @import("inspection.zig");
const Inspection = inspection.Inspection;

/// A matching record together with the inspection that can resolve its ids.
/// Inputs may come from different services with different driver tables, so a
/// record is only ever resolved against the file it was read from.
const Match = struct {
    record: kwev.structures.Event.EventData,
    insp: *const Inspection,
    source: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    id_text: []const u8,
    inputs: []const []const u8,
    output: ?[]const u8,
) !void {
    const target = core.correlation.CorrelationID.parse(id_text) orelse {
        try stderr.print(
            "query: '{s}' is not a correlation id (expected 64 hex characters)\n",
            .{id_text},
        );
        return error.BadArguments;
    };

    const files = try archive.collectInputs(allocator, inputs);

    var matches = std.ArrayList(Match){};
    var scanned: usize = 0;
    var uncorrelated: usize = 0;
    // Files that actually contributed a record — only these constrain the
    // output's definition set, so a query that happens to touch one service
    // still writes cleanly even when unrelated inputs disagree.
    var contributors = std.ArrayList(*const Inspection){};
    var contributor_paths = std.ArrayList([]const u8){};

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (files) |path| {
        const insp = try allocator.create(Inspection);
        insp.* = try inspection.loadValidated(allocator, gpa, path);

        var matched_here: usize = 0;
        for (insp.batches.items) |b| {
            for (b.records) |r| {
                scanned += 1;
                defer _ = scratch.reset(.retain_capacity);
                const cid = (try inspection.recordCid(scratch.allocator(), r.properties)) orelse {
                    uncorrelated += 1;
                    continue;
                };
                if (!target.sameTrace(cid)) continue;
                try matches.append(allocator, .{ .record = r, .insp = insp, .source = path });
                matched_here += 1;
            }
        }
        if (matched_here != 0) {
            try contributors.append(allocator, insp);
            try contributor_paths.append(allocator, path);
        }
    }

    if (matches.items.len == 0) {
        try stdout.print("no records for trace {f} in {d} file(s) ({d} record(s) scanned)\n", .{
            target, files.len, scanned,
        });
        if (uncorrelated != 0) {
            try stderr.print(
                "warning: {d} record(s) without a usable correlation id were skipped\n",
                .{uncorrelated},
            );
        }
        return;
    }

    if (uncorrelated != 0) {
        try stderr.print(
            "warning: {d} record(s) without a usable correlation id were skipped\n",
            .{uncorrelated},
        );
    }

    if (output) |out| {
        try write(allocator, stdout, target, matches.items, contributors.items, contributor_paths.items, out);
    } else {
        try render(stdout, target, matches.items, contributor_paths.items, scanned, files.len);
    }
}

/// Inspect-style listing of the selection, grouped by the file each record
/// came from so a cross-service trace reads as its per-service segments.
fn render(
    stdout: *std.Io.Writer,
    target: core.correlation.CorrelationID,
    matches: []const Match,
    sources: []const []const u8,
    scanned: usize,
    file_count: usize,
) !void {
    try stdout.print("Trace: {f}\n", .{target});
    try stdout.print("[QURY] {d} record(s) from {d} of {d} file(s) ({d} scanned)\n", .{
        matches.len, sources.len, file_count, scanned,
    });

    for (sources) |src| {
        var n: usize = 0;
        for (matches) |m| {
            if (std.mem.eql(u8, m.source, src)) n += 1;
        }
        try stdout.print("[FILE] {s} | {d} record(s)\n", .{ src, n });
        for (matches) |m| {
            if (!std.mem.eql(u8, m.source, src)) continue;
            // References were validated at load, but a record can still name
            // an event id its own file never declared (torn chunk, salvaged
            // tail) — print the raw id rather than crashing the query.
            if (m.insp.resolveEvent(m.record.event_id)) |res| {
                try stdout.print("[----] {s} ({d}) via ", .{ res.identifier, m.record.event_id });
                try printDriverLabel(m.insp, stdout, res.driver_id);
                try stdout.writeAll("\n");
            } else {
                try stdout.print("[----] <unresolved> ({d})\n", .{m.record.event_id});
            }
            try stdout.print("[    ] {s}\n", .{m.record.data});
            try stdout.print("[    ] {s}\n", .{m.record.properties});
        }
    }
}

/// Write the selection as a standalone archive. The definitions come from the
/// contributing files, which must agree: event ids are only meaningful
/// against the driver table that declared them, so records from services with
/// different tables cannot share one output.
fn write(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    target: core.correlation.CorrelationID,
    matches: []const Match,
    contributors: []const *const Inspection,
    contributor_paths: []const []const u8,
    output: []const u8,
) !void {
    const ref = contributors[0];
    for (contributors[1..], contributor_paths[1..]) |insp, path| {
        consolidate.expectSameDefs(ref, insp, path) catch |e| {
            std.log.err(
                "query: matching records span files with different definitions; " ++
                    "--out needs one definition set (query them separately, or " ++
                    "`consolidate` compatible inputs first)",
                .{},
            );
            return e;
        };
    }

    var chunks = std.ArrayList(kwev.structures.ChunkData){};
    try chunks.append(allocator, .{ .header_a = ref.header.? });
    try chunks.append(allocator, .{ .drivers = .{ .drivers = ref.drivers } });
    for (ref.etyps.items) |e| try chunks.append(allocator, .{ .event_type = e });
    for (ref.rophs.items) |r| try chunks.append(allocator, .{ .route_op_hash = r });
    // Records are stored uncompressed — a trace is a handful of records, and
    // an EVNC frame would cost more than it saves. That is also why no DICT
    // is carried: dictionaries only exist to expand EVNC chunks, and a
    // 100 KiB dictionary attached to a 6-record trace is pure weight.
    const records = try allocator.alloc(kwev.structures.Event.EventData, matches.len);
    var payload: usize = 0;
    for (matches, records) |m, *r| {
        r.* = m.record;
        payload += 6 + m.record.data.len + m.record.properties.len;
    }
    var rest: []const kwev.structures.Event.EventData = records;
    while (rest.len > 0) {
        const n = @min(rest.len, std.math.maxInt(u16));
        try chunks.append(allocator, .{ .event = .{ .events = rest[0..n] } });
        rest = rest[n..];
    }

    var defs: usize = 0;
    for (ref.etyps.items) |e| defs += 64 * e.mappings.len;
    for (ref.rophs.items) |r| defs += 64 * r.mappings.len;
    const size = try archive.writeArchive(allocator, output, chunks.items, payload + defs + 64 * 1024);

    try stdout.print("trace {f}: {d} record(s) from {d} file(s) -> {s} ({d} bytes)\n", .{
        target, matches.len, contributors.len, output, size,
    });
}

fn printDriverLabel(insp: *const Inspection, w: *std.Io.Writer, driver_id: u16) !void {
    if (insp.findDriver(driver_id)) |drv| {
        try w.print("{s}.{s} = {d}", .{ drv.type, drv.name, driver_id });
    } else {
        try w.print("<unknown driver {d}>", .{driver_id});
    }
}
