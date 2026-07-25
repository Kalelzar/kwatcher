// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;
    const asyncapi_version = b.option([]const u8, "asyncapi_version", "Target AsyncAPI version to emit.") orelse "3.0.0";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption([]const u8, "asyncapi_version", asyncapi_version);

    const kw_docgen_amqp = b.addModule("kw-docgen--amqp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    kw_docgen_amqp.addOptions("build_config", o);

    const kw_docindex = b.dependency("kw_docindex", .{ .target = target, .optimize = optimize }).module("kw-docindex");
    kw_docgen_amqp.addImport("kw-docindex", kw_docindex);

    // The shared JSON-Schema kernel and the reusable AsyncAPI core.
    const kw_docschema = b.dependency("kw_docgen", .{ .target = target, .optimize = optimize }).module("kw-docschema");
    kw_docgen_amqp.addImport("kw-docschema", kw_docschema);
    const kw_asyncapi = b.dependency("kw_asyncapi", .{ .target = target, .optimize = optimize }).module("kw-asyncapi");
    kw_docgen_amqp.addImport("kw-asyncapi", kw_asyncapi);

    const tests = b.addTest(.{
        .root_module = kw_docgen_amqp,
        .use_llvm = true,
    });

    const lib = b.addLibrary(.{
        .name = "kw-docgen--amqp",
        .root_module = kw_docgen_amqp,
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
