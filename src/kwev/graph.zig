//! `kwev graph` — aggregated operation trees: correlation ids parsed back out
//! of the zon-encoded properties, records grouped by trace identity, parent
//! spans matched WITHIN a trace (24-bit spans collide across traces), one dot
//! subgraph per observed root_op_id.

const std = @import("std");

const core = @import("kw-core");

const archive = @import("archive.zig");
const inspection = @import("inspection.zig");

pub fn run(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: []const u8,
    inputs: []const []const u8,
) !void {
    const files = try archive.collectInputs(allocator, inputs);

    // Collect every correlated record with its resolved label parts. The
    // correlation id is parsed back out of the zon-encoded properties.
    // Aggregation containers use a real allocator: at millions of records,
    // arena'd hashmap growth (no-op frees on every resize) and per-trace
    // maps retained gigabytes.
    const gpa = std.heap.smp_allocator;
    var items = std.ArrayList(GraphItem){};
    defer items.deinit(gpa);
    var op_names = std.AutoHashMap(u32, []const u8).init(allocator);
    var total_records: usize = 0;
    var uncorrelated: usize = 0;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    for (files) |path| {
        const insp = try inspection.loadValidated(allocator, path);
        // Identical by construction where inputs overlap; last write wins.
        for (insp.rophs.items) |roph| {
            for (roph.mappings) |m| {
                try op_names.put(m.hash, m.identifier);
            }
        }
        for (insp.batches.items) |b| {
            for (b.records) |r| {
                total_records += 1;
                const cid = parseCidFast(r.properties) orelse blk: {
                    // Non-canonical properties (foreign writer, older
                    // format): pay for a real zon parse.
                    defer _ = scratch.reset(.retain_capacity);
                    const source = try scratch.allocator().dupeZ(u8, r.properties);
                    const props = std.zon.parse.fromSlice(core.event.Properties, scratch.allocator(), source, null, .{
                        .ignore_unknown_fields = true,
                    }) catch |e| switch (e) {
                        error.ParseZon => {
                            uncorrelated += 1;
                            continue;
                        },
                        else => return e,
                    };
                    break :blk props.correlation_id;
                };
                if (cid.isUnset()) {
                    uncorrelated += 1;
                    continue;
                }
                // loadValidated guarantees these resolve.
                const res = insp.resolveEvent(r.event_id).?;
                const drv = insp.findDriver(res.driver_id).?;
                try items.append(gpa, .{
                    .cid = cid,
                    .kind = drv.type,
                    .key = drv.name,
                    .event_name = res.identifier,
                });
            }
        }
    }

    var agg = try aggregateTraces(gpa, items.items);
    defer agg.deinit();
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
