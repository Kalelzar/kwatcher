//! `kwev inspect` — load into an Inspection (links resolved), validate, then
//! bulk-print. Strict by design: missing HDRA or dangling references are hard
//! errors; jump/http links are merely "skipped" notes.

const std = @import("std");

const kwev = @import("kw-kwev");

const inspection = @import("inspection.zig");
const Inspection = inspection.Inspection;

pub fn run(allocator: std.mem.Allocator, stdout: *std.Io.Writer, file: []const u8) !void {
    var insp = Inspection{};
    try inspection.load(allocator, &insp, file, true, 4);
    try inspection.validateRefs(&insp, file);
    const header = insp.header.?;

    try stdout.print("File: {s}\n", .{file});
    for (insp.sources.items) |s| try stdout.print("[DEFS] {s}\n", .{s});
    for (insp.skipped.items) |s| try stdout.print("[DEFS] skipped {s}\n", .{s});
    for (insp.notes.items) |n| try stdout.print("[NOTE] {s}\n", .{n});
    try stdout.print("[HDRA] client \"{s}\" version {d} (min {d}) | spec {d} (min {d}), configured by {s}\n", .{
        header.client_name,
        header.client_version,
        header.min_client_version,
        header.version,
        header.min_version,
        header.conf_by,
    });

    for (insp.dicts.items) |d| {
        try stdout.print("[DICT] {d} version {d}: {t}, {d} byte(s)\n", .{
            d.id, d.version, d.algorithm, d.dictionary.len,
        });
    }
    try stdout.print("[DRVS] {d} driver(s)\n", .{insp.drivers.len});
    for (0..insp.drivers.len) |id| {
        var seen = false;
        for (insp.etyps.items) |etyp| {
            if (etyp.driver_id != id) continue;
            seen = true;
            try printMappings(&insp, stdout, etyp);
        }
        if (!seen) {
            try stdout.writeAll("[----] 0 mapping(s) for driver ");
            try printDriverLabel(&insp, stdout, @intCast(id));
            try stdout.writeAll("\n");
        }
        for (insp.rophs.items) |roph| {
            if (roph.driver_id != id) continue;
            try stdout.writeAll("[ROPH] ");
            try printDriverLabel(&insp, stdout, @intCast(id));
            try stdout.writeAll("\n");
            for (roph.mappings) |m| {
                try stdout.print("[    ] {s} = {x:0>8}\n", .{ m.identifier, m.hash });
            }
        }
    }

    var total: usize = 0;
    for (insp.batches.items) |b| total += b.records.len;
    try stdout.print("[EVTS] {d} record(s) in {d} chunk(s)\n", .{ total, insp.batches.items.len });
    for (insp.batches.items) |b| {
        if (b.streamed) {
            try stdout.print("[SEVT] {s} | {d} record(s)\n", .{
                if (b.sealed) "SEALED" else "CORRUPT",
                b.records.len,
            });
        } else {
            try stdout.print("[EVNT] {d} record(s)\n", .{b.records.len});
        }
        for (b.records) |r| {
            const res = insp.resolveEvent(r.event_id).?;
            try stdout.print("[----] {s} ({d}) via ", .{ res.identifier, r.event_id });
            try printDriverLabel(&insp, stdout, res.driver_id);
            try stdout.writeAll("\n");
            try stdout.print("[    ] {s}\n", .{r.data});
            try stdout.print("[    ] {s}\n", .{r.properties});
        }
    }
}

fn printDriverLabel(insp: *const Inspection, w: *std.Io.Writer, driver_id: u16) !void {
    // References are validated before printing starts.
    const drv = insp.findDriver(driver_id).?;
    try w.print("{s}.{s} = {d}", .{ drv.type, drv.name, driver_id });
}

fn printMappings(insp: *const Inspection, stdout: *std.Io.Writer, etyp: kwev.structures.EventType) !void {
    try stdout.print("[----] ", .{});
    try printDriverLabel(insp, stdout, etyp.driver_id);
    try stdout.writeAll("\n");
    for (etyp.mappings) |m| {
        try stdout.print("[    ] {s} = {d}\n", .{ m.identifier, m.value });
    }
}
