//! Build-time helper that wires the docgen pipeline (the kw-docgen generator)
//! into a consumer's build graph. Pure build-graph logic — references only `std.Build`
//! types, never the runtime docgen code. Re-exported from this package's `build.zig` as
//! `build_docgen`, so a consumer uses `@import("kw_docgen").build_docgen.wire(b, .{…})`.
const std = @import("std");

/// One driver-kind → docgen-backend-module mapping. The consumer owns this decision
/// (which kinds it wants documented, and which backend documents each); the helper
/// stays generic and never enumerates kinds itself. Kinds with no entry are
/// skipped by the generator, so only list what you need.
pub const Backend = struct {
    /// Driver kind tag as it appears in `@tagName(Driver.kind)`, e.g. "http", "cron".
    kind: []const u8,
    /// The kw-docgen--<kind> backend module (e.g. kw-docgen--http).
    module: *std.Build.Module,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Module that consumes the emitted docs; receives the `kw-gen--docs` anon import.
    /// Its imports must already be wired when `wire` is called (the derived entrypoint
    /// mirrors them — see `entrypoint`).
    consumer: *std.Build.Module,
    /// Host-target build of the app the generators introspect, imported as "entrypoint"
    /// by modgen and docgen. Must NOT import `kw-gen--docs`, or the docgen run would
    /// depend on its own output. Leave null (the default) and the helper derives it by
    /// mirroring `consumer`'s root source + imports onto the host target — so callers
    /// needn't hand-maintain a second copy. Set explicitly only when the introspected
    /// app must differ from the doc consumer.
    entrypoint: ?*std.Build.Module = null,
    /// App source root walked for doc comments, relative to the consumer build root.
    app_source_root: []const u8 = "src",
    /// Driver-kind → backend module mapping.
    backends: []const Backend,
    /// Consumer's zon key for the docgen package (where kw-modgen/kw-docgen come from).
    docgen_dep_name: []const u8 = "kw_docgen",
};

pub const Result = struct {
    build_step: *std.Build.Step.Compile,
    docgen_step: *std.Build.Step.Run,
    install_docs: *std.Build.Step.InstallDir,
    /// The docgen output directory (openapi/asyncapi JSON, sqlite schema +
    /// candidate migration files) — for steps that consume the artifacts.
    docgen_path: std.Build.LazyPath,
    /// The docgen-package test suite. It compiles the consumer's full app
    /// graph, so it is NOT a gate on the generator exe — hang it off a step
    /// that runs concurrently with the codegen chain (e.g. the install step)
    /// to keep the regression signal without serializing it.
    docgen_tests: *std.Build.Step,
};

/// Wire the docgen pipeline: builds the kw-docgen generator against the app,
/// runs it, mines doc comments from the app sources plus every package in the
/// build graph, installs the emitted JSON, and stitches the generated manifest
/// back into the consumer. The driver-kind → backend mapping is resolved at
/// comptime inside the generator (`kw-docgen--<kind>` imports added below) —
/// there is no separate module-generation pass.
pub fn wire(b: *std.Build, opts: Options) Result {
    const kw_docgen_dep = b.dependency(opts.docgen_dep_name, .{
        .target = opts.target,
        .optimize = opts.optimize,
        .all = true,
    });

    const kw_docgen = kw_docgen_dep.artifact("kw-docgen");

    const kw_docgen_mod = kw_docgen_dep.module("kw-docgen");

    const entrypoint = opts.entrypoint orelse deriveEntrypoint(b, opts.consumer);
    kw_docgen_mod.addImport("entrypoint", entrypoint);

    // The kind → backend re-export map the generator resolves at comptime
    // (`kw-gen--modules`). `@import` demands literal strings, so the mapping
    // must be a real file with literal imports — but it's written right here
    // from the consumer's backend list as a WriteFile step; the old kw-modgen
    // pass compiled the entire app graph to emit these same lines. Kinds
    // without an entry are skipped by the generator (with a log line), so
    // list only the backends you actually want — no placeholders needed.
    var modules_src: std.ArrayListUnmanaged(u8) = .empty;
    for (opts.backends) |back| {
        modules_src.appendSlice(
            b.allocator,
            b.fmt("pub const {s} = @import(\"kw-docgen--{s}\");\n", .{ back.kind, back.kind }),
        ) catch @panic("OOM");
    }
    const modules_wf = b.addWriteFiles();
    const docgen_modules = b.createModule(.{
        .root_source_file = modules_wf.add("modules.zig", modules_src.items),
    });
    for (opts.backends) |back| {
        docgen_modules.addImport(b.fmt("kw-docgen--{s}", .{back.kind}), back.module);
    }
    kw_docgen_mod.addImport("kw-gen--modules", docgen_modules);

    entrypoint.addImport("kw-gen--docs", kw_docgen_dep.module("dummy"));

    const docgen = b.addRunArtifact(kw_docgen);

    const docgen_path = docgen.addOutputDirectoryArg("kw-docgen");
    // Source roots for doc-comment mining (kw-docindex), walked at generation time.
    // The app's own sources, plus every package in the build graph (transitive,
    // path- and fetched-deps alike) so routes/types defined in dependencies are
    // documented too.
    docgen.addArg(b.pathFromRoot(opts.app_source_root));
    inline for (@typeInfo(@import("root").dependencies.packages).@"struct".decls) |decl| {
        const pkg = @field(@import("root").dependencies.packages, decl.name);
        if (@hasDecl(pkg, "build_root")) docgen.addArg(pkg.build_root);
    }

    // Copy the generated documents into zig-out/docs on install: OpenAPI/AsyncAPI
    // JSON plus the sqlite schema artifacts (DDL + IR snapshot). The generated
    // manifest.zig stays out — it is wired as a module below.
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docgen_path,
        .install_dir = .prefix,
        .install_subdir = "docs",
        .include_extensions = &.{ "json", "sql", "zon" },
    });
    b.getInstallStep().dependOn(&install_docs.step);

    // One generated-manifest module, shared by the consumer and any extra runtime doc
    // consumers (the introspection modules) so they all read the same `manifest.zig`.
    const docs_mod = b.createModule(.{
        .root_source_file = docgen_path.path(b, "manifest.zig"),
    });
    opts.consumer.addImport("kw-gen--docs", docs_mod);

    return .{
        .docgen_step = docgen,
        .build_step = kw_docgen,
        .install_docs = install_docs,
        .docgen_path = docgen_path,
        .docgen_tests = &kw_docgen_dep.builder.top_level_steps.get("test").?.step,
    };
}

/// Build a host-target copy of `consumer` for the generators to introspect. The
/// generators are build-time host tools, so the app they import must be host-built; we
/// mirror the consumer's root source, imports, and module flags but force the host
/// target / ReleaseFast. Crucially this copies the consumer's imports *as they stand
/// now* — call it before `kw-gen--docs` is added to the consumer, so the copy stays free
/// of the generated output and the docgen cycle is broken.
fn deriveEntrypoint(b: *std.Build, consumer: *std.Build.Module) *std.Build.Module {
    const dummy = b.createModule(.{
        .root_source_file = consumer.root_source_file,
        .target = b.graph.host,
        // Debug, not ReleaseFast: this module is the whole app graph compiled
        // inside both generator exes, and optimizing it is pure LLVM cost —
        // the generators run for well under a second either way.
        .optimize = .Debug,
        .dwarf_format = consumer.dwarf_format,
        .link_libc = consumer.link_libc,
        .omit_frame_pointer = consumer.omit_frame_pointer,
    });
    for (consumer.import_table.keys(), consumer.import_table.values()) |name, mod| {
        dummy.addImport(name, mod);
    }
    return dummy;
}
