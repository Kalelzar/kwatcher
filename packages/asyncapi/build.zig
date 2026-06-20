const std = @import("std");

pub fn build(b: *std.Build) !void {
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kw_asyncapi = b.addModule("kw-asyncapi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The shared JSON-Schema kernel (reflection + schema nodes) lives in the docgen
    // framework package; the AsyncAPI model reuses its `Schema`/`Components` nodes.
    const kw_docschema = b.dependency("kw_docgen", .{ .target = target, .optimize = optimize }).module("kw-docschema");
    kw_asyncapi.addImport("kw-docschema", kw_docschema);

    const tests = b.addTest(.{
        .root_module = kw_asyncapi,
        .use_llvm = true,
    });

    const lib = b.addLibrary(.{
        .name = "kw-asyncapi",
        .root_module = kw_asyncapi,
        .linkage = .static,
        .use_llvm = true,
    });
    if (build_static_library) {
        b.installArtifact(lib);
    }

    const run_tests = b.addRunArtifact(tests);

    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "build.zig",
            "build.zig.zon",
        },
        .check = true,
    });

    // Steps:
    const check = b.step("check", "Build without generating artifacts.");
    check.dependOn(&lib.step);

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
    lib.step.dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);
}
