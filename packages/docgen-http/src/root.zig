const std = @import("std");
const build_config = @import("build_config");

const docindex = @import("kw-docindex");

const model = @import("model.zig");
const version = @import("version.zig");
const reflect = @import("kw-docschema").reflect;
const extract = @import("extract.zig");
const openapi = @import("openapi.zig");

/// Generate an OpenAPI document for an HTTP driver.
///
/// Called by the docgen framework (`packages/docgen`) once per driver. We mine the
/// driver's registered routes into a version-neutral model and serialize it to the
/// target OpenAPI version (default 3.2.0, overridable via the `openapi_version`
/// build option). The result is written to `openapi-<name>-<driver_key>-<version>.json`.
pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version_str: []const u8,
) !void {
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

    const info: model.Info = .{ .title = name, .version = version_str };

    const doc = try extract.buildDocument(Driver, info, ver, doc_index, a);

    const file_name = try std.fmt.allocPrint(a, "openapi-{s}-{s}-{s}.json", .{
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
