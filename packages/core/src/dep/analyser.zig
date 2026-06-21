const std = @import("std");
const klib = @import("klib");
const DepCtx = @import("ctx.zig").DepCtx;

pub const Analyser = struct {
    const Node = struct {
        name: []const u8,
        source: []const u8,
        id: klib.meta.TypeId,
        to: [256]u8 = undefined,
        len: u8 = 0,
        provided: bool = false,
        fulfilled: ?bool = null,

        fn isFulfilledInner(self: *const Node, g: *Graph) bool {
            if (self.len == 0) return self.provided;
            for (0..self.len) |i| {
                const dep = self.to[i];
                if (!g.nodes[dep].isFulfilled(g)) return false;
            }
            return true;
        }

        pub fn isFulfilled(self: *Node, g: *Graph) bool {
            if (self.fulfilled) |f| return f;
            self.fulfilled = self.isFulfilledInner(g);
            return self.fulfilled.?;
        }

        pub fn blame(self: *Node, g: *Graph) void {
            if (self.len == 0) {
                if (!self.provided) {
                    if (@inComptime()) {
                        @compileLog(std.fmt.comptimePrint(
                            "Graph({s}): Unresolved static of type '{s}': from '{s}'\n",
                            .{ g.key, self.name, self.source },
                        ));
                    } else {
                        std.debug.print(
                            "Graph({s}): Unresolved static of type '{s}'\n",
                            .{ g.key, self.name },
                        );
                    }
                }
            }
            for (0..self.len) |i| {
                const dep = self.to[i];
                if (!g.nodes[dep].isFulfilled(g)) {
                    if (@inComptime()) {
                        @compileLog(std.fmt.comptimePrint(
                            "Graph({s}): Unresolved factory {s} of type '{s}'\n",
                            .{
                                g.key,
                                self.source,
                                self.name,
                            },
                        ));
                    } else {
                        std.debug.print(
                            "Graph({s}): Unresolved factory {s} of type '{s}'\n",
                            .{
                                g.key,
                                self.source,
                                self.name,
                            },
                        );
                    }
                    g.nodes[dep].blame(g);
                }
            }
        }
    };

    pub const Graph = struct {
        key: []const u8,
        nodes: [256]Node = undefined,
        len: u8 = 0,

        const CycleNode = struct {
            id: ?u8 = null,
            idx: u8,
            lowlink: ?u8 = null,
            on_stack: bool = false,
        };

        pub fn detectCycles(self: *Graph) void {
            var nodes: [256]CycleNode = undefined;
            const node_len = self.len;
            for (0..self.len) |i| {
                nodes[i] = .{
                    .idx = i,
                };
            }

            var stack: [256]*CycleNode = undefined;
            var stack_size: u8 = 0;
            var id: u8 = 0;

            for (0..node_len) |i| {
                if (nodes[i].id != null) continue;
                strongConnect(self, &nodes, &stack, &stack_size, &id, i);
            }
        }

        fn strongConnect(
            self: *Graph,
            nodes: [*]CycleNode,
            stack: [*]*CycleNode,
            stack_size: *u8,
            id: *u8,
            idx: u8,
        ) void {
            const v: *CycleNode = &nodes[idx];
            v.id = id.*;
            v.lowlink = id.*;
            id.* += 1;
            stack[stack_size.*] = v;
            v.on_stack = true;
            stack_size.* += 1;

            for (0..self.nodes[v.idx].len) |j| {
                const w: *CycleNode = &nodes[self.nodes[v.idx].to[j]];
                if (w.id == null) {
                    self.strongConnect(nodes, stack, stack_size, id, w.idx);
                    v.lowlink = @min(v.lowlink.?, w.lowlink.?);
                } else if (w.on_stack) {
                    v.lowlink = @min(v.lowlink.?, w.id.?);
                }
            }

            if (v.lowlink.? == v.id.?) {
                for (0..self.nodes[v.idx].len) |j| {
                    if (self.nodes[v.idx].to[j] == v.idx) {
                        @compileError(std.fmt.comptimePrint(
                            "Found self-cycle on {s}({s}).",
                            .{ self.nodes[v.idx].source, self.nodes[v.idx].name },
                        ));
                    }
                }

                var w = stack[stack_size.* - 1];
                stack_size.* -= 1;
                while (w.idx != v.idx) {
                    w.on_stack = false;
                    const ow = w;
                    w = stack[stack_size.* - 1];
                    stack_size.* -= 1;
                    const msg = std.fmt.comptimePrint(
                        "Found cycle from {s}({s}) to {s}({s}).",
                        .{
                            self.nodes[v.idx].source,
                            self.nodes[v.idx].name,
                            self.nodes[ow.idx].source,
                            self.nodes[ow.idx].name,
                        },
                    );
                    @compileError(msg);
                }
            }
        }

        pub fn indexOf(self: *Graph, comptime T: type) ?u8 {
            const tid = klib.meta.typeId(T);
            // std.log.info("Index of: {s}", .{@typeName(T)});
            for (0..self.len) |i| {
                // std.log.info("  [{d:03}] Trying {s}", .{ i, self.nodes[i].name });
                if (self.nodes[i].id == tid) {
                    // std.log.info("  [{d:03}] Found {s}", .{ i, self.nodes[i].name });
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn cloneInto(self: *Graph, other: *Graph, node: Node, depth: u8) void {
            if (self.len >= 255) {
                if (@inComptime()) {
                    @compileError("Oveflow on dependency graph buffer!");
                } else {
                    @panic("Oveflow on dependency graph buffer!");
                }
            }
            if (depth >= 20) {
                if (@inComptime()) {
                    @compileError("Max depth exceeded!");
                } else {
                    @panic("Max depth exceeded!");
                }
            }
            const target = self.len;
            self.nodes[self.len] = node;
            self.len += 1;
            deps: for (0..node.len) |j| {
                const their_dep = other.nodes[node.to[j]];
                var i: u8 = 0;
                while (i < self.len) : (i += 1) {
                    if (i == target) continue;
                    const ours = self.nodes[i];
                    if (ours.id == their_dep.id) {
                        self.nodes[target].to[j] = i;
                        continue :deps;
                    }
                }
                const dtarget = self.len;
                self.cloneInto(other, their_dep, depth + 1);
                self.nodes[target].to[j] = dtarget;
            }
        }

        pub fn blame(self: *Graph) void {
            for (0..self.len) |i| {
                if (!self.nodes[i].isFulfilled(self)) {
                    self.nodes[i].blame(self);
                }
            }
        }

        pub fn isFulfilled(self: *const Graph) bool {
            for (0..self.len) |i| {
                if (!self.nodes[i].isFulfilled(self)) {
                    if (@inComptime()) {
                        @compileError(std.fmt.comptimePrint(
                            "Graph({s}): Factory {s} cannot be fulfilled.",
                            .{ self.key, self.nodes[i].name },
                        ));
                    } else {
                        std.log.err(
                            "Graph({s}): Factory {s} cannot be fulfilled.",
                            .{ self.key, self.nodes[i].name },
                        );
                        return false;
                    }
                }
            }
            return true;
        }

        pub fn provides(comptime self: *Graph, n: Node) void {
            for (0..self.len) |i| {
                if (self.nodes[i].id == n.id) {
                    self.nodes[i].source = n.source;
                    self.nodes[i].provided = true;
                    return;
                }
            }
            if (comptime self.len == 255) @compileError("Exceeded maximum dependency graph size.");
            self.nodes[self.len] = n;
            self.nodes[self.len].provided = true;
            self.len += 1;
        }

        pub fn requires(comptime self: *Graph, n: Node) void {
            for (0..self.len) |i| {
                if (self.nodes[i].id == n.id) {
                    return;
                }
            }
            if (comptime self.len == 255) @compileError("Exceeded maximum dependency graph size.");
            self.nodes[self.len] = n;
            self.nodes[self.len].provided = false;
            self.len += 1;
        }

        pub fn requireAll(comptime self: *Graph, comptime Ts: []const type, comptime source: []const u8) void {
            inline for (Ts) |T| {
                self.requires(.{
                    .name = @typeName(T),
                    .id = klib.meta.typeId(T),
                    .source = source ++ ":req",
                });
            }
        }

        pub fn depends(comptime self: *Graph, of: klib.meta.TypeId, n: Node) void {
            var idx: ?u8 = null;
            for (0..self.len) |i| {
                if (self.nodes[i].id == n.id) {
                    if (idx) |j| {
                        self.nodes[j].to[self.nodes[j].len] = i;
                        self.nodes[j].len += 1;
                        return;
                    } else {
                        idx = i;
                    }
                }
                if (self.nodes[i].id == of) {
                    if (idx) |j| {
                        self.nodes[i].to[self.nodes[i].len] = j;
                        self.nodes[i].len += 1;
                        return;
                    } else {
                        idx = i;
                    }
                }
            }
            if (idx) |i| {
                if (comptime self.len >= 255) @compileError("Exceeded maximum dependency graph size.");
                if (comptime i >= 255) @compileError("Invalid index");
                if (comptime self.nodes[i].len >= 255) @compileError("Too many dependants!");
                self.nodes[self.len] = n;
                self.nodes[i].to[self.nodes[i].len] = self.len;
                self.nodes[i].len += 1;
                self.len += 1;
            } else {
                @compileError("Invalid depend call. Expected dependant type to already be in the graph");
            }
        }

        pub fn log(comptime g: *const Graph) void {
            @compileLog(g.key, g.len);
        }
    };

    pub fn analyse(comptime Ctx: type, comptime key: anytype) Graph {
        var g: Graph = .{
            .key = @tagName(key),
        };
        analyseInto(&g, Ctx);
        return g;
    }

    pub fn analyseInto(g: *Graph, comptime Ctx: type) void {
        comptime {
            @setEvalBranchQuota(1_000_000);
            const ti = @typeInfo(Ctx);

            if (ti != .@"struct") @compileError("You can only analyze the dependencies of structs");

            const sti = ti.@"struct";

            g.provides(.{
                .name = @typeName(*Ctx),
                .source = "self",
                .id = klib.meta.typeId(*Ctx),
            });

            g.provides(.{
                .name = @typeName(*DepCtx),
                .source = "depctx",
                .id = klib.meta.typeId(*DepCtx),
            });

            for (sti.fields) |f| {
                const fti = @typeInfo(f.type);
                switch (fti) {
                    .optional => continue,
                    .pointer => |p| {
                        _ = p;
                        // const isConst = p.is_const;
                        const t = f.type; //if (isConst) *p.child else f.type;
                        // const ct = if (isConst) f.type else *const p.child;
                        g.provides(.{
                            .name = @typeName(t),
                            .source = f.name,
                            .id = klib.meta.typeId(t),
                        });
                        // g.provides(.{
                        //     .name = @typeName(ct),
                        //     .source = f.name,
                        //     .id = klib.meta.typeId(ct),
                        // });
                        // g.provides(.{
                        //     .name = @typeName(p.child),
                        //     .source = f.name,
                        //     .id = klib.meta.typeId(p.child),
                        // });
                    },
                    else => {
                        g.provides(.{
                            .name = @typeName(f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(f.type),
                        });
                        g.provides(.{
                            .name = @typeName(*f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(*f.type),
                        });
                        g.provides(.{
                            .name = @typeName(*const f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(*const f.type),
                        });
                    },
                }
            }
            for (std.meta.declarations(Ctx)) |d| {
                if (reserved_declarations_map.has(d.name)) continue;
                const fun = @field(Ctx, d.name);
                const dsti = @typeInfo(@TypeOf(fun));
                switch (dsti) {
                    .@"fn" => |_| {
                        const fid = klib.meta.typeId(klib.meta.Result(fun));
                        g.provides(.{
                            .name = @typeName(klib.meta.Result(fun)),
                            .source = d.name,
                            .id = fid,
                        });
                        const args = std.meta.ArgsTuple(@TypeOf(fun));
                        for (std.meta.fields(args)) |a| {
                            g.depends(fid, .{
                                .name = @typeName(a.type),
                                .source = @typeName(Ctx) ++ ":" ++ d.name ++ ":" ++ a.name,
                                .id = klib.meta.typeId(a.type),
                            });
                        }
                    },
                    else => {},
                }
            }
        }
    }
};

pub const reserved_declarations_map = std.StaticStringMap(void).initComptime(.{
    .{"deinit"},
    .{"init"},
    .{"construct"},
    .{"deconstruct"},
});

comptime {
    std.testing.refAllDecls(@This());
    const Ctx = struct {
        i: i64,
        u: *u64,
        d: *const f64,

        pub fn f(ii: i64, uu: *u64, dd: *const f64) u128 {
            _ = ii;
            _ = uu;
            _ = dd;
        }
    };

    var G = Analyser.analyse(Ctx, .ctx);
    G.blame();
}
