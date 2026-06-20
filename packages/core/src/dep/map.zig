const std = @import("std");
const shared = @import("../utils/shared.zig");
const meta = @import("../utils/meta.zig");
const Analyser = @import("analyser.zig").Analyser;

pub fn DCategory(
    comptime tag: anytype,
    comptime lifetime: anytype,
    comptime _ContextStack: []const type,
    comptime _Requirements: []const type,
) type {
    return struct {
        pub const Tag = tag;
        pub const Lifetime = lifetime;
        pub const ContextStack = _ContextStack;
        pub const Requirements = _Requirements;

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
        pub const Lifetime = _Lifetime;
        pub const Categories = _Categories;
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
            @setEvalBranchQuota(Categories.len * 500);
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

comptime {
    std.testing.refAllDecls(@This());
}
