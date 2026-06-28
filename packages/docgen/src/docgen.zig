const std = @import("std");
const core = @import("kw-core");
const Drivers = core.driver.Drivers;

const build_config = @import("build_config");
const modules = @import("kw-gen--modules");
const user_root = @import("entrypoint");
const docindex = @import("kw-docindex");

const Zoir = std.zig.Zoir;

const Manifest = struct { name: []const u8, version: []const u8 };

pub fn generate(alloc: std.mem.Allocator, out_dir: []const u8, source_roots: []const []const u8) !void {
    const D = user_root.drivers.drivers;
    std.log.info("Generating docs at: {s}", .{out_dir});
    var out = try std.fs.cwd().makeOpenPath(out_dir, .{});
    defer out.close();

    var sourceFile = try out.createFile("manifest.zig", .{});
    defer sourceFile.close();

    var buf: [1024]u8 = undefined;
    var writer = sourceFile.writer(&buf);
    const wi = &writer.interface;

    try wi.writeAll(
        \\ pub const isDocgen = false;
        \\ pub const DriverInfo = struct { kind: []const u8, key: []const u8 };
        \\ pub const drivers: []const DriverInfo = &.{
    );

    inline for (D.drivers) |Drv| {
        const kind = Drv.kind;
        const key = Drv.key;
        try wi.print(".{{ .key = \"{s}\", .kind = \"{s}\", }}, ", .{ @tagName(key), @tagName(kind) });
    }

    try wi.writeAll(
        \\ };
    );

    try wi.flush();

    var manifest_arena = std.heap.ArenaAllocator.init(alloc);
    defer manifest_arena.deinit();
    const manifest = readManifest(manifest_arena.allocator());

    var index = try docindex.build(alloc, source_roots);
    defer index.deinit();

    inline for (D.drivers) |Drv| {
        const kind = Drv.kind;
        const module_name = @tagName(kind);
        const module = @field(modules, module_name);
        try module.docgen(Drv, out, alloc, &index, manifest.name, manifest.version);
    }

    // Runtime doc data: let each backend that wants to be introspectable in-app append
    // self-contained Zig to the manifest. Driven per unique kind (the framework never
    // enumerates kinds) — each backend receives every driver and filters to its own,
    // keeping one driver's metadata from leaking into another's.
    const KindCtx = struct {
        pub fn eql(comptime A: type, comptime B: type) bool {
            return std.mem.eql(u8, @tagName(A.kind), @tagName(B.kind));
        }
    };
    const unique_kinds = core.shared.SetUnionEql(type, .{}, D.drivers, KindCtx);
    inline for (unique_kinds) |Drv| {
        const module = @field(modules, @tagName(Drv.kind));
        if (@hasDecl(module, "emitRuntime")) {
            try module.emitRuntime(D.drivers, wi, alloc, &index, manifest.name, manifest.version);
        }
    }
    try wi.flush();
}

/// Read `.name`/`.version` from the project's `build.zig.zon`, falling back per
/// field when it can't be read or parsed.
fn readManifest(arena: std.mem.Allocator) Manifest {
    const default: Manifest = .{ .name = "app", .version = "0.0.0" };

    const bytes = std.fs.cwd().readFileAlloc(arena, "build.zig.zon", 1 << 20) catch return default;
    const src = arena.dupeZ(u8, bytes) catch return default;
    return parseManifest(arena, src, default) catch default;
}

/// Pull `.name` (a ZON enum literal) and `.version` (a string) out of a manifest
/// using the standard library's ZON reader. The returned strings are duped into
/// `arena` so they outlive the parse.
fn parseManifest(arena: std.mem.Allocator, src: [:0]const u8, default: Manifest) !Manifest {
    var ast = try std.zig.Ast.parse(arena, src, .zon);
    defer ast.deinit(arena);
    var zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(arena);
    if (zoir.hasCompileErrors()) return default;

    const root = Zoir.Node.Index.root.get(zoir);
    const fields = switch (root) {
        .struct_literal => |s| s,
        else => return default,
    };

    var manifest = default;
    for (fields.names, 0..) |name, i| {
        const field_name = name.get(zoir);
        const value = fields.vals.at(@intCast(i)).get(zoir);
        if (std.mem.eql(u8, field_name, "name")) {
            switch (value) {
                .enum_literal => |lit| manifest.name = try arena.dupe(u8, lit.get(zoir)),
                else => {},
            }
        } else if (std.mem.eql(u8, field_name, "version")) {
            switch (value) {
                .string_literal => |s| manifest.version = try arena.dupe(u8, s),
                else => {},
            }
        }
    }
    return manifest;
}

comptime {
    std.testing.refAllDecls(@This());
}

test "reads name and version from a manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\.{
        \\    .name = .kwatcher_example,
        \\    .version = "0.1.2",
        \\    .dependencies = .{},
        \\}
    ;
    const m = try parseManifest(a, src, .{ .name = "fallback", .version = "0.0.0" });
    try std.testing.expectEqualStrings("kwatcher_example", m.name);
    try std.testing.expectEqualStrings("0.1.2", m.version);
}

test "falls back on a manifest missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try parseManifest(a, ".{}", .{ .name = "fallback", .version = "9.9.9" });
    try std.testing.expectEqualStrings("fallback", m.name);
    try std.testing.expectEqualStrings("9.9.9", m.version);
}
