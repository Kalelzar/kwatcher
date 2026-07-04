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

    const command = arg_it.next() orelse return usage(stderr);
    const file = arg_it.next() orelse return usage(stderr);

    if (std.mem.eql(u8, command, "dump")) {
        try dump(arena.allocator(), stdout, file);
    } else if (std.mem.eql(u8, command, "inspect")) {
        try inspect(arena.allocator(), stdout, file);
    } else {
        return usage(stderr);
    }
}

fn usage(stderr: *std.Io.Writer) error{BadArguments} {
    stderr.print("Usage: kwev <dump|inspect> <filepath>\n", .{}) catch {};
    return error.BadArguments;
}

fn readChunks(allocator: std.mem.Allocator, path: []const u8) ![]const kwev.structures.ChunkData {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    var fixed = std.Io.Reader.fixed(data);
    var reader = kwev.Reader{ .reader = &fixed };
    return reader.readAll(allocator);
}

fn dump(allocator: std.mem.Allocator, stdout: *std.Io.Writer, file: []const u8) !void {
    const chunks = try readChunks(allocator, file);
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
            .link => |l| {
                try switch (l) {
                    inline .rel, .abs, .http => |value, tag| stdout.print("{t}: {s}\n", .{ tag, value }),
                    .jump => |value| stdout.print("jump to {s} at {d}\n", .{ value.name, value.offset }),
                };
            },
            .event => |e| {
                try stdout.print("{d} event(s)\n", .{e.events.len});
                for (e.events) |r| {
                    try stdout.print("[----] ---{d}---\n", .{
                        r.event_id,
                    });
                    try stdout.print("[DATA] {s}\n", .{r.data});
                    try stdout.print("[META] {s}\n", .{r.properties});
                }
            },
            .streamed_event => |e| {
                try stdout.print("{s}\n", .{if (e.sealed) "SEALED" else "CORRUPT"});
                for (e.records) |r| {
                    try stdout.print("[----] ---{d}---\n", .{
                        r.event_id,
                    });
                    try stdout.print("[DATA] {s}\n", .{r.data});
                    try stdout.print("[META] {s}\n", .{r.properties});
                }
            },
            .eof => try stdout.writeAll("end of file\n"),
        }
    }
}

const Inspection = struct {
    header: ?kwev.structures.HeaderA = null,
    /// From the single expected DRVS chunk (index = driver id); any further
    /// DRVS chunk is noted and ignored.
    drivers: []const kwev.structures.Drivers.Driver = &.{},
    etyps: std.ArrayList(kwev.structures.EventType) = .{},
    /// Events from the primary file only; linked files contribute
    /// definitions, not payloads.
    batches: std.ArrayList(Batch) = .{},
    /// Linked definition files that were loaded.
    sources: std.ArrayList([]const u8) = .{},
    /// Links that were not followed (unsupported kind, depth, read failure).
    skipped: std.ArrayList([]const u8) = .{},
    notes: std.ArrayList([]const u8) = .{},

    const Batch = struct {
        records: []const kwev.structures.Event.EventData,
        streamed: bool,
        sealed: bool,
    };

    const ResolvedEvent = struct {
        driver_id: u16,
        identifier: []const u8,
    };

    fn findDriver(self: *const Inspection, driver_id: u16) ?kwev.structures.Drivers.Driver {
        if (driver_id < self.drivers.len) return self.drivers[driver_id];
        return null;
    }

    fn resolveEvent(self: *const Inspection, event_id: u16) ?ResolvedEvent {
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

fn load(
    allocator: std.mem.Allocator,
    insp: *Inspection,
    path: []const u8,
    primary: bool,
    depth: u8,
) anyerror!void {
    // A missing or unreadable file is a hard error even for linked
    // definition files: without its definitions the events are opaque.
    const chunks = readChunks(allocator, path) catch |e| {
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
                .rel => |rel| {
                    // Relative to the linking file, per spec.
                    const dir = std.fs.path.dirname(path) orelse "";
                    const target = if (dir.len == 0)
                        rel
                    else
                        try std.fs.path.join(allocator, &.{ dir, rel });
                    try followLink(allocator, insp, target, depth);
                },
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

fn printDriverLabel(insp: *const Inspection, w: *std.Io.Writer, driver_id: u16) !void {
    // References are validated before printing starts.
    const drv = insp.findDriver(driver_id).?;
    try w.print("{s}.{s} = {d}", .{ drv.type, drv.name, driver_id });
}

fn inspect(allocator: std.mem.Allocator, stdout: *std.Io.Writer, file: []const u8) !void {
    var insp = Inspection{};
    try load(allocator, &insp, file, true, 4);

    // A file is unreadable without a HDRA, whether its own or linked.
    const header = insp.header orelse {
        std.log.err("{s} has no HDRA header, not even via links", .{file});
        return error.MissingHeader;
    };

    // Anything referenced must resolve: every ETYP to a known driver,
    // every event record to a known event type.
    for (insp.etyps.items) |etyp| {
        if (insp.findDriver(etyp.driver_id) == null) {
            std.log.err("ETYP chunk references unknown driver {d}", .{etyp.driver_id});
            return error.UnknownDriver;
        }
    }
    for (insp.batches.items) |b| {
        for (b.records) |r| {
            if (insp.resolveEvent(r.event_id) == null) {
                std.log.err("event references unknown event type {d}", .{r.event_id});
                return error.UnknownEventType;
            }
        }
    }

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

fn printMappings(insp: *const Inspection, stdout: *std.Io.Writer, etyp: kwev.structures.EventType) !void {
    try stdout.print("[----] ", .{});
    try printDriverLabel(insp, stdout, etyp.driver_id);
    try stdout.writeAll("\n");
    for (etyp.mappings) |m| {
        try stdout.print("[    ] {s} = {d}\n", .{ m.identifier, m.value });
    }
}
