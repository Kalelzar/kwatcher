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

//! `kwev graph` — aggregated operation trees: correlation ids parsed back out
//! of the zon-encoded properties, records grouped by trace identity, parent
//! spans matched WITHIN a trace (24-bit spans collide across traces), one dot
//! subgraph per observed root_op_id.

const std = @import("std");

const core = @import("kw-core");
const kwev = @import("kw-kwev");

const archive = @import("archive.zig");
const inspection = @import("inspection.zig");
const Inspection = inspection.Inspection;

pub fn run(
    allocator: std.mem.Allocator,
    // Everything per-record fans out on thread pools; big containers use
    // the real (thread-safe) allocator: at millions of records, arena'd
    // growth (no-op frees on every resize) retained gigabytes.
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
) !void {
    const files = try archive.collectInputs(allocator, inputs);

    // Load every input (EVNC groups already expand in parallel inside
    // loadValidated) and flatten its batches into extraction tasks.
    var op_names = std.AutoHashMap(u32, []const u8).init(allocator);
    var tasks = std.ArrayList(ExtractTask){};
    var total_records: usize = 0;
    for (files) |path| {
        const insp = try allocator.create(Inspection);
        insp.* = try inspection.loadValidated(allocator, gpa, path);
        // Identical by construction where inputs overlap; last write wins.
        for (insp.rophs.items) |roph| {
            for (roph.mappings) |m| {
                try op_names.put(m.hash, m.identifier);
            }
        }
        for (insp.batches.items) |b| {
            if (b.records.len == 0) continue;
            try tasks.append(allocator, .{ .records = b.records, .insp = insp, .gpa = gpa, .out = undefined });
            total_records += b.records.len;
        }
    }

    // Extract correlation ids in parallel: every task fills its own disjoint
    // range of one preallocated array (skipped records leave a gap at the
    // range tail; `len` marks the used prefix).
    const slots = try gpa.alloc(GraphItem, total_records);
    defer gpa.free(slots);
    {
        var offset: usize = 0;
        for (tasks.items) |*t| {
            t.out = slots[offset..][0..t.records.len];
            offset += t.records.len;
        }
    }
    try forEachParallel(allocator, ExtractTask, tasks.items, extractTask);

    var uncorrelated: usize = 0;
    var extracted: usize = 0;
    for (tasks.items) |t| {
        if (t.err) |e| return e;
        uncorrelated += t.uncorrelated;
        extracted += t.len;
    }

    // Scatter into trace-identity shards: a trace never spans shards, so
    // each shard can sort and aggregate independently (parent matching
    // stays trace-scoped). Cursors are prefix-summed from the per-task
    // shard counts, so all writes land in disjoint slots.
    const sharded = try gpa.alloc(GraphItem, extracted);
    defer gpa.free(sharded);
    var shard_totals: [shard_count]usize = [_]usize{0} ** shard_count;
    for (tasks.items) |t| {
        for (t.shard_counts, 0..) |c, w| shard_totals[w] += c;
    }
    var shard_starts: [shard_count]usize = undefined;
    {
        var offset: usize = 0;
        for (shard_totals, 0..) |c, w| {
            shard_starts[w] = offset;
            offset += c;
        }
    }
    const scatters = try allocator.alloc(ScatterTask, tasks.items.len);
    var cursors = shard_starts;
    for (tasks.items, scatters) |t, *s| {
        s.* = .{ .src = t.out[0..t.len], .cursors = cursors, .dst = sharded };
        for (t.shard_counts, 0..) |c, w| cursors[w] += c;
    }
    try forEachParallel(allocator, ScatterTask, scatters, scatterTask);

    // Sort + aggregate each shard in parallel, then merge the per-shard
    // maps — they are tiny (distinct ops, not records), so the merge is
    // trivially cheap.
    var shards: [shard_count]ShardTask = undefined;
    for (&shards, shard_starts, shard_totals) |*st, start, total| {
        st.* = .{ .items = sharded[start..][0..total], .gpa = gpa };
    }
    try forEachParallel(allocator, ShardTask, &shards, shardTask);

    var agg = TraceAggregation{
        .nodes = std.AutoHashMap(NodeKey, NodeInfo).init(gpa),
        .edges = std.AutoHashMap(EdgeKey, usize).init(gpa),
    };
    defer agg.deinit();
    for (&shards) |*st| {
        if (st.err) |e| return e;
        var nit = st.agg.nodes.iterator();
        while (nit.next()) |kv| {
            const gop = try agg.nodes.getOrPut(kv.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = kv.value_ptr.*;
            } else {
                gop.value_ptr.count += kv.value_ptr.count;
            }
        }
        var eit = st.agg.edges.iterator();
        while (eit.next()) |kv| {
            const gop = try agg.edges.getOrPut(kv.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += kv.value_ptr.*;
        }
        agg.orphaned += st.agg.orphaned;
        agg.trace_count += st.agg.trace_count;
        st.agg.deinit();
    }

    const rendered = try renderDot(allocator, &op_names, &agg);
    try archive.writeAtomic(allocator, output, rendered.dot);

    if (uncorrelated != 0) {
        try stderr.print("warning: {d} record(s) without a usable correlation id were skipped\n", .{uncorrelated});
    }
    try stdout.print("graphed {d} file(s): {d} record(s), {d} trace(s), {d} operation tree(s)", .{
        files.len,
        total_records,
        agg.trace_count,
        rendered.root_count,
    });
    if (agg.orphaned != 0) try stdout.print(" ({d} orphaned record(s) hang off \"?\")", .{agg.orphaned});
    try stdout.print(" -> {s}\n", .{output});
}

/// Fixed shard fan-out for the sort/aggregate phase. More shards than cores
/// so a hot shard doesn't serialize the tail; cheap enough that small inputs
/// don't care (empty shards are free).
const shard_count = 64;

/// Shard by the immutable trace identity — entropy is random per trace, but
/// fold in the rest so degenerate ids still spread.
fn shardOf(cid: core.correlation.CorrelationID) usize {
    const mixed = cid.timestamp ^
        (@as(u64, cid.root_op_id) << 16) ^
        (@as(u64, cid.user_id) << 8) ^
        @as(u64, cid.entropy);
    return @intCast(mixed % shard_count);
}

/// Run `func(&tasks[i])` for every task, fanning out on a thread pool when
/// there is more than one. Workers must not touch the shared arena; they
/// report failure through their task's `err` field.
fn forEachParallel(
    allocator: std.mem.Allocator,
    comptime T: type,
    tasks: []T,
    comptime func: fn (*T) void,
) !void {
    if (tasks.len == 0) return;
    if (tasks.len == 1) return func(&tasks[0]);
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @min(tasks.len, std.Thread.getCpuCount() catch 1),
    });
    defer pool.deinit();
    var wg = std.Thread.WaitGroup{};
    for (tasks) |*t| pool.spawnWg(&wg, func, .{t});
    pool.waitAndWork(&wg);
}

const ExtractTask = struct {
    records: []const kwev.structures.Event.EventData,
    insp: *const Inspection,
    /// Thread-safe allocator backing this worker's zon-fallback scratch.
    gpa: std.mem.Allocator,
    /// This task's disjoint range of the shared slot array; extracted items
    /// are written compactly from the start.
    out: []GraphItem,
    len: usize = 0,
    shard_counts: [shard_count]u32 = [_]u32{0} ** shard_count,
    uncorrelated: usize = 0,
    err: ?anyerror = null,
};

fn extractTask(t: *ExtractTask) void {
    var scratch = std.heap.ArenaAllocator.init(t.gpa);
    defer scratch.deinit();
    for (t.records) |r| {
        const cid = parseCidFast(r.properties) orelse blk: {
            // Non-canonical properties (foreign writer, older format): pay
            // for a real zon parse.
            defer _ = scratch.reset(.retain_capacity);
            const source = scratch.allocator().dupeZ(u8, r.properties) catch |e| {
                t.err = e;
                return;
            };
            const props = std.zon.parse.fromSlice(core.event.Properties, scratch.allocator(), source, null, .{
                .ignore_unknown_fields = true,
            }) catch |e| switch (e) {
                error.ParseZon => {
                    t.uncorrelated += 1;
                    continue;
                },
                else => {
                    t.err = e;
                    return;
                },
            };
            break :blk props.correlation_id;
        };
        if (cid.isUnset()) {
            t.uncorrelated += 1;
            continue;
        }
        // loadValidated guarantees these resolve.
        const res = t.insp.resolveEvent(r.event_id).?;
        const drv = t.insp.findDriver(res.driver_id).?;
        t.out[t.len] = .{
            .cid = cid,
            .kind = drv.type,
            .key = drv.name,
            .event_name = res.identifier,
        };
        t.len += 1;
        t.shard_counts[shardOf(cid)] += 1;
    }
}

const ScatterTask = struct {
    src: []const GraphItem,
    /// Write cursor per shard; prefix-summed so tasks never collide even
    /// though `dst` is shared.
    cursors: [shard_count]usize,
    dst: []GraphItem,
};

fn scatterTask(t: *ScatterTask) void {
    for (t.src) |item| {
        const w = shardOf(item.cid);
        t.dst[t.cursors[w]] = item;
        t.cursors[w] += 1;
    }
}

const ShardTask = struct {
    items: []GraphItem,
    /// Thread-safe allocator for this shard's aggregation maps.
    gpa: std.mem.Allocator,
    agg: TraceAggregation = undefined,
    err: ?anyerror = null,
};

fn shardTask(t: *ShardTask) void {
    t.agg = aggregateTraces(t.gpa, t.items) catch |e| {
        t.err = e;
        return;
    };
}

/// Fast path for pulling the correlation id out of the canonical zon the
/// recorder writes (`.{.attempts=N,.correlation_id=.{.timestamp=...,...}}`):
/// a full zon parse per record dominates graph's runtime on large archives.
/// Anything unexpected returns null and the caller falls back to std.zon.
fn parseCidFast(props: []const u8) ?core.correlation.CorrelationID {
    const marker = ".correlation_id=.{";
    const start = (std.mem.indexOf(u8, props, marker) orelse return null) + marker.len;
    var cid: core.correlation.CorrelationID = .unset;
    var i = start;
    while (i < props.len) {
        if (props[i] != '.') return null;
        i += 1;
        const name_end = std.mem.indexOfScalarPos(u8, props, i, '=') orelse return null;
        const name = props[i..name_end];
        i = name_end + 1;
        var value_end = i;
        while (value_end < props.len and props[value_end] != ',' and props[value_end] != '}') {
            value_end += 1;
        }
        if (value_end == props.len) return null;
        const value = props[i..value_end];

        inline for (@typeInfo(core.correlation.CorrelationID).@"struct".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) {
                @field(cid, f.name) = std.fmt.parseInt(f.type, value, 10) catch return null;
            }
        }

        if (props[value_end] == '}') return cid;
        i = value_end + 1;
    }
    return null;
}

const GraphItem = struct {
    cid: core.correlation.CorrelationID,
    kind: []const u8,
    key: []const u8,
    event_name: []const u8,
};

/// Span ids are only 24 bits, so parent/child matching MUST be scoped to one
/// trace — items sort and group by the immutable trace identity (minus the
/// constant version/flags).
fn itemTraceLessThan(_: void, a: GraphItem, b: GraphItem) bool {
    if (a.cid.timestamp != b.cid.timestamp) return a.cid.timestamp < b.cid.timestamp;
    if (a.cid.root_op_id != b.cid.root_op_id) return a.cid.root_op_id < b.cid.root_op_id;
    if (a.cid.user_id != b.cid.user_id) return a.cid.user_id < b.cid.user_id;
    return a.cid.entropy < b.cid.entropy;
}

fn sameTraceKey(a: GraphItem, b: GraphItem) bool {
    return a.cid.timestamp == b.cid.timestamp and
        a.cid.root_op_id == b.cid.root_op_id and
        a.cid.user_id == b.cid.user_id and
        a.cid.entropy == b.cid.entropy;
}

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

const TraceAggregation = struct {
    nodes: std.AutoHashMap(NodeKey, NodeInfo),
    edges: std.AutoHashMap(EdgeKey, usize),
    orphaned: usize = 0,
    trace_count: usize = 0,

    fn deinit(self: *TraceAggregation) void {
        self.nodes.deinit();
        self.edges.deinit();
    }
};

/// Sort by trace identity and walk runs: traces are a handful of records
/// each, so parent lookup within a run is a trivial scan — no per-trace
/// containers, no giant trace map.
fn aggregateTraces(gpa: std.mem.Allocator, items: []GraphItem) !TraceAggregation {
    std.mem.sort(GraphItem, items, {}, itemTraceLessThan);

    var agg = TraceAggregation{
        .nodes = std.AutoHashMap(NodeKey, NodeInfo).init(gpa),
        .edges = std.AutoHashMap(EdgeKey, usize).init(gpa),
    };
    errdefer agg.deinit();

    var i: usize = 0;
    while (i < items.len) {
        var j = i + 1;
        while (j < items.len and sameTraceKey(items[i], items[j])) j += 1;
        const trace = items[i..j];
        agg.trace_count += 1;
        i = j;

        for (trace) |item| {
            const ngop = try agg.nodes.getOrPut(.{
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

            const parent_op: ?u32 = blk: {
                for (trace) |p| {
                    if (p.cid.span_id == item.cid.parent_span_id) break :blk p.cid.current_op_id;
                }
                break :blk null;
            };
            const ek: EdgeKey = if (parent_op) |op| .{
                .root_op = item.cid.root_op_id,
                .parent_op = op,
                .child_op = item.cid.current_op_id,
                .from_unknown = false,
            } else blk: {
                agg.orphaned += 1;
                break :blk .{
                    .root_op = item.cid.root_op_id,
                    .parent_op = 0,
                    .child_op = item.cid.current_op_id,
                    .from_unknown = true,
                };
            };
            const egop = try agg.edges.getOrPut(ek);
            if (!egop.found_existing) egop.value_ptr.* = 0;
            egop.value_ptr.* += 1;
        }
    }
    return agg;
}

const RenderedDot = struct {
    dot: []const u8,
    root_count: usize,
};

/// Deterministic output: sorted roots, nodes, edges.
fn renderDot(
    allocator: std.mem.Allocator,
    op_names: *const std.AutoHashMap(u32, []const u8),
    agg: *const TraceAggregation,
) !RenderedDot {
    var node_keys = std.ArrayList(NodeKey){};
    var nk_it = agg.nodes.keyIterator();
    while (nk_it.next()) |k| try node_keys.append(allocator, k.*);
    std.mem.sort(NodeKey, node_keys.items, {}, nodeKeyLessThan);

    var edge_keys = std.ArrayList(EdgeKey){};
    var ek_it = agg.edges.keyIterator();
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
            const info = agg.nodes.get(nk).?;
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
            const count = agg.edges.get(ek).?;
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

    return .{ .dot = out.written(), .root_count = root_ops.items.len };
}
