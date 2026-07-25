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

//! `kwev dump` — raw per-chunk listing; stays lenient on broken input.

const std = @import("std");

const kwev = @import("kw-kwev");

const archive = @import("archive.zig");

pub fn run(allocator: std.mem.Allocator, stdout: *std.Io.Writer, file: []const u8) !void {
    const chunks = try archive.readChunks(allocator, file);
    var dicts = std.ArrayList(kwev.structures.Dict){};
    for (chunks, 0..) |c, i| {
        try stdout.print("[{d:04}] {t} | ", .{ i, std.meta.activeTag(c) });
        switch (c) {
            .header_a => |h| {
                try stdout.print("version {d} (min {d}), configured by {s}\n", .{
                    h.version,
                    h.min_version,
                    h.conf_by,
                });
                try stdout.print("[CLNT] {s} version {d} (min {d})\n", .{
                    h.client_name,
                    h.client_version,
                    h.min_client_version,
                });
            },
            .drivers => |d| {
                try stdout.print("{d} driver(s)\n", .{d.drivers.len});
                for (d.drivers, 0..) |drv, id| {
                    try stdout.print("[{d:04}] {s} ({s})\n", .{ id, drv.name, drv.type });
                }
            },
            .event_type => |e| {
                try stdout.print("{d} mapping(s) for driver {d}\n", .{ e.mappings.len, e.driver_id });
                for (e.mappings) |m| {
                    try stdout.print("[{d:04}] {s}\n", .{ m.value, m.identifier });
                }
            },
            .route_op_hash => |r| {
                try stdout.print("{d} route op hash(es) for driver {d}\n", .{ r.mappings.len, r.driver_id });
                for (r.mappings) |m| {
                    try stdout.print("[{x:0>8}] {s}\n", .{ m.hash, m.identifier });
                }
            },
            .dict => |d| {
                try dicts.append(allocator, d);
                try stdout.print("dictionary {d} version {d}: {t}, {d} byte(s)\n", .{
                    d.id, d.version, d.algorithm, d.dictionary.len,
                });
            },
            .evnc => |e| {
                try stdout.print("{t}, dictionary {d} version {d}, {d} -> {d} byte(s)\n", .{
                    e.compression,
                    e.dictionary_id,
                    e.dictionary_version,
                    e.compressed_data.len,
                    e.uncompressed_size,
                });
                const dict: ?[]const u8 = blk: {
                    if (e.dictionary_id == 0) break :blk null;
                    for (dicts.items) |d| {
                        if (d.id == e.dictionary_id and
                            (e.dictionary_version == 0 or d.version == e.dictionary_version))
                            break :blk d.dictionary;
                    }
                    break :blk null;
                };
                const inner = kwev.compress.expandEvnc(allocator, e, dict) catch |err| {
                    try stdout.print("[????] cannot expand: {t}\n", .{err});
                    continue;
                };
                for (inner) |ic| {
                    try stdout.print("[EVNT] {d} event(s)\n", .{ic.event.events.len});
                    try dumpRecords(stdout, ic.event.events);
                }
            },
            .link => |l| {
                try switch (l) {
                    inline .rel, .abs, .http => |value, tag| stdout.print("{t}: {s}\n", .{ tag, value }),
                    .jump => |value| stdout.print("jump to {s} at {d}\n", .{ value.name, value.offset }),
                };
                // EVNC expansion below needs linked dictionaries; pull DICT
                // chunks out of resolvable link targets (best effort — dump
                // stays lenient).
                const target: ?[]const u8 = switch (l) {
                    .abs => |abs| abs,
                    .rel => |rel| try archive.resolveRelative(allocator, file, rel),
                    else => null,
                };
                if (target) |t| {
                    if (archive.readChunks(allocator, t)) |linked| {
                        for (linked) |lc| {
                            if (lc == .dict) try dicts.append(allocator, lc.dict);
                        }
                    } else |_| {}
                }
            },
            .event => |e| {
                try stdout.print("{d} event(s)\n", .{e.events.len});
                try dumpRecords(stdout, e.events);
            },
            .streamed_event => |e| {
                try stdout.print("{s}\n", .{if (e.sealed) "SEALED" else "CORRUPT"});
                try dumpRecords(stdout, e.records);
            },
            .eof => try stdout.writeAll("end of file\n"),
        }
    }
}

fn dumpRecords(stdout: *std.Io.Writer, records: []const kwev.structures.Event.EventData) !void {
    for (records) |r| {
        try stdout.print("[----] ---{d}---\n", .{r.event_id});
        try stdout.print("[DATA] {s}\n", .{r.data});
        try stdout.print("[META] {s}\n", .{r.properties});
    }
}
