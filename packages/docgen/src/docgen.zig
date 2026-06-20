const std = @import("std");
const core = @import("kw-core");
const Drivers = core.driver.Drivers;

const build_config = @import("build_config");
const modules = @import("kw-gen--modules");
const user_root = @import("entrypoint");
const docindex = @import("kw-docindex");

pub fn generate(alloc: std.mem.Allocator, out_dir: []const u8, source_roots: []const []const u8) !void {
    const D = user_root.drivers.drivers;
    std.log.info("Generating docs at: {s}", .{out_dir});
    var out = try std.fs.cwd().makeOpenPath(out_dir, .{});
    defer out.close();

    var sourceFile = try out.createFile("generated.zig", .{});
    defer sourceFile.close();

    // Mine `///` doc comments from the project sources once; every driver's docgen
    // shares the same index (generic — see kw-docindex).
    var index = try docindex.build(alloc, source_roots);
    defer index.deinit();

    inline for (D.drivers) |Drv| {
        const kind = Drv.kind;
        const module_name = @tagName(kind);
        const module = @field(modules, module_name);
        try module.docgen(Drv, out, alloc, &index);
    }
}
