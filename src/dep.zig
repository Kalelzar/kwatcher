pub const std = @import("std");
pub const klib = @import("klib");

pub const DriverRegistry = @import("driver.zig").Drivers;

pub const shared = @import("utils/shared.zig");
pub const meta = @import("utils/meta.zig");

pub const Analyser = struct {
    const Node = struct {
        name: []const u8,
        source: []const u8,
        id: klib.meta.TypeId,
        to: [256]u8 = undefined,
        len: u8 = 0,
        provided: bool = false,

        pub fn isFulfilled(self: *const Node, g: *const Graph) bool {
            if (self.len == 0) return self.provided;
            for (0..self.len) |i| {
                const dep = self.to[i];
                const nod = g.nodes[dep];
                if (!nod.isFulfilled(g)) return false;
            }
            return true;
        }

        pub fn blame(self: *const Node, g: *const Graph) void {
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
                const nod = g.nodes[dep];
                if (!nod.isFulfilled(g)) {
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
                    nod.blame(g);
                }
            }
        }
    };

    const Graph = struct {
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

        pub fn isAvailable(self: *Graph, comptime T: type) bool {
            const tid = klib.meta.typeId(T);
            for (0..self.len) |i| {
                if (self.nodes[i].id == tid) return self.nodes[i].isFulfilled(self);
            }
            return false;
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

        pub fn fulfill(self: *Graph, other: *Graph) void {
            outer: for (0..other.len) |i| {
                if (i >= 255) @compileError("Overflow");
                const theirs = other.nodes[i];
                const og = self.len;
                if (og >= 255) @compileError("Overflow");
                for (0..og) |j| {
                    const ours = self.nodes[j];
                    if (ours.isFulfilled(self)) continue;
                    if (theirs.id == ours.id) {
                        self.nodes[j] = theirs;
                        continue :outer;
                    }
                }
                self.cloneInto(other, theirs, 0);
            }
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

        pub fn blame(self: *const Graph) void {
            for (0..self.len) |i| {
                const n = self.nodes[i];
                if (!n.isFulfilled(self)) {
                    n.blame(self);
                }
            }
        }

        pub fn isFulfilled(self: *const Graph) bool {
            for (0..self.len) |i| {
                const n = self.nodes[i];
                if (!n.isFulfilled(self)) {
                    if (@inComptime()) {
                        @compileError(std.fmt.comptimePrint(
                            "Graph({s}): Factory {s} cannot be fulfilled.",
                            .{ self.key, n.name },
                        ));
                    } else {
                        std.log.err(
                            "Graph({s}): Factory {s} cannot be fulfilled.",
                            .{ self.key, n.name },
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

const reserved_declarations_map = std.StaticStringMap(void).initComptime(.{
    .{"deconstruct"},
    .{"deinit"},
    .{"init"},
    .{"preconfigure"}, //FIXME: This does need to be checked
});

pub fn DCategory(
    comptime tag: anytype,
    comptime lifetime: anytype,
    comptime _ContextStack: []const type,
    comptime _Requirements: []const type,
) type {
    return struct {
        const Tag = tag;
        const Lifetime = lifetime;
        const ContextStack = _ContextStack;
        const Requirements = _Requirements;

        pub fn augment(comptime Context: type) type {
            return DCategory(
                Tag,
                Lifetime,
                shared.SetUnion(type, _ContextStack, &.{Context}),
                Requirements,
            );
        }

        pub fn requires(comptime Reqs: []const type) type {
            return DCategory(
                Tag,
                Lifetime,
                _ContextStack,
                shared.SetUnion(type, _Requirements, Reqs),
            );
        }
    };
}

pub fn DepMap(comptime _Categories: []const type, _Lifetime: type) type {
    return struct {
        const Lifetime = _Lifetime;
        const Categories = _Categories;
        const Ls = meta.arrayFromEnum(Lifetime);

        pub fn makeGraph() []const Analyser.Graph {
            const graphs = comptime blk: {
                var graphs: [Categories.len]Analyser.Graph = undefined;
                for (Categories, 0..) |C, i| {
                    const off = i % Ls.len;

                    var graph: Analyser.Graph = if (off > 0) graphs[i - 1] else Analyser.Graph{
                        .key = "",
                    };
                    graph.key = @tagName(C.Tag) ++ ":" ++ @tagName(C.Lifetime);

                    if (!std.mem.eql(u8, @tagName(C.Tag), "all")) {
                        for (C.ContextStack) |CS| {
                            Analyser.analyseInto(&graph, CS);
                            graph.detectCycles();
                        }

                        graph.requireAll(
                            C.Requirements,
                            @tagName(C.Tag) ++ ":" ++ @tagName(C.Lifetime),
                        );
                    }
                    graphs[i] = graph;
                }
                for (graphs) |G| {
                    G.blame();
                }
                break :blk graphs;
            };
            return &graphs;
        }

        pub fn find(comptime tag: anytype, comptime lifetime: Lifetime) ?struct { type, usize } {
            inline for (Categories, 0..) |Cs, i| {
                if (Cs.Tag == tag and Cs.Lifetime == lifetime) return .{ Cs, i };
            }
            return null;
        }

        pub fn cat(comptime tag: @Type(.enum_literal)) type {
            var res = Categories;
            for (Ls) |lifetime| {
                const Cat = find(tag, lifetime);
                if (Cat != null)
                    @compileError("Category '" ++ @tagName(tag) ++ "' already registered with lifetime '" ++ @tagName(lifetime) ++ "'.");
                res = res ++ .{DCategory(tag, lifetime, &.{}, &.{})};
            }
            return DepMap(res, Lifetime);
        }

        pub fn requires(comptime tag: anytype, comptime lifetime: Lifetime, comptime Reqs: []const type) type {
            if (std.mem.eql(u8, @tagName(tag), "all")) {
                return requiresAll(Reqs, lifetime);
            }

            const Cat = find(tag, lifetime);
            if (Cat == null) {
                @compileError("Category '" ++ @tagName(tag) ++ "' not registered with lifetime '" ++ "" ++ @tagName(lifetime) ++ "'.");
            }

            const ModCat = Cat.?.@"0".requires(Reqs);
            const NewCategories = shared.Mod(type, Cat.?.@"1", Categories, ModCat);
            return DepMap(NewCategories, Lifetime);
        }

        pub fn augment(comptime tag: anytype, comptime lifetime: Lifetime, comptime Context: type) type {
            //            @compileLog("Augment", tag, lifetime, Context);
            if (std.mem.eql(u8, @tagName(tag), "all")) {
                return augmentAll(Context, lifetime);
            }

            const Cat = find(tag, lifetime);
            if (Cat == null) {
                @compileError("Category '" ++ @tagName(tag) ++ "' not registered with lifetime '" ++ "" ++ @tagName(lifetime) ++ "'.");
            }

            const ModCat = Cat.?.@"0".augment(Context);
            const NewCategories = shared.Mod(type, Cat.?.@"1", Categories, ModCat);
            return DepMap(NewCategories, Lifetime);
        }

        fn requiresAll(comptime Reqs: []const type, comptime lifetime: Lifetime) type {
            const buf = comptime blk: {
                var buf: [Categories.len]type = undefined;
                for (Categories, 0..) |C, j| {
                    if (C.Lifetime == lifetime)
                        buf[j] = C.requires(Reqs)
                    else
                        buf[j] = C;
                }
                break :blk buf;
            };
            return DepMap(&buf, Lifetime);
        }

        fn augmentAll(comptime Context: type, comptime lifetime: Lifetime) type {
            const buf = comptime blk: {
                var buf: [Categories.len]type = undefined;
                for (Categories, 0..) |C, j| {
                    if (C.Lifetime == lifetime)
                        buf[j] = C.augment(Context)
                    else
                        buf[j] = C;
                }
                break :blk buf;
            };
            return DepMap(&buf, Lifetime);
        }
    };
}

const StaticBinder = struct {
    ptr: *anyopaque,
    tag: []const u8,
};

pub const Resolved = union(enum) {
    ctx: u8,
    static_ctx: u64,
    resolver: struct {
        ctx: u8,
        offset: usize,
    },
    static: struct {
        ctx: usize,
        offset: usize,
    },
    factory: struct {
        ctx: u8,
        fac: *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque,
    },
    static_factory: struct {
        ctx: usize,
        fac: *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque,
    },
};

pub const TidHashContext = struct {
    pub fn hash(self: @This(), key: klib.meta.TypeId) u32 {
        _ = self;
        const res: u32 = @truncate(@intFromPtr(key));
        return res;
    }

    pub fn eql(self: @This(), a: klib.meta.TypeId, b: klib.meta.TypeId) bool {
        _ = self;
        return a == b;
    }
};

pub const TidArrayHashContext = struct {
    pub fn hash(self: @This(), key: klib.meta.TypeId) u32 {
        _ = self;
        const res: u32 = @truncate(@intFromPtr(key));
        return res;
    }

    pub fn eql(self: @This(), a: klib.meta.TypeId, b: klib.meta.TypeId, _: usize) bool {
        _ = self;
        return a == b;
    }
};

pub const DepCtx = struct {
    parent: ?*DepCtx = null,
    cache: Cache,
    static: []StaticBinder,
    value: []*anyopaque,

    pub fn call_first(self: *DepCtx, comptime fun: anytype, extra_args: anytype) anyerror!klib.meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(klib.meta.Fn(@TypeOf(fun))).@"fn".params;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_args.len) |i| types[i] = @TypeOf(extra_args[i]);
            for (extra_args.len..params.len) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i >= extra_args.len) try self.require(@TypeOf(args[i])) else extra_args[i];

        return @call(.auto, fun, args);
    }

    pub fn require(self: *DepCtx, comptime T: type) !T {
        // std.log.info("Getting {s}.", .{@typeName(T)});
        if (T == *DepCtx) return self;
        const tid = comptime klib.meta.typeId(T);
        const res = self.cache.get(tid);
        if (res == null) {
            if (self.parent) |p| {
                return try p.require(T);
            } else {
                return error.DependencyNotFound;
            }
        }

        return switch (res.?) {
            .ctx => |c| {
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(self.value[c]));
                } else {
                    return @as(*T, @ptrCast(@alignCast(self.value[c]))).*;
                }
            },
            .static_ctx => |c| {
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(self.static[c].ptr));
                } else {
                    return @as(*T, @ptrCast(@alignCast(self.static[c].ptr))).*;
                }
            },
            .resolver => |r| {
                if (comptime klib.meta.isValuePointer(T)) {
                    const v: T = @ptrFromInt(@intFromPtr(self.value[r.ctx]) + r.offset);
                    // std.log.info("{x}: Found resolver(*) at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.value[r.ctx]),
                    //     r.offset,
                    //     r.ctx,
                    // });
                    return v;
                } else {
                    const v: *T = @ptrFromInt(@intFromPtr(self.value[r.ctx]) + r.offset);
                    // std.log.info("{x}: Found resolver at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.value[r.ctx]),
                    //     r.offset,
                    //     r.ctx,
                    // });
                    return v.*;
                }
            },
            .static => |s| {
                if (comptime klib.meta.isValuePointer(T)) {
                    const v: T = @ptrFromInt(@intFromPtr(self.static[s.ctx].ptr) + s.offset);
                    // std.log.info("{x}: Found static(*) at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.static[s.ctx].ptr),
                    //     s.offset,
                    //     s.ctx,
                    // });
                    return v;
                } else {
                    const v: *T = @ptrFromInt(@intFromPtr(self.static[s.ctx].ptr) + s.offset);
                    // std.log.info("{x}: Found static at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.static[s.ctx].ptr),
                    //     s.offset,
                    //     s.ctx,
                    // });
                    return v.*;
                }
            },
            .factory => |f| {
                //TODO: If a cache is present we need to return that instead.
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(try f.fac(self, null)));
                } else {
                    var val: T = undefined;
                    _ = try f.fac(self, @ptrCast(@alignCast(&val)));
                    return val;
                }
            },
            .static_factory => |f| {
                //TODO: If a cache is present we need to return that instead.
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(try f.fac(self, null)));
                } else {
                    var val: T = undefined;
                    _ = try f.fac(self, @ptrCast(@alignCast(&val)));
                    return val;
                }
            },
        };
    }
};

pub const Cache = std.ArrayHashMapUnmanaged(klib.meta.TypeId, Resolved, TidArrayHashContext, false);

pub fn DepHub(comptime DM: type, comptime Statics: anytype, comptime Config: type) type {
    return struct {
        pub const DependencyMap = DM;
        pub const StaticMap = Statics;

        statics: std.ArrayList(StaticBinder),

        fn fac(comptime T: type, fun: anytype) *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque {
            const H = struct {
                pub fn get(ctx: *DepCtx, receiver: ?*anyopaque) anyerror!*anyopaque {
                    var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                    inline for (args, 0..) |t, i| {
                        args[i] = try ctx.require(@TypeOf(t));
                    }

                    if (comptime !klib.meta.isValuePointer(T)) {
                        std.debug.assert(receiver != null);
                        const tr: *T = @ptrCast(@alignCast(receiver.?));
                        tr.* = if (comptime klib.meta.canBeError(fun)) try @call(.auto, fun, args) else @call(.auto, fun, args);
                        return receiver.?;
                    } else {
                        return @ptrCast(@alignCast(if (comptime klib.meta.canBeError(fun)) try @call(.auto, fun, args) else @call(.auto, fun, args)));
                    }
                }
            };

            return H.get;
        }

        pub fn compile(self: *@This(), comptime category: anytype, comptime lifetime: DM.Lifetime, allocator: std.mem.Allocator) !DepCtx {
            var nextCtx: u8 = 0;
            var ctx = DepCtx{
                .cache = .{},
                .value = &.{},
                .static = self.statics.items,
            };
            inline for (DependencyMap.Categories, 0..) |C, idx| {
                _ = idx;
                if (comptime !std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) or @intFromEnum(C.Lifetime) > @intFromEnum(lifetime)) continue;

                if (C.Lifetime != .static) {
                    inline for (C.ContextStack) |Ctx| {
                        defer nextCtx += 1;

                        try ctx.cache.put(
                            allocator,
                            klib.meta.typeId(*Ctx),
                            .{
                                .ctx = nextCtx,
                            },
                        );
                        inline for (std.meta.fields(Ctx)) |f| {
                            const ti = @typeInfo(f.type);
                            switch (ti) {
                                .optional => {},
                                else => {
                                    try ctx.cache.put(
                                        allocator,
                                        klib.meta.typeId(f.type),
                                        .{
                                            .resolver = .{
                                                .ctx = nextCtx,
                                                .offset = @offsetOf(Ctx, f.name),
                                            },
                                        },
                                    );
                                    if (!klib.meta.isValuePointer(f.type)) {
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*f.type),
                                            .{
                                                .resolver = .{
                                                    .ctx = nextCtx,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*const f.type),
                                            .{
                                                .resolver = .{
                                                    .ctx = nextCtx,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                    }
                                },
                            }
                        }

                        inline for (@typeInfo(Ctx).@"struct".decls) |f| {
                            const fun = @field(Ctx, f.name);
                            const RT = klib.meta.Result(fun);
                            if (comptime RT == void) continue;
                            try ctx.cache.put(
                                allocator,
                                klib.meta.typeId(RT),
                                .{
                                    .factory = .{
                                        .ctx = nextCtx,
                                        .fac = fac(RT, fun),
                                    },
                                },
                            );
                        }
                    }
                } else {
                    comptime var i: usize = 0;
                    inline for (C.ContextStack) |Ctx| {
                        if (comptime i >= Statics.len) break;
                        inline for (i..Statics.len) |j| {
                            const s = Statics[j];
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), "all")) break;
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), @tagName(C.Tag))) break;
                            i += 1;
                        }
                        i += 1;
                        // std.log.info("Found {s} at {d}.", .{ @typeName(Ctx), i });

                        try ctx.cache.put(
                            allocator,
                            klib.meta.typeId(*Ctx),
                            .{
                                .static_ctx = i - 1,
                            },
                        );

                        inline for (std.meta.fields(Ctx)) |f| {
                            const ti = @typeInfo(f.type);
                            switch (ti) {
                                .optional => {},
                                else => {
                                    try ctx.cache.put(
                                        allocator,
                                        klib.meta.typeId(f.type),
                                        .{
                                            .static = .{
                                                .ctx = i - 1,
                                                .offset = @offsetOf(Ctx, f.name),
                                            },
                                        },
                                    );

                                    if (!klib.meta.isValuePointer(f.type)) {
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*f.type),
                                            .{
                                                .static = .{
                                                    .ctx = i - 1,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*const f.type),
                                            .{
                                                .static = .{
                                                    .ctx = i,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                    }
                                },
                            }
                        }

                        inline for (@typeInfo(Ctx).@"struct".decls) |f| {
                            const fun = @field(Ctx, f.name);
                            const RT = klib.meta.Result(fun);
                            if (comptime RT == void) continue;
                            try ctx.cache.put(
                                allocator,
                                klib.meta.typeId(RT),
                                .{
                                    .static_factory = .{
                                        .ctx = i - 1,
                                        .fac = fac(RT, fun),
                                    },
                                },
                            );
                        }
                    }
                }
            }
            return ctx;
        }

        pub fn swap(comptime DMap: anytype) type {
            return DepHub(DMap, Static, Config);
        }

        pub fn become(self: @This(), comptime Other: type) Other {
            return .{
                .statics = self.statics,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (DM.Categories) |C| {
                if (comptime Statics.len == 0) break;
                if (comptime C.Lifetime == .static) out: {
                    var cont = self.compile(C.Tag, C.Lifetime, allocator) catch break :out;
                    self.prepare(&cont, C.Tag, C.Lifetime, allocator) catch break :out;
                    defer reset(&cont, C.Tag, C.Lifetime, allocator);
                    self.actualize(C.Tag, C.Lifetime, &cont) catch break :out;
                    defer deactualize(&cont, C.Tag, C.Lifetime);

                    const Rd = meta.reverse(C.ContextStack);
                    inline for (Rd) |Ctx| {
                        comptime var i: usize = 0;
                        if (comptime i >= Statics.len - 1) break;
                        inline for (0..Statics.len) |rj| {
                            const j = Statics.len - rj - 1;
                            const s = Statics[j];
                            //@compileLog(Ctx, "at", j, meta.Bare(s.@"1"), s.@"0", C.Tag);
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), @tagName(C.Tag))) {
                                if (comptime meta.Bare(s.@"1") == Ctx) {
                                    break;
                                }
                            }
                            i += 1;
                        }
                        if (comptime i > Statics.len - 1) {
                            continue;
                        }
                        const ri = Statics.len - i - 1;

                        const ctx: *Ctx = @ptrCast(@alignCast(self.statics.items[ri].ptr));
                        if (comptime @hasDecl(Ctx, "deconstruct")) blk: {
                            const fun = @field(Ctx, "deconstruct");
                            if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                            var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                            const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                            const n_deps = comptime fields.len;
                            if (n_deps < 1) {
                                @compileError("Deconstruct must accept self. Why else would you need it?");
                            }
                            args[0] = ctx;
                            inline for (1..n_deps) |j| {
                                args[j] = cont.require(@TypeOf(args[j])) catch @panic("Bad require");
                            }

                            @call(.auto, fun, args);
                        }
                    }
                }
            }

            self.statics.deinit(allocator);
        }

        pub fn new(
            comptime drivers: DriverRegistry,
        ) Drivers(drivers) {
            return .{ .statics = .{} };
        }

        pub fn verify() void {
            _ = DM.makeGraph();
        }

        pub fn static(
            self: @This(),
            comptime category: anytype,
            ctx: anytype,
            allocator: std.mem.Allocator,
        ) Static(category, @TypeOf(ctx)) {
            // std.log.info("Registering static (new) {s}: {s} {x}", .{ @typeName(@TypeOf(ctx)), @tagName(category), @intFromPtr(ctx) });
            var s = self.statics;
            s.append(allocator, .{
                .ptr = @ptrCast(@alignCast(ctx)),
                .tag = @tagName(category),
            }) catch unreachable; // YIKES!

            return .{ .statics = s };
        }

        pub fn staticAssumeRegistered(
            self: *@This(),
            comptime category: anytype,
            ctx: anytype,
            allocator: std.mem.Allocator,
        ) void {
            // std.log.info("Registering static {s}: {s} {x}", .{ @typeName(@TypeOf(ctx)), @tagName(category), @intFromPtr(ctx) });
            self.statics.append(allocator, .{
                .ptr = @ptrCast(@alignCast(ctx)),
                .tag = @tagName(category),
            }) catch unreachable; // YIKES!
        }

        pub fn deactualize(
            ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
        ) void {
            var handles: u64 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            const c: *Ctx = @ptrCast(@alignCast(ctx.value[handles]));
                            if (comptime @hasDecl(Ctx, "deconstruct")) blk: {
                                //FIXME: This needs to happen in inverse order! UB!
                                const fun = @field(Ctx, "deconstruct");
                                if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;
                                if (n_deps < 1) {
                                    @compileError("Deconstruct must accept self. Why else would you need it?");
                                }
                                args[0] = c;
                                inline for (1..n_deps) |j| {
                                    args[j] = ctx.require(@TypeOf(args[j])) catch unreachable;
                                }

                                @call(.auto, fun, args);
                            }
                            handles += 1;
                        }
                    } else {}
                }
            }
        }

        pub fn reset(
            ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            allocator: std.mem.Allocator,
        ) void {
            ctx.cache.deinit(allocator);
            var i: u64 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            defer i += 1;
                            allocator.destroy(@as(*Ctx, @ptrCast(@alignCast(ctx.value[i]))));
                        }
                    } else {}
                }
            }
            allocator.free(ctx.value);
        }

        /// Expand the current container with an extension.
        pub fn with(
            self: @This(),
            comptime category: anytype,
            comptime extension: type,
            allocator: std.mem.Allocator,
        ) extension.Return(category, Config, @This()) {
            return extension.apply(self, category, allocator, Config);
        }

        pub fn prepare(
            _: @This(),
            to_ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            allocator: std.mem.Allocator,
        ) !void {
            var handles: std.ArrayList(*anyopaque) = .{};
            try handles.ensureUnusedCapacity(allocator, 1);
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        try handles.ensureUnusedCapacity(allocator, C.ContextStack.len);
                        inline for (C.ContextStack) |Ctx| {
                            const ctx = try allocator.create(Ctx);
                            handles.appendAssumeCapacity(@ptrCast(@alignCast(ctx)));
                            // std.log.info("={d}=> {s} {x}", .{ handles.items.len - 1, @typeName(Ctx), @intFromPtr(ctx) });
                        }
                    } else {}
                }
            }

            to_ctx.value = try handles.toOwnedSlice(allocator);
        }

        pub fn actualize(
            _: @This(),
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            ctx: *DepCtx,
        ) !void {
            var nextCtx: u8 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            const v: *Ctx = @ptrCast(@alignCast(ctx.value[nextCtx]));
                            v.* = std.mem.zeroInit(Ctx, .{});
                            if (comptime @hasDecl(Ctx, "construct")) blk: {
                                const fun = @field(Ctx, "construct");
                                if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;
                                if (n_deps < 1) {
                                    @compileError("Construct must accept self. Why else would you need it?");
                                }
                                args[0] = v;
                                inline for (1..n_deps) |i| {
                                    args[i] = try ctx.require(@TypeOf(args[i]));
                                }

                                switch (comptime @typeInfo(klib.meta.Return(fun))) {
                                    .error_union => try @call(.auto, fun, args),
                                    else => @call(.auto, fun, args),
                                }
                            }
                            nextCtx += 1;
                        }
                    }
                }
            }
        }

        pub fn scoped(self: @This(), comptime category: anytype, comptime T: type) Scoped(category, T) {
            return .{ .statics = self.statics };
        }

        pub fn Scoped(comptime category: anytype, comptime T: type) type {
            return DepHub(DM.augment(category, .scoped, T), Statics, Config);
        }

        pub fn Static(comptime category: anytype, comptime T: type) type {
            const ti = @typeInfo(T);
            if (ti != .pointer) @compileError("Expected context to be a pointer.");
            return DepHub(
                DM.augment(category, .static, ti.pointer.child),
                Statics ++ .{.{ category, T }},
                Config,
            );
        }

        fn Drivers(comptime drivers: DriverRegistry) type {
            var N = DM;
            inline for (drivers.drivers) |D| {
                N = N.cat(D.key);
                N = N.requires(D.key, .scoped, D.Dependencies);
            }
            return DepHub(N, Statics, Config);
        }
    };
}

pub const DependencyLifetimes = enum { static, scoped };

pub fn DependencyContainer(comptime Config: type) type {
    return DepHub(DepMap(&.{}, DependencyLifetimes).cat(.all), .{}, Config);
}
