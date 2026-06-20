const std = @import("std");
const build_config = @import("build_config");

const model = @import("model.zig");
const version = @import("version.zig");
const reflect = @import("reflect.zig");
const extract = @import("extract.zig");
const openapi = @import("openapi.zig");

const Zoir = std.zig.Zoir;

/// Generate an OpenAPI document for an HTTP driver.
///
/// Called by the docgen framework (`packages/docgen`) once per driver. We mine the
/// driver's registered routes into a version-neutral model and serialize it to the
/// target OpenAPI version (default 3.2.0, overridable via the `openapi_version`
/// build option). The result is written to `<name>-<driver_key>-<version>.json`.
pub fn docgen(comptime Driver: type, out_dir: std.fs.Dir, allocator: std.mem.Allocator) !void {
    const ver = version.parse(build_config.openapi_version) catch |err| {
        std.log.err(
            "docgen-http: unsupported openapi_version '{s}'. Only 3.2.0 is implemented.",
            .{build_config.openapi_version},
        );
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info = readInfo(a, @tagName(Driver.kind));

    const doc = try extract.buildDocument(Driver, info, ver, a);

    const file_name = try std.fmt.allocPrint(a, "{s}-{s}-{s}.json", .{
        info.title,
        @tagName(Driver.key),
        info.version,
    });

    std.log.info("docgen-http: writing OpenAPI {s} to '{s}'.", .{ ver.toString(), file_name });

    var file = try out_dir.createFile(file_name, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const wi = &writer.interface;
    try openapi.serialize(doc, wi);
    try wi.writeByte('\n');
    try wi.flush();
}

/// Read `title`/`version` for the `info` block from the project's `build.zig.zon`
/// (resolved against the current working directory, which is the project root
/// during a build). Falls back to driver-derived defaults if it can't be read or
/// parsed — each field independently.
fn readInfo(arena: std.mem.Allocator, driver_kind: []const u8) model.Info {
    const default: model.Info = .{ .title = driver_kind, .version = "0.0.0" };

    const bytes = std.fs.cwd().readFileAlloc(arena, "build.zig.zon", 1 << 20) catch return default;
    const src = arena.dupeZ(u8, bytes) catch return default;
    return parseManifest(arena, src, default) catch default;
}

/// Pull `.name` (a ZON enum literal) and `.version` (a string) out of a manifest
/// using the standard library's ZON reader. Unknown/missing fields keep their
/// default; the returned strings are duped into `arena` so they outlive the parse.
fn parseManifest(arena: std.mem.Allocator, src: [:0]const u8, default: model.Info) !model.Info {
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

    var info = default;
    for (fields.names, 0..) |name, i| {
        const field_name = name.get(zoir);
        const value = fields.vals.at(@intCast(i)).get(zoir);
        if (std.mem.eql(u8, field_name, "name")) {
            switch (value) {
                .enum_literal => |lit| info.title = try arena.dupe(u8, lit.get(zoir)),
                else => {},
            }
        } else if (std.mem.eql(u8, field_name, "version")) {
            switch (value) {
                .string_literal => |s| info.version = try arena.dupe(u8, s),
                else => {},
            }
        }
    }
    return info;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    // Pull every module's tests into the package test binary.
    std.testing.refAllDecls(@This());
    _ = model;
    _ = version;
    _ = reflect;
    _ = extract;
    _ = openapi;
    _ = @import("emit/v3_2_0.zig");
}

test "reads name and version from a manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\.{
        \\    .name = .kwatcher_example,
        \\    .version = "0.1.2",
        \\    .minimum_zig_version = "0.15.2",
        \\    .fingerprint = 0x5a2508fd019a6580,
        \\    .dependencies = .{},
        \\}
    ;
    const info = try parseManifest(a, src, .{ .title = "fallback", .version = "0.0.0" });
    try std.testing.expectEqualStrings("kwatcher_example", info.title);
    try std.testing.expectEqualStrings("0.1.2", info.version);
}

test "falls back on a manifest missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info = try parseManifest(a, ".{}", .{ .title = "fallback", .version = "9.9.9" });
    try std.testing.expectEqualStrings("fallback", info.title);
    try std.testing.expectEqualStrings("9.9.9", info.version);
}
