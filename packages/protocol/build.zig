const std = @import("std");
const zettel = @import("zettel");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;
    const include_metrics = b.option(bool, "metrics", "Include metrics generation in code.") orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption(bool, "enable_metrics", include_metrics);

    const kw_protocol = b.addModule("kw-protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    kw_protocol.addOptions("build_config", o);

    const tests = b.addTest(.{
        .root_module = kw_protocol,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-protocol",
        .root_module = kw_protocol,
        .linkage = .static,
        .use_llvm = true,
    });
    if (build_static_library) {
        b.installArtifact(lib);
    }

    const run_tests = b.addRunArtifact(tests);

    const install_docs = b.addInstallDirectory(
        .{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        },
    );

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

    // - fmt
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);

    // - docs
    const docs_step = b.step("docs", "Generate docs");
    docs_step.dependOn(&install_docs.step);
    docs_step.dependOn(&lib.step);

    // Dependencies:
    // 1st Party:
    const kw_core_dep = b.dependency("kw_core", .{ .target = target, .optimize = optimize });
    const kw_core = kw_core_dep.module("kw-core");
    const kw_amqp = b.dependency("kw_amqp", .{ .target = target, .optimize = optimize }).module("kw-amqp");
    const kw_cron = b.dependency("kw_cron", .{ .target = target, .optimize = optimize }).module("kw-cron");
    const klib = b.dependency("klib", .{ .target = target, .optimize = optimize }).module("klib");

    // Imports:
    // 1st Party:
    kw_protocol.addImport("kw-core", kw_core);
    kw_protocol.addImport("kw-amqp", kw_amqp);
    kw_protocol.addImport("kw-cron", kw_cron);
    kw_protocol.addImport("klib", klib);

    // zettel schema codegen: one generated module per protocol domain,
    // compiled against kw-core's schema sources via --import so foreign
    // names lower to @import("kw-core-schema") and the whole tree shares
    // one Context/ZettelError.
    // Debug for build speed — must stay in lockstep with kw-core's zettel
    // dependency so the two instantiations dedup into one.
    const zettel_dep = b.dependency("zettel", .{ .optimize = .Debug });
    const core_schema = zettel.SchemaImport{
        .name = "kw-core-schema",
        .dir = kw_core_dep.namedLazyPath("schema-dir"),
        .module = kw_core_dep.module("kw-core-schema"),
    };
    for ([_][2][]const u8{
        .{ "kwatcher:protocol:client-registration", "kw-cr-schema" },
        .{ "kwatcher:protocol:secret", "kw-secret-schema" },
    }) |domain| {
        kw_protocol.addImport(domain[1], zettel.schemaModule(b, zettel_dep, .{
            .source_dir = b.path("schema"),
            .root_module = domain[0],
            .imports = &.{core_schema},
            .check_step = check,
            .target = target,
            .optimize = optimize,
        }));
    }
}
