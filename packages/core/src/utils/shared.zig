const std = @import("std");
const meta = @import("meta.zig");
const klib = @import("klib");

const dep = @import("../dep.zig");

const InternFmtCache = @import("intern_fmt_cache.zig");
const resolver = @import("resolver.zig");
const arc = @import("arc.zig");

pub const DriverOptions = union(enum) {
    key: @Type(.enum_literal),
    config_path: []const u8,
    listen: bool,
    jobs: comptime_int,
    routes: []const type,
    error_handler: type,
};

pub fn DriverBuilder(comptime Driver: anytype, comptime requires_config: bool) type {
    const Opts = DriverOptions;
    return struct {
        opts: []Opts,
        const Self = @This();

        fn extend(comptime self: Self, comptime other: Opts) Self {
            comptime {
                const opts = blk: {
                    var opts: [self.opts.len + 1]Opts = undefined;
                    for (self.opts, 0..) |o, i| {
                        opts[i] = o;
                    }
                    opts[self.opts.len] = other;
                    break :blk opts;
                };
                return .{
                    .opts = @constCast(&opts),
                };
            }
        }

        pub fn new(comptime key: @Type(.enum_literal)) Self {
            const opts = blk: {
                var opts: [1]Opts = .{
                    .{ .key = key },
                };
                break :blk &opts;
            };

            return comptime .{ .opts = opts };
        }

        pub fn config(comptime self: Self, comptime config_path: []const u8) Self {
            return self.extend(.{ .config_path = config_path });
        }

        pub fn listen(comptime self: Self, comptime v: bool) Self {
            return self.extend(.{ .listen = v });
        }

        pub fn jobs(comptime self: Self, comptime v: comptime_int) Self {
            return self.extend(.{ .jobs = v });
        }

        pub fn routes(comptime self: Self, comptime v: []const type) Self {
            return self.extend(.{ .routes = v });
        }

        pub fn error_handler(comptime self: Self, comptime v: type) Self {
            return self.extend(.{ .error_handler = v });
        }

        pub fn build(comptime self: Self) *const fn (comptime u12) type {
            var has_key = false;
            var k: @Type(.enum_literal) = .none;
            var config_path: []const u8 = "";
            var has_config = false;
            var j: comptime_int = 0;
            var ltn = false;
            var rts: []const type = &.{};
            var eh: type = void;

            comptime {
                for (self.opts) |opts| {
                    switch (opts) {
                        .key => |kk| {
                            has_key = true;
                            k = kk;
                        },
                        .config_path => |c| {
                            has_config = true;
                            config_path = c;
                        },
                        .listen => |l| ltn = l,
                        .jobs => |jb| j = jb,
                        .routes => |r| rts = rts ++ r,
                        .error_handler => |e| eh = e,
                    }
                }

                if (!has_key) {
                    @compileError("A driver always needs a key!");
                }

                if (has_config != requires_config) {
                    if (requires_config) {
                        @compileError("A driver requires a config.");
                    } else {
                        @compileError("A driver does not require a config.");
                    }
                }

                if (ltn and j <= 0) {
                    @compileError("Cannot listen with 0 or less jobs.");
                }

                if (j >= 1 and !ltn) {
                    @compileError("Cannot have 1 or more jobs if not listening");
                }

                if (rts.len == 0) {
                    //                    @compileError("No routes");
                }

                if (requires_config) {
                    return Driver(k, config_path, ltn, j, rts, eh);
                } else {
                    return Driver(k, ltn, j, rts, eh);
                }
            }
        }
    };
}

pub fn EnumerateRoutes(comptime Routes: []const type) type {
    var defs: [Routes.len]std.builtin.Type.EnumField = undefined;

    var i: u64 = 0;

    inline for (Routes) |R| {
        defer i += 1;
        const name: [:0]const u8 = @ptrCast(R.id ++ .{0});
        defs[i] = .{
            .value = i,
            .name = name,
        };
    }

    return @Type(.{
        .@"enum" = .{
            .decls = &.{},
            .fields = &defs,
            .is_exhaustive = true,
            .tag_type = meta.UIntShrink(i),
        },
    });
}

pub fn UniteCallContext(comptime Routes: []const type) type {
    const E = EnumerateRoutes(Routes);
    var defs: [Routes.len]std.builtin.Type.UnionField = undefined;

    var i: u64 = 0;

    inline for (Routes) |R| {
        defer i += 1;
        const name: [:0]const u8 = @ptrCast(R.id ++ .{0});
        defs[i] = .{
            .name = name,
            .type = R.CallContext,
            .alignment = @alignOf(R.CallContext),
        };
    }

    return @Type(.{
        .@"union" = .{
            .decls = &.{},
            .fields = &defs,
            .layout = .auto,
            .tag_type = E,
        },
    });
}

pub fn Mod(comptime T: type, comptime i: usize, comptime As: []const T, comptime B: T) []const T {
    const buf = comptime blk: {
        var buf: [As.len]T = undefined;
        for (As, 0..) |A, j| {
            buf[j] = if (i == j) B else A;
        }
        break :blk buf;
    };
    return &buf;
}

pub fn SetUnion(comptime T: type, comptime As: []const T, comptime Bs: []const T) []const T {
    @setEvalBranchQuota((As.len + Bs.len) * 300);
    var len: usize = 0;
    const buf = comptime blk: {
        var buf: [As.len + Bs.len]T = undefined;
        for (As, 0..) |A, i| {
            buf[i] = A;
            len += 1;
        }
        outer: for (Bs) |B| {
            for (0..len) |j| {
                if (buf[j] == B) continue :outer;
            }
            buf[len] = B;
            len += 1;
        }
        break :blk buf;
    };

    return buf[0..len];
}

pub fn SetUnionEql(comptime T: type, comptime As: anytype, comptime Bs: anytype, comptime EqlCtx: type) []const T {
    @setEvalBranchQuota((As.len + Bs.len) * 200);
    var len: usize = 0;
    const buf = comptime blk: {
        var buf: [As.len + Bs.len]T = undefined;
        for (As, 0..) |A, i| {
            buf[i] = A;
            len += 1;
        }
        outer: for (Bs) |B| {
            for (0..len) |j| {
                if (EqlCtx.eql(buf[j], B)) continue :outer;
            }
            buf[len] = B;
            len += 1;
        }
        break :blk buf;
    };

    return buf[0..len];
}

pub fn MergeDeps(comptime Routes: []const type, comptime extra: []const type) []const type {
    var len: usize = 0;
    const buf = comptime blk: {
        var buf: [8192]type = undefined;
        for (Routes) |R| {
            deps: for (R.Dependencies) |D| {
                for (0..len) |i| {
                    if (buf[i] == D) continue :deps;
                }
                buf[len] = D;
                len += 1;
            }
        }
        deps: for (extra) |D| {
            for (0..len) |i| {
                if (buf[i] == D) continue :deps;
            }
            buf[len] = D;
            len += 1;
        }

        break :blk buf;
    };

    return buf[0..len];
}

pub fn RouteMap(comptime Routes: []const type) std.StaticStringMap(EnumerateRoutes(Routes)) {
    const E = EnumerateRoutes(Routes);
    const kvs = comptime blk: {
        var kvs: [Routes.len]struct { []const u8, E } = undefined;
        for (Routes, 0..) |R, i| {
            kvs[i] = .{ R.id, @field(E, R.id) };
        }
        break :blk &kvs;
    };
    return .initComptime(kvs);
}

/// Encodes a dynamic template that is free-standing.
/// i.e the value can be safely replaced because nothing is depending on it.
pub fn FreeTemplate(
    comptime Context: type,
    comptime key: []const u8,
    comptime fmt: []const u8,
    comptime params: []const []const u8,
) type {
    const Resolver = resolver.Resolver(Context);
    const types = comptime blk: {
        var types: [params.len]type = undefined;
        for (0..params.len) |i| {
            types[i] = Resolver.resolveType(params[i]);
        }

        break :blk &types;
    };

    const ArgType = std.meta.Tuple(types);

    return struct {
        pub const TemplateType = .free;
        pub fn get(_: @This(), inj: *dep.DepCtx) ![]const u8 {
            const cache = try inj.require(*InternFmtCache);
            const ctx = try inj.require(*Context);

            var args: ArgType = undefined;
            inline for (0..params.len) |i| {
                args[i] = try Resolver.resolve(inj, params[i], ctx);
            }

            const lease = try cache.internFmtWithLease(key, fmt, args);
            defer if (lease.old) |o| lease.allocator.?.free(o);

            return lease.new;
        }
    };
}

/// Encodes a dynamic template that is linked to another template.
/// i.e the value is stored in another route.
pub fn LinkedTemplate(
    comptime key: []const u8,
) type {
    return struct {
        pub const TemplateType = .linked;
        pub fn get(_: @This(), _: *dep.DepCtx) ![]const u8 {
            return key;
        }
    };
}

const DTCtx = struct {
    pub fn deinit(_: *DTCtx, r: *DTR) void {
        r.alloc.free(r.value);
    }
};
const DTR = struct {
    value: []const u8,
    invariant: u64,
    alloc: std.mem.Allocator,
};

pub const DTValue = arc.ArcCtx(DTR, DTCtx);

pub fn DependantTemplate(
    comptime Context: type,
    comptime key: []const u8,
    comptime fmt: []const u8,
    comptime params: []const []const u8,
) type {
    _ = key;
    const Resolver = resolver.Resolver(Context);
    const types = comptime blk: {
        var types: [params.len]type = undefined;
        for (0..params.len) |i| {
            types[i] = Resolver.resolveType(params[i]);
        }

        break :blk &types;
    };

    const ArgType = std.meta.Tuple(types);

    return struct {
        pub const TemplateType = .dependant;
        revision: ?arc.ArcSwap(DTR, DTCtx) = null,

        pub fn deinit(self: *@This()) void {
            if (self.revision) |*r| {
                r.deinit();
            }
        }

        pub fn get(self: *@This(), inj: *dep.DepCtx) !*DTValue {
            const ctx = try inj.require(*Context);
            const alloc = try inj.require(std.mem.Allocator);
            if (self.revision == null) {
                self.revision = try .init(alloc, 8);
            }

            var args: ArgType = undefined;
            inline for (0..params.len) |i| {
                args[i] = try Resolver.resolve(inj, params[i], ctx);
            }

            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, args, .DeepRecursive);
            const invariant = hasher.final();
            const latest = self.revision.?.get();
            if (latest) |l| {
                if (l.data.data.invariant == invariant) {
                    return l;
                } else {
                    self.revision.?.next(.{
                        .invariant = invariant,
                        .value = try std.fmt.allocPrint(alloc, fmt, args),
                        .alloc = alloc,
                    });
                    return self.revision.?.get().?;
                }
            }
            self.revision.?.next(.{
                .invariant = invariant,
                .value = try std.fmt.allocPrint(alloc, fmt, args),
                .alloc = alloc,
            });
            return self.revision.?.get().?;
        }
    };
}

/// Encodes a template with an unchanging value.
pub fn ComptimeTemplate(
    comptime raw: []const u8,
) type {
    return struct {
        pub const TemplateType = .constant;
        pub inline fn get(_: @This(), inj: *dep.DepCtx) ![]const u8 {
            _ = inj;
            return raw;
        }
    };
}

// Ref all decls — instantiate the template generics (the route/driver builder
// helpers are exercised by the driver packages with real Routes).
comptime {
    std.testing.refAllDeclsRecursive(@This());
    const Ctx = struct { x: u8 };
    std.testing.refAllDeclsRecursive(FreeTemplate(Ctx, "k", "{d}", &.{"x"}));
    std.testing.refAllDeclsRecursive(DependantTemplate(Ctx, "k", "{d}", &.{"x"}));
    std.testing.refAllDeclsRecursive(LinkedTemplate("k"));
    std.testing.refAllDeclsRecursive(ComptimeTemplate("k"));
    _ = DTValue;
}
