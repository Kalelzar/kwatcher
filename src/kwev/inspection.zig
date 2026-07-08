//! Loading a kwev file (links resolved) into an `Inspection` and validating
//! its referential integrity — shared by every strict subcommand.

const std = @import("std");

const kwev = @import("kw-kwev");

const archive = @import("archive.zig");

pub const Inspection = struct {
    header: ?kwev.structures.HeaderA = null,
    /// From the single expected DRVS chunk (index = driver id); any further
    /// DRVS chunk is noted and ignored.
    drivers: []const kwev.structures.Drivers.Driver = &.{},
    etyps: std.ArrayList(kwev.structures.EventType) = .{},
    rophs: std.ArrayList(kwev.structures.RouteOpHash) = .{},
    dicts: std.ArrayList(kwev.structures.Dict) = .{},
    /// Events from the primary file only; linked files contribute
    /// definitions, not payloads.
    batches: std.ArrayList(Batch) = .{},
    /// Linked definition files that were loaded.
    sources: std.ArrayList([]const u8) = .{},
    /// Links that were not followed (unsupported kind, depth, read failure).
    skipped: std.ArrayList([]const u8) = .{},
    notes: std.ArrayList([]const u8) = .{},
    /// Total uncompressed bytes expanded out of EVNC chunks — output-size
    /// budgeting must count these on top of the input file sizes.
    expanded_bytes: usize = 0,

    pub const Batch = struct {
        records: []const kwev.structures.Event.EventData,
        streamed: bool,
        sealed: bool,
    };

    pub const ResolvedEvent = struct {
        driver_id: u16,
        identifier: []const u8,
    };

    pub fn findDriver(self: *const Inspection, driver_id: u16) ?kwev.structures.Drivers.Driver {
        if (driver_id < self.drivers.len) return self.drivers[driver_id];
        return null;
    }

    /// Dictionary for an EVNC reference; version 0 means "latest".
    pub fn findDict(self: *const Inspection, id: u16, version: u16) ?[]const u8 {
        var best: ?kwev.structures.Dict = null;
        for (self.dicts.items) |d| {
            if (d.id != id) continue;
            if (version != 0) {
                if (d.version == version) return d.dictionary;
                continue;
            }
            if (best == null or d.version > best.?.version) best = d;
        }
        return if (best) |b| b.dictionary else null;
    }

    /// Route operation hash (as carried in correlation ids) -> route id.
    pub fn resolveOp(self: *const Inspection, hash: u32) ?[]const u8 {
        for (self.rophs.items) |roph| {
            for (roph.mappings) |m| {
                if (m.hash == hash) return m.identifier;
            }
        }
        return null;
    }

    pub fn resolveEvent(self: *const Inspection, event_id: u16) ?ResolvedEvent {
        for (self.etyps.items) |etyp| {
            for (etyp.mappings) |m| {
                if (m.value == event_id) {
                    return .{ .driver_id = etyp.driver_id, .identifier = m.identifier };
                }
            }
        }
        return null;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    insp: *Inspection,
    path: []const u8,
    primary: bool,
    depth: u8,
) anyerror!void {
    // A missing or unreadable file is a hard error even for linked
    // definition files: without its definitions the events are opaque.
    const chunks = archive.readChunks(allocator, path) catch |e| {
        std.log.err("failed to read {s}: {t}", .{ path, e });
        return e;
    };
    if (!primary) try insp.sources.append(allocator, path);

    for (chunks) |c| {
        switch (c) {
            .header_a => |h| {
                if (insp.header == null) {
                    insp.header = h;
                } else {
                    try insp.notes.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "extra HDRA chunk in {s} ignored",
                        .{path},
                    ));
                }
            },
            .drivers => |d| {
                if (insp.drivers.len == 0) {
                    insp.drivers = d.drivers;
                } else {
                    try insp.notes.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "extra DRVS chunk in {s} ignored",
                        .{path},
                    ));
                }
            },
            .event_type => |e| try insp.etyps.append(allocator, e),
            .route_op_hash => |r| try insp.rophs.append(allocator, r),
            .dict => |d| try insp.dicts.append(allocator, d),
            .evnc => |e| if (primary) {
                const dict: ?[]const u8 = if (e.dictionary_id == 0)
                    null
                else
                    insp.findDict(e.dictionary_id, e.dictionary_version) orelse {
                        std.log.err("{s}: EVNC references unknown dictionary {d} (version {d})", .{
                            path, e.dictionary_id, e.dictionary_version,
                        });
                        return error.UnknownDictionary;
                    };
                insp.expanded_bytes += e.uncompressed_size;
                // Expansion yields EVNT chunks only (anything else errors).
                const inner = try kwev.compress.expandEvnc(allocator, e, dict);
                for (inner) |ic| {
                    try insp.batches.append(allocator, .{
                        .records = ic.event.events,
                        .streamed = false,
                        .sealed = true,
                    });
                }
            },
            .event => |e| if (primary) {
                try insp.batches.append(allocator, .{
                    .records = e.events,
                    .streamed = false,
                    .sealed = true,
                });
            },
            .streamed_event => |s| if (primary) {
                try insp.batches.append(allocator, .{
                    .records = s.records,
                    .streamed = true,
                    .sealed = s.sealed,
                });
            },
            .link => |l| switch (l) {
                .rel => |rel| try followLink(allocator, insp, try archive.resolveRelative(allocator, path, rel), depth),
                .abs => |abs| try followLink(allocator, insp, abs, depth),
                .jump => |j| try insp.skipped.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "jump to {s} at offset {d} (unsupported)",
                    .{ j.name, j.offset },
                )),
                .http => |url| try insp.skipped.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "http {s} (unsupported)",
                    .{url},
                )),
            },
            .eof => {},
        }
    }
}

fn followLink(allocator: std.mem.Allocator, insp: *Inspection, target: []const u8, depth: u8) anyerror!void {
    if (depth == 0) {
        std.log.err("link depth limit reached at {s} (link cycle?)", .{target});
        return error.TooManyLinks;
    }
    try load(allocator, insp, target, false, depth - 1);
}

/// Referential integrity every strict command demands: a HDRA must exist,
/// every ETYP/ROPH must reference a known driver, every event record a known
/// event type.
pub fn validateRefs(insp: *const Inspection, path: []const u8) !void {
    if (insp.header == null) {
        std.log.err("{s} has no HDRA header, not even via links", .{path});
        return error.MissingHeader;
    }
    for (insp.etyps.items) |etyp| {
        if (insp.findDriver(etyp.driver_id) == null) {
            std.log.err("{s}: ETYP chunk references unknown driver {d}", .{ path, etyp.driver_id });
            return error.UnknownDriver;
        }
    }
    for (insp.rophs.items) |roph| {
        if (insp.findDriver(roph.driver_id) == null) {
            std.log.err("{s}: ROPH chunk references unknown driver {d}", .{ path, roph.driver_id });
            return error.UnknownDriver;
        }
    }
    for (insp.batches.items) |b| {
        for (b.records) |r| {
            if (insp.resolveEvent(r.event_id) == null) {
                std.log.err("{s}: event references unknown event type {d}", .{ path, r.event_id });
                return error.UnknownEventType;
            }
        }
    }
}

/// Loads one input for consolidation: resolve links, sort the definition
/// chunks so definition comparison is chunk-order insensitive, and enforce
/// the same referential integrity `inspect` demands.
pub fn loadValidated(allocator: std.mem.Allocator, path: []const u8) !Inspection {
    var insp = Inspection{};
    try load(allocator, &insp, path, true, 4);
    std.mem.sort(kwev.structures.EventType, insp.etyps.items, {}, etypLessThan);
    std.mem.sort(kwev.structures.RouteOpHash, insp.rophs.items, {}, rophLessThan);
    std.mem.sort(kwev.structures.Dict, insp.dicts.items, {}, dictLessThan);
    try validateRefs(&insp, path);
    return insp;
}

fn etypLessThan(_: void, a: kwev.structures.EventType, b: kwev.structures.EventType) bool {
    return a.driver_id < b.driver_id;
}

fn rophLessThan(_: void, a: kwev.structures.RouteOpHash, b: kwev.structures.RouteOpHash) bool {
    return a.driver_id < b.driver_id;
}

fn dictLessThan(_: void, a: kwev.structures.Dict, b: kwev.structures.Dict) bool {
    if (a.id != b.id) return a.id < b.id;
    return a.version < b.version;
}
