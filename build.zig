const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_kwev = b.option(bool, "kwev", "Build the kwev tooling ") orelse build_all;
    const openapi_version = b.option([]const u8, "openapi_version", "Target OpenAPI version for HTTP docgen") orelse "3.2.0";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kwatcher_example = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .dwarf_format = .@"64",
        .link_libc = false,
        .omit_frame_pointer = false,
    });

    const kwatcher_example_dummy = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .dwarf_format = .@"64",
        .link_libc = false,
        .omit_frame_pointer = false,
    });

    const kwatcher_kwev = b.createModule(.{
        .root_source_file = b.path("src/kwev.zig"),
        .target = target,
        .optimize = optimize,
        .dwarf_format = .@"64",
        .link_libc = false,
        .omit_frame_pointer = false,
    });

    // Artifacts:
    const example = b.addExecutable(.{
        .name = "kwatcher-example",
        .root_module = kwatcher_example,
        .use_llvm = true, // Due to https://github.com/ziglang/zig/issues/24181
    });

    if (build_example) {
        b.installArtifact(example);
    }

    const kwev = b.addExecutable(.{
        .name = "kwev",
        .root_module = kwatcher_kwev,
        .use_llvm = true, // Due to https://github.com/ziglang/zig/issues/24181
    });
    if (build_kwev) {
        b.installArtifact(kwev);
    }

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
    check.dependOn(&example.step);
    check.dependOn(&kwev.step);

    // - fmt
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);

    // Dependencies:
    // 1st Party:
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kwatcher = b.dependency("kwatcher", .{ .target = target, .optimize = optimize }).module("kwatcher");
    const kw_amqp = b.dependency("kw_amqp", .{ .target = target, .optimize = optimize }).module("kw-amqp");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_cron = b.dependency("kw_cron", .{ .target = target, .optimize = optimize }).module("kw-cron");
    const kw_action = b.dependency("kw_action", .{ .target = target, .optimize = optimize }).module("kw-action");
    const kw_signal = b.dependency("kw_signal", .{ .target = target, .optimize = optimize }).module("kw-signal");
    const kw_kwev = b.dependency("kw_kwev", .{ .target = target, .optimize = optimize }).module("kw-kwev");

    const kw_modgen_dep = b.dependency("kw_docgen", .{
        .target = b.graph.host,
        .optimize = optimize,
        .module_only = true,
        .all = true,
    });

    const kw_docgen_dep = b.dependency("kw_docgen", .{
        .target = b.graph.host,
        .optimize = optimize,
        .module_only = false,
        .all = true,
    });

    const kw_modgen = kw_modgen_dep.artifact("kw-modgen");
    const kw_docgen = kw_docgen_dep.artifact("kw-docgen");

    const kw_modgen_mod = kw_modgen_dep.module("kw-docgen");
    const kw_docgen_mod = kw_docgen_dep.module("kw-docgen");

    kw_modgen_mod.addImport("entrypoint", kwatcher_example_dummy);
    kw_docgen_mod.addImport("entrypoint", kwatcher_example_dummy);

    const docgen = b.addRunArtifact(kw_docgen);
    const modgen = b.addRunArtifact(kw_modgen);
    kw_docgen.step.dependOn(&kw_modgen.step);

    const modgen_path = modgen.addOutputDirectoryArg("kw-modgen");
    const docgen_path = docgen.addOutputDirectoryArg("kw-docgen");

    example.step.dependOn(&docgen.step);

    // Copy the generated OpenAPI documents into zig-out/docs on install.
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docgen_path,
        .install_dir = .prefix,
        .install_subdir = "docs",
        .include_extensions = &.{"json"},
    });
    b.getInstallStep().dependOn(&install_docs.step);

    const kw_docgen_none = b.dependency("kw_docgen_none", .{
        .target = target,
        .optimize = optimize,
    }).module("kw-docgen--none");

    const kw_docgen_http = b.dependency("kw_docgen_http", .{
        .target = target,
        .optimize = optimize,
        .openapi_version = openapi_version,
    }).module("kw-docgen--http");

    kwatcher_example.addAnonymousImport("kw-gen--docs", .{
        .root_source_file = docgen_path.path(b, "generated.zig"),
    });

    const docgen_modules = b.createModule(.{
        .root_source_file = modgen_path.path(b, "modules.zig"),
    });

    docgen_modules.addImport("kw-docgen--cron", kw_docgen_none);
    docgen_modules.addImport("kw-docgen--amqp", kw_docgen_none);
    docgen_modules.addImport("kw-docgen--http", kw_docgen_http);
    docgen_modules.addImport("kw-docgen--action", kw_docgen_none);
    docgen_modules.addImport("kw-docgen--signal", kw_docgen_none);

    kw_docgen_mod.addImport("kw-gen--modules", docgen_modules);

    // 3rd Party:
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");

    // Imports:
    // Example application:
    kwatcher_example.addImport("kw-core", kw_core);
    kwatcher_example.addImport("kwatcher", kwatcher);
    kwatcher_example.addImport("kw-amqp", kw_amqp);
    kwatcher_example.addImport("kw-http", kw_http);
    kwatcher_example.addImport("kw-cron", kw_cron);
    kwatcher_example.addImport("kw-action", kw_action);
    kwatcher_example.addImport("kw-signal", kw_signal);
    kwatcher_example.addImport("httpz", httpz);

    kwatcher_example_dummy.addImport("kw-core", kw_core);
    kwatcher_example_dummy.addImport("kwatcher", kwatcher);
    kwatcher_example_dummy.addImport("kw-amqp", kw_amqp);
    kwatcher_example_dummy.addImport("kw-http", kw_http);
    kwatcher_example_dummy.addImport("kw-cron", kw_cron);
    kwatcher_example_dummy.addImport("kw-action", kw_action);
    kwatcher_example_dummy.addImport("kw-signal", kw_signal);
    kwatcher_example_dummy.addImport("httpz", httpz);

    // kwev tooling:
    kwatcher_kwev.addImport("kw-kwev", kw_kwev);
}
