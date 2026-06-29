const std = @import("std");
const core = @import("kw-core");
const Drivers = core.driver.Drivers;

const build_config = @import("build_config");
const user_root = @import("entrypoint");

pub fn generate(alloc: std.mem.Allocator, out_dir: []const u8, source_roots: []const []const u8) !void {
    _ = alloc;
    _ = source_roots;
    const D = user_root.drivers.drivers;

    var out = try std.fs.cwd().makeOpenPath(out_dir, .{});
    defer out.close();

    var sourceFile = try out.createFile("modules.zig", .{});
    defer sourceFile.close();
    var buf: [1024]u8 = undefined;
    var writer = sourceFile.writer(&buf);
    const wi = &writer.interface;

    const Ctx = struct {
        pub fn eql(comptime A: type, comptime B: type) bool {
            return std.mem.eql(u8, @tagName(A.kind), @tagName(B.kind));
        }
    };

    const uniq = core.shared.SetUnionEql(type, .{}, D.drivers, Ctx);
    inline for (uniq) |Drv| {
        const kind = Drv.kind;
        const module_name = @tagName(kind);
        try wi.writeAll(std.fmt.comptimePrint("pub const {s} = @import(\"kw-docgen--{s}\");\n", .{ module_name, module_name }));
    }
    try wi.flush();
}
