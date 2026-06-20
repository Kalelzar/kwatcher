const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_kwev = b.option(bool, "kwev", "Build the kwev tooling ") orelse build_all;

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

    // kwev tooling:
    kwatcher_kwev.addImport("kw-kwev", kw_kwev);
}
