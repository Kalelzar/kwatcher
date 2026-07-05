const std = @import("std");
const builtin = @import("builtin");

const kwev = @import("kw-kwev");
const core = @import("kw-core");

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
    } else if (std.mem.eql(u8, command, "consolidate")) {
        var inputs = std.ArrayList([]const u8){};
        while (arg_it.next()) |arg| {
            try inputs.append(arena.allocator(), arg);
        }
        if (inputs.items.len == 0) return usage(stderr);
        try consolidate(arena.allocator(), stdout, stderr, file, inputs.items);
    } else if (std.mem.eql(u8, command, "graph")) {
        var inputs = std.ArrayList([]const u8){};
        while (arg_it.next()) |arg| {
            try inputs.append(arena.allocator(), arg);
        }
        if (inputs.items.len == 0) return usage(stderr);
        try graph(arena.allocator(), stdout, stderr, file, inputs.items);
    } else {
        return usage(stderr);
    }
}

fn usage(stderr: *std.Io.Writer) error{BadArguments} {
    stderr.print(
        \\Usage: kwev <dump|inspect> <filepath>
        \\       kwev consolidate <output> <input...>
        \\       kwev graph <output.dot> <input...>
        \\
    , .{}) catch {};
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
            .route_op_hash => |r| {
                try stdout.print("{d} route op hash(es) for driver {d}\n", .{ r.mappings.len, r.driver_id });
                for (r.mappings) |m| {
                    try stdout.print("[{x:0>8}] {s}\n", .{ m.hash, m.identifier });
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
    rophs: std.ArrayList(kwev.structures.RouteOpHash) = .{},
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

    /// Route operation hash (as carried in correlation ids) -> route id.
    fn resolveOp(self: *const Inspection, hash: u32) ?[]const u8 {
        for (self.rophs.items) |roph| {
            for (roph.mappings) |m| {
                if (m.hash == hash) return m.identifier;
            }
        }
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
            .route_op_hash => |r| try insp.rophs.append(allocator, r),
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

fn printMappings(insp: *const Inspection, stdout: *std.Io.Writer, etyp: kwev.structures.EventType) !void {
    try stdout.print("[----] ", .{});
    try printDriverLabel(insp, stdout, etyp.driver_id);
    try stdout.writeAll("\n");
    for (etyp.mappings) |m| {
        try stdout.print("[    ] {s} = {d}\n", .{ m.identifier, m.value });
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn etypLessThan(_: void, a: kwev.structures.EventType, b: kwev.structures.EventType) bool {
    return a.driver_id < b.driver_id;
}

fn rophLessThan(_: void, a: kwev.structures.RouteOpHash, b: kwev.structures.RouteOpHash) bool {
    return a.driver_id < b.driver_id;
}

/// Loads one input for consolidation: resolve links, sort the event type
/// chunks so definition comparison is chunk-order insensitive, and enforce
/// the same referential integrity `inspect` demands.
fn loadValidated(allocator: std.mem.Allocator, path: []const u8) !Inspection {
    var insp = Inspection{};
    try load(allocator, &insp, path, true, 4);

    if (insp.header == null) {
        std.log.err("{s} has no HDRA header, not even via links", .{path});
        return error.MissingHeader;
    }
    std.mem.sort(kwev.structures.EventType, insp.etyps.items, {}, etypLessThan);
    for (insp.etyps.items) |etyp| {
        if (insp.findDriver(etyp.driver_id) == null) {
            std.log.err("{s}: ETYP chunk references unknown driver {d}", .{ path, etyp.driver_id });
            return error.UnknownDriver;
        }
    }
    std.mem.sort(kwev.structures.RouteOpHash, insp.rophs.items, {}, rophLessThan);
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
    return insp;
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

/// Expand files/directories into a flat input list. Directories are scanned
/// (non-recursively) for .kwev/.kwev.part files, sorted by name (run stamps
/// are fixed-width milliseconds, so name order = run order). Inputs are not
/// deduplicated.
fn collectInputs(allocator: std.mem.Allocator, inputs: []const []const u8) ![]const []const u8 {
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

fn consolidate(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
) !void {
    const files = try collectInputs(allocator, inputs);

    var reference: ?Inspection = null;
    var chunks = std.ArrayList(kwev.structures.ChunkData){};
    var events = std.ArrayList(kwev.structures.ChunkData){};
    var total_size: usize = 0;
    var total_records: usize = 0;
    var salvaged: usize = 0;

    for (files) |path| {
        total_size += (try std.fs.cwd().statFile(path)).size;
        const insp = try loadValidated(allocator, path);
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
    try chunks.appendSlice(allocator, events.items);

    // The output is strictly smaller than its inputs (SEVT framing and
    // per-file definitions collapse); the slack covers framing and defs.
    const buf = try allocator.alloc(u8, total_size + 64 * 1024);
    var w = std.Io.Writer.fixed(buf);
    var writer = kwev.Writer{ .writer = &w };
    const size = try writer.writeAll(chunks.items);

    // Stage as .part and rename so the output name only ever holds a
    // complete file.
    const part = try std.fmt.allocPrint(allocator, "{s}.part", .{output});
    try std.fs.cwd().writeFile(.{ .sub_path = part, .data = buf[0..size] });
    try std.fs.cwd().rename(part, output);

    try stdout.print("consolidated {d} file(s), {d} record(s)", .{ files.len, total_records });
    if (salvaged != 0) try stdout.print(" ({d} salvaged from torn chunks)", .{salvaged});
    try stdout.print(" -> {s} ({d} bytes)\n", .{ output, size });
}

const GraphItem = struct {
    cid: core.correlation.CorrelationID,
    kind: []const u8,
    key: []const u8,
    event_name: []const u8,
};

/// The immutable trace identity (minus constant version/flags): span ids are
/// only 24 bits, so parent/child matching MUST be scoped to one trace.
const TraceKey = struct {
    timestamp: u64,
    root_op: u32,
    user: u32,
    entropy: u32,
};

const NodeKey = struct {
    root_op: u32,
    op: u32,
};

const NodeInfo = struct {
    count: usize = 0,
    kind: []const u8 = "",
    key: []const u8 = "",
    event_name: []const u8 = "",
};

const EdgeKey = struct {
    root_op: u32,
    parent_op: u32,
    child_op: u32,
    /// The parent span was not found in the inputs (recorded by another
    /// service, lost, etc.) — the edge hangs off the dashed "?" node.
    from_unknown: bool,
};

fn nodeKeyLessThan(_: void, a: NodeKey, b: NodeKey) bool {
    if (a.root_op != b.root_op) return a.root_op < b.root_op;
    return a.op < b.op;
}

fn edgeKeyLessThan(_: void, a: EdgeKey, b: EdgeKey) bool {
    if (a.root_op != b.root_op) return a.root_op < b.root_op;
    if (a.from_unknown != b.from_unknown) return !a.from_unknown;
    if (a.parent_op != b.parent_op) return a.parent_op < b.parent_op;
    return a.child_op < b.child_op;
}

fn graph(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
) !void {
    const files = try collectInputs(allocator, inputs);

    // Collect every correlated record with its resolved label parts. The
    // correlation id is parsed back out of the zon-encoded properties.
    var items = std.ArrayList(GraphItem){};
    var op_names = std.AutoHashMap(u32, []const u8).init(allocator);
    var total_records: usize = 0;
    var uncorrelated: usize = 0;

    for (files) |path| {
        const insp = try loadValidated(allocator, path);
        // Identical by construction where inputs overlap; last write wins.
        for (insp.rophs.items) |roph| {
            for (roph.mappings) |m| {
                try op_names.put(m.hash, m.identifier);
            }
        }
        for (insp.batches.items) |b| {
            for (b.records) |r| {
                total_records += 1;
                const source = try allocator.dupeZ(u8, r.properties);
                const props = std.zon.parse.fromSlice(core.event.Properties, allocator, source, null, .{
                    .ignore_unknown_fields = true,
                }) catch |e| switch (e) {
                    error.ParseZon => {
                        uncorrelated += 1;
                        continue;
                    },
                    else => return e,
                };
                if (props.correlation_id.isUnset()) {
                    uncorrelated += 1;
                    continue;
                }
                // loadValidated guarantees these resolve.
                const res = insp.resolveEvent(r.event_id).?;
                const drv = insp.findDriver(res.driver_id).?;
                try items.append(allocator, .{
                    .cid = props.correlation_id,
                    .kind = drv.type,
                    .key = drv.name,
                    .event_name = res.identifier,
                });
            }
        }
    }

    // Group into traces, then walk each trace's span chain to aggregate
    // per-root-operation node and edge counts.
    var traces = std.AutoHashMap(TraceKey, std.ArrayList(usize)).init(allocator);
    for (items.items, 0..) |item, i| {
        const gop = try traces.getOrPut(.{
            .timestamp = item.cid.timestamp,
            .root_op = item.cid.root_op_id,
            .user = item.cid.user_id,
            .entropy = item.cid.entropy,
        });
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(allocator, i);
    }

    var nodes = std.AutoHashMap(NodeKey, NodeInfo).init(allocator);
    var edges = std.AutoHashMap(EdgeKey, usize).init(allocator);
    var orphaned: usize = 0;

    var trace_it = traces.valueIterator();
    while (trace_it.next()) |trace| {
        var spans = std.AutoHashMap(u24, usize).init(allocator);
        defer spans.deinit();
        for (trace.items) |i| {
            try spans.put(items.items[i].cid.span_id, i);
        }

        for (trace.items) |i| {
            const item = items.items[i];
            const ngop = try nodes.getOrPut(.{
                .root_op = item.cid.root_op_id,
                .op = item.cid.current_op_id,
            });
            if (!ngop.found_existing) {
                ngop.value_ptr.* = .{
                    .kind = item.kind,
                    .key = item.key,
                    .event_name = item.event_name,
                };
            }
            ngop.value_ptr.count += 1;

            // A root invocation has no incoming edge.
            if (item.cid.parent_span_id == 0) continue;

            const ek: EdgeKey = if (spans.get(item.cid.parent_span_id)) |pi| .{
                .root_op = item.cid.root_op_id,
                .parent_op = items.items[pi].cid.current_op_id,
                .child_op = item.cid.current_op_id,
                .from_unknown = false,
            } else blk: {
                orphaned += 1;
                break :blk .{
                    .root_op = item.cid.root_op_id,
                    .parent_op = 0,
                    .child_op = item.cid.current_op_id,
                    .from_unknown = true,
                };
            };
            const egop = try edges.getOrPut(ek);
            if (!egop.found_existing) egop.value_ptr.* = 0;
            egop.value_ptr.* += 1;
        }
    }

    // Deterministic output: sorted roots, nodes, edges.
    var node_keys = std.ArrayList(NodeKey){};
    var nk_it = nodes.keyIterator();
    while (nk_it.next()) |k| try node_keys.append(allocator, k.*);
    std.mem.sort(NodeKey, node_keys.items, {}, nodeKeyLessThan);

    var edge_keys = std.ArrayList(EdgeKey){};
    var ek_it = edges.keyIterator();
    while (ek_it.next()) |k| try edge_keys.append(allocator, k.*);
    std.mem.sort(EdgeKey, edge_keys.items, {}, edgeKeyLessThan);

    var root_ops = std.ArrayList(u32){};
    for (node_keys.items) |k| {
        if (root_ops.items.len == 0 or root_ops.items[root_ops.items.len - 1] != k.root_op) {
            try root_ops.append(allocator, k.root_op);
        }
    }

    var out = std.Io.Writer.Allocating.init(allocator);
    const w = &out.writer;
    try w.writeAll("digraph kwev {\n    rankdir=LR;\n    node [shape=box];\n");
    for (root_ops.items) |root| {
        try w.print("    subgraph \"cluster_{x:0>8}\" {{\n", .{root});
        if (op_names.get(root)) |name| {
            try w.print("        label=\"root {s}\";\n", .{name});
        } else {
            try w.print("        label=\"root {x:0>8}\";\n", .{root});
        }

        var has_unknown = false;
        for (edge_keys.items) |ek| {
            if (ek.root_op == root and ek.from_unknown) has_unknown = true;
        }
        if (has_unknown) {
            try w.print("        \"{x:0>8}/unknown\" [label=\"?\", style=dashed];\n", .{root});
        }

        for (node_keys.items) |nk| {
            if (nk.root_op != root) continue;
            const info = nodes.get(nk).?;
            try w.print("        \"{x:0>8}/{x:0>8}\" [label=\"{s}.{s}.{s}.", .{
                root,
                nk.op,
                info.kind,
                info.key,
                info.event_name,
            });
            if (op_names.get(nk.op)) |name| {
                try w.print("{s}", .{name});
            } else {
                try w.print("{x:0>8}", .{nk.op});
            }
            try w.print("\\n{d}x\"];\n", .{info.count});
        }

        for (edge_keys.items) |ek| {
            if (ek.root_op != root) continue;
            const count = edges.get(ek).?;
            if (ek.from_unknown) {
                try w.print("        \"{x:0>8}/unknown\" -> \"{x:0>8}/{x:0>8}\" [label=\"{d}x\"];\n", .{
                    root, root, ek.child_op, count,
                });
            } else {
                try w.print("        \"{x:0>8}/{x:0>8}\" -> \"{x:0>8}/{x:0>8}\" [label=\"{d}x\"];\n", .{
                    root, ek.parent_op, root, ek.child_op, count,
                });
            }
        }

        try w.writeAll("    }\n");
    }
    try w.writeAll("}\n");

    // Stage as .part and rename so the output name only ever holds a
    // complete file.
    const part = try std.fmt.allocPrint(allocator, "{s}.part", .{output});
    try std.fs.cwd().writeFile(.{ .sub_path = part, .data = out.written() });
    try std.fs.cwd().rename(part, output);

    if (uncorrelated != 0) {
        try stderr.print("warning: {d} record(s) without a usable correlation id were skipped\n", .{uncorrelated});
    }
    try stdout.print("graphed {d} file(s): {d} record(s), {d} trace(s), {d} operation tree(s)", .{
        files.len,
        total_records,
        traces.count(),
        root_ops.items.len,
    });
    if (orphaned != 0) try stdout.print(" ({d} orphaned record(s) hang off \"?\")", .{orphaned});
    try stdout.print(" -> {s}\n", .{output});
}
