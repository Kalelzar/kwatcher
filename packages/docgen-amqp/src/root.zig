const std = @import("std");
const build_config = @import("build_config");

const docindex = @import("kw-docindex");
const asyncapi = @import("kw-asyncapi");

const extract = @import("extract.zig");

/// Generate an AsyncAPI document for an AMQP driver.
///
/// Called by the docgen framework (`packages/docgen`) once per driver. We mine the
/// driver's registered routes into a version-neutral model and serialize it to the
/// target AsyncAPI version (default 3.0.0, overridable via the `asyncapi_version`
/// build option). The result is written to `asyncapi-<name>-<driver_key>-<version>.json`.
pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version: []const u8,
) !void {
    const ver = asyncapi.parseVersion(build_config.asyncapi_version) catch |err| {
        std.log.err(
            "docgen-amqp: unsupported asyncapi_version '{s}'. Only 3.0.0 is implemented.",
            .{build_config.asyncapi_version},
        );
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info: asyncapi.model.Info = .{ .title = name, .version = version };

    const doc = try extract.buildDocument(Driver, info, ver, doc_index, a);

    const file_name = try std.fmt.allocPrint(a, "asyncapi-{s}-{s}-{s}.json", .{
        info.title,
        @tagName(Driver.key),
        info.version,
    });

    std.log.info("docgen-amqp: writing AsyncAPI {s} to '{s}'.", .{ ver.toString(), file_name });

    var file = try out_dir.createFile(file_name, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const wi = &writer.interface;
    try asyncapi.serialize(doc, wi);
    try wi.writeByte('\n');
    try wi.flush();
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    _ = extract;
}
