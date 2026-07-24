const std = @import("std");
const docgen = @import("kw_docgen").build_docgen;
const http_template = @import("kw_http_template").build_templates;
const sqlite_migrations = @import("kw_sqlite").build_migrations;

/// Build the example application's module graph for a given target/optimize. Called twice:
/// once at the user's requested target to produce the installed `kwatcher-example`, and —
/// for cross-builds — once at the build host to give the build-time docgen generators a
/// host-runnable copy of the app to introspect (see `build` below). Keeping all the import
/// wiring here means both copies stay byte-for-byte identical apart from their target.
fn wireApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    openapi_version: []const u8,
) *std.Build.Module {
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .dwarf_format = .@"64",
        // Derived from the graph rather than pinned off: kw-sqlite links the
        // vendored sqlite3 static lib, which needs libc.
        .link_libc = null,
        .omit_frame_pointer = false,
    });

    // Committed sqlite schema snapshot + embedded migrations ("kw-sqlite--snapshot" /
    // "kw-sqlite--migrations"). Wired here so the host docgen entrypoint copy gets the
    // identical imports.
    sqlite_migrations.wire(b, app, "migrations");

    // 1st Party:
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kwatcher = b.dependency("kwatcher", .{ .target = target, .optimize = optimize }).module("kwatcher");
    const kw_amqp = b.dependency("kw_amqp", .{ .target = target, .optimize = optimize }).module("kw-amqp");
    const kw_protocol = b.dependency("kw_protocol", .{ .target = target, .optimize = optimize }).module("kw-protocol");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_cron = b.dependency("kw_cron", .{ .target = target, .optimize = optimize }).module("kw-cron");
    const kw_action = b.dependency("kw_action", .{ .target = target, .optimize = optimize }).module("kw-action");
    const kw_signal = b.dependency("kw_signal", .{ .target = target, .optimize = optimize }).module("kw-signal");
    const kw_sqlite = b.dependency("kw_sqlite", .{ .target = target, .optimize = optimize }).module("kw-sqlite");
    const kw_auth_oidc = b.dependency("kw_auth_oidc", .{ .target = target, .optimize = optimize }).module("kw-auth-oidc");

    // 3rd Party:
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");

    // Runtime-facing introspection UI modules (separate from the build-time codegen backends
    // wired in `build`): the generic core and the HTTP backend, served over the app's HTTP
    // driver.
    const kw_docgen_dep = b.dependency("kw_docgen", .{ .target = target, .optimize = optimize });
    const kw_docgen_http_dep = b.dependency("kw_docgen_http", .{
        .target = target,
        .optimize = optimize,
        .openapi_version = openapi_version,
    });
    const kw_docgen_cron_dep = b.dependency("kw_docgen_cron", .{
        .target = target,
        .optimize = optimize,
    });
    const kw_docgen_signal_dep = b.dependency("kw_docgen_signal", .{
        .target = target,
        .optimize = optimize,
    });
    const kw_introspect = kw_docgen_dep.module("kw-introspect");
    const kw_introspect_http = kw_docgen_http_dep.module("kw-introspect--http");
    const kw_introspect_cron = kw_docgen_cron_dep.module("kw-introspect--cron");
    const kw_introspect_signal = kw_docgen_signal_dep.module("kw-introspect--signal");

    // The template machinery owns its own zmpl dependency; we hand it every contributing
    // template source (each with a prefix namespace) and it returns a module wired to a zmpl
    // instance whose manifest covers them all. The introspection backends ship their `.zmpl`
    // files inside their packages; `packageSource` resolves those dirs to absolute paths. One
    // shared module so every generator's `WithTemplates` lookups (core + http prefixes) resolve.
    const kw_http_template = http_template.wire(b, .{
        .target = target,
        .optimize = optimize,
        .sources = &.{
            http_template.packageSource(kw_docgen_dep, "core", &.{"templates"}),
            http_template.packageSource(kw_docgen_http_dep, "http", &.{"templates"}),
            http_template.packageSource(kw_docgen_cron_dep, "cron", &.{"templates"}),
            http_template.packageSource(kw_docgen_signal_dep, "signal", &.{"templates"}),
        },
    });

    // The introspection modules call `WithTemplates`, which resolves `zmpl` against their own
    // `kw-http-template` import — so override their package default with this wired instance
    // (whose manifest covers the core + http prefixes).
    kw_introspect.addImport("kw-http-template", kw_http_template);
    kw_introspect_http.addImport("kw-http-template", kw_http_template);
    kw_introspect_cron.addImport("kw-http-template", kw_http_template);
    kw_introspect_signal.addImport("kw-http-template", kw_http_template);

    // Imports:
    app.addImport("kw-core", kw_core);
    app.addImport("kwatcher", kwatcher);
    app.addImport("kw-amqp", kw_amqp);
    app.addImport("kw-protocol", kw_protocol);
    app.addImport("kw-http", kw_http);
    app.addImport("kw-cron", kw_cron);
    app.addImport("kw-action", kw_action);
    app.addImport("kw-signal", kw_signal);
    app.addImport("kw-sqlite", kw_sqlite);
    app.addImport("kw-auth-oidc", kw_auth_oidc);
    app.addImport("httpz", httpz);
    app.addImport("kw-introspect", kw_introspect);
    app.addImport("kw-introspect--http", kw_introspect_http);
    app.addImport("kw-introspect--cron", kw_introspect_cron);
    app.addImport("kw-introspect--signal", kw_introspect_signal);

    return app;
}

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_kwev = b.option(bool, "kwev", "Build the kwev tooling ") orelse build_all;
    const openapi_version = b.option([]const u8, "openapi_version", "Target OpenAPI version for HTTP docgen") orelse "3.2.0";
    const asyncapi_version = b.option([]const u8, "asyncapi_version", "Target AsyncAPI version for AMQP docgen") orelse "3.0.0";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The installed application, built for the requested target.
    const kwatcher_example = wireApp(b, target, optimize, openapi_version);

    const kwatcher_kwev = b.createModule(.{
        .root_source_file = b.path("src/kwev/main.zig"),
        .target = target,
        // The kwev tool crunches multi-GB archives (CRC32 over everything,
        // millions of record parses); a Debug build of it pins a core for
        // ages. Debug builds of the repo still get an optimized tool.
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
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

    // Docgen generator graph. The generators (kw-modgen/kw-docgen) are build-time tools that
    // run on the build host and `@import` the application to introspect its drivers — so the
    // app they compile against must be built for a host-runnable target, as must the docgen
    // backends they link. When building natively the installed app graph already satisfies
    // that, so we let `docgen.wire` derive the entrypoint from it (the cheap path). For any
    // `-Dtarget` / `-Dcpu` override the app graph is no longer host-native: building it into
    // the host tool would put the same source file in two differently-targeted modules and
    // Zig refuses ("file exists in modules 'kw-core' and 'kw-core0'"). So build a dedicated
    // host copy of the app — and the backends — purely for the generators to consume.
    const native = target.query.isNative();
    const gen_target = if (native) target else b.graph.host;

    const kw_docgen_none = b.dependency("kw_docgen_none", .{
        .target = gen_target,
        .optimize = optimize,
    }).module("kw-docgen--none");

    const kw_docgen_http = b.dependency("kw_docgen_http", .{
        .target = gen_target,
        .optimize = optimize,
        .openapi_version = openapi_version,
    }).module("kw-docgen--http");

    const kw_docgen_amqp = b.dependency("kw_docgen_amqp", .{
        .target = gen_target,
        .optimize = optimize,
        .asyncapi_version = asyncapi_version,
    }).module("kw-docgen--amqp");

    const kw_docgen_cron = b.dependency("kw_docgen_cron", .{
        .target = gen_target,
        .optimize = optimize,
    }).module("kw-docgen--cron");

    const kw_docgen_signal = b.dependency("kw_docgen_signal", .{
        .target = gen_target,
        .optimize = optimize,
    }).module("kw-docgen--signal");

    const kw_docgen_sqlite = b.dependency("kw_docgen_sqlite", .{
        .target = gen_target,
        .optimize = optimize,
    }).module("kw-docgen--sqlite");

    // Host-built copy of the app for the generators to introspect; only needed when the
    // installed app isn't itself host-native. `null` lets the helper derive it from the
    // consumer (reusing the installed app's modules).
    const entrypoint: ?*std.Build.Module = if (native)
        null
    else
        wireApp(b, b.graph.host, optimize, openapi_version);

    // Docgen: wired after the example's imports are in place so the helper can mirror
    // them onto the host-target entrypoint it derives internally. This also adds the
    // generated `kw-gen--docs` module to `kwatcher_example`.
    const docs = docgen.wire(b, .{
        .target = gen_target,
        .optimize = optimize,
        .consumer = kwatcher_example,
        .entrypoint = entrypoint,
        .backends = &.{
            .{ .kind = "http", .module = kw_docgen_http },
            .{ .kind = "cron", .module = kw_docgen_cron },
            .{ .kind = "amqp", .module = kw_docgen_amqp },
            .{ .kind = "action", .module = kw_docgen_none },
            .{ .kind = "sqlite", .module = kw_docgen_sqlite },
            .{ .kind = "signal", .module = kw_docgen_signal },
            .{ .kind = "internal", .module = kw_docgen_none },
        },
    });

    example.step.dependOn(&docs.docgen_step.step);

    // Promote the generated candidate sqlite migration to a committed one:
    // `zig build commit-migration -Dmigration-name=<name>`.
    const migration_name = b.option([]const u8, "migration-name", "Name for the migration committed by `zig build commit-migration`") orelse "migration";
    const commit_tool = b.dependency("kw_docgen_sqlite", .{
        .target = gen_target,
        .optimize = optimize,
    }).artifact("kw-sqlite-commit");
    const run_commit = b.addRunArtifact(commit_tool);
    run_commit.has_side_effects = true;
    run_commit.addDirectoryArg(docs.docgen_path);
    run_commit.addArg(b.pathFromRoot("migrations"));
    run_commit.addArg(migration_name);
    const commit_step = b.step("commit-migration", "Promote the candidate sqlite migration to a committed migration");
    commit_step.dependOn(&run_commit.step);

    // kwev tooling:
    const kw_kwev = b.dependency("kw_kwev", .{ .target = target, .optimize = optimize }).module("kw-kwev");
    kwatcher_kwev.addImport("kw-kwev", kw_kwev);
    kwatcher_kwev.addImport("kw-core", b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core"));
}
