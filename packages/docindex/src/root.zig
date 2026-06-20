//! A generic, driver-agnostic index of `///` doc comments mined from Zig source.
//!
//! Zig reflection exposes neither doc comments nor source locations, so to attach
//! human-written documentation to generated output (OpenAPI, AsyncAPI, …) we parse
//! the source files themselves at generation time and look things up by name.
//!
//! Nothing here is HTTP- or OpenAPI-specific. Callers map their own domain concepts
//! (a route's raw function name, a struct type, a field, …) onto the generic
//! lookups below:
//!
//!   * `declDoc(name)`            — a function/const declaration, by exact name.
//!   * `typeDoc(name, fields)`    — a named container type, by its bare decl name.
//!   * `fieldDoc(name, f, fields)`— one field of such a type.
//!
//! Types are keyed by their *bare declaration name* (the last `@typeName` component,
//! e.g. `ProblemDetails`) — deliberately not by file/module path, since `@typeName`'s
//! prefix is the import path and can't be reconstructed from a flat file walk. Name
//! collisions are resolved by the `fields` argument: a lookup succeeds only when
//! exactly one indexed type of that name has a matching field set (otherwise null,
//! so an ambiguous match never yields a wrong doc).

const std = @import("std");
const Ast = std.zig.Ast;

pub const FieldDoc = struct {
    name: []const u8,
    doc: []const u8,
};

/// One documented type. Multiple may share an FQN (basename collision); `field_names`
/// disambiguates which source type a reflected type corresponds to.
pub const TypeEntry = struct {
    doc: ?[]const u8 = null,
    field_names: []const []const u8 = &.{},
    field_docs: []const FieldDoc = &.{},
};

pub const DocIndex = struct {
    arena: std.heap.ArenaAllocator,
    /// Declaration name (exactly as written) → joined doc-comment text.
    decls: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Type FQN → candidate entries (more than one only on basename collision).
    types: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TypeEntry)) = .empty,

    pub fn deinit(self: *DocIndex) void {
        self.arena.deinit();
    }

    /// Doc comment for a top-level/`pub` declaration (function or const) by its
    /// exact source name, or `null`.
    pub fn declDoc(self: *const DocIndex, name: []const u8) ?[]const u8 {
        if (name.len == 0) return null;
        return self.decls.get(name);
    }

    /// Doc comment for a named container type, identified by its bare decl name.
    /// `field_names` (the reflected type's fields) disambiguates name collisions.
    pub fn typeDoc(self: *const DocIndex, name: []const u8, field_names: []const []const u8) ?[]const u8 {
        const entry = self.pickType(name, field_names) orelse return null;
        return entry.doc;
    }

    /// Doc comment for one field of a named container type, or `null`.
    pub fn fieldDoc(
        self: *const DocIndex,
        name: []const u8,
        field_name: []const u8,
        field_names: []const []const u8,
    ) ?[]const u8 {
        const entry = self.pickType(name, field_names) orelse return null;
        for (entry.field_docs) |fd| {
            if (std.mem.eql(u8, fd.name, field_name)) return fd.doc;
        }
        return null;
    }

    /// The unique indexed type of `name` whose field set matches `field_names`.
    /// Requires an exact field-set match (even when only one candidate exists) so a
    /// same-named-but-different type never picks up the wrong doc, and returns null
    /// when two candidates match equally (genuine ambiguity).
    fn pickType(self: *const DocIndex, name: []const u8, field_names: []const []const u8) ?*const TypeEntry {
        const list = self.types.getPtr(name) orelse return null;
        var found: ?*const TypeEntry = null;
        for (list.items) |*entry| {
            if (!fieldSetEqual(entry.field_names, field_names)) continue;
            if (found != null) return null; // two types match equally — ambiguous.
            found = entry;
        }
        return found;
    }
};

fn fieldSetEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x, y)) break;
        } else return false;
    }
    return true;
}

/// Build an index by walking each source root for `.zig` files and collecting every
/// `///` (and container `//!`) doc comment. Robust by design: an unreadable root or
/// an unparseable file is skipped with a warning rather than failing the build.
pub fn build(gpa: std.mem.Allocator, source_roots: []const []const u8) !DocIndex {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer index.arena.deinit();

    for (source_roots) |root| {
        indexTree(gpa, &index, root) catch |e| {
            std.log.warn("docindex: skipping source root '{s}': {t}", .{ root, e });
        };
    }
    return index;
}

const skip_dirs = [_][]const u8{ ".zig-cache", "zig-out", ".git" };

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return name.len > 1 and name[0] == '.' and !std.mem.eql(u8, name, "..");
}

fn indexTree(gpa: std.mem.Allocator, index: *DocIndex, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(entry.name)) continue;
                const sub = try std.fs.path.join(gpa, &.{ root, entry.name });
                defer gpa.free(sub);
                try indexTree(gpa, index, sub);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const full = try std.fs.path.join(gpa, &.{ root, entry.name });
                defer gpa.free(full);
                indexFile(gpa, index, full) catch |e| {
                    std.log.warn("docindex: skipping '{s}': {t}", .{ full, e });
                };
            },
            else => {},
        }
    }
}

fn indexFile(gpa: std.mem.Allocator, index: *DocIndex, path: []const u8) !void {
    const src = try std.fs.cwd().readFileAllocOptions(gpa, path, 1 << 24, null, .of(u8), 0);
    defer gpa.free(src);
    try indexSource(gpa, index, src);
}

/// Index a source buffer: function/const decls (token pass) and container types
/// with their fields (AST pass).
pub fn indexSource(gpa: std.mem.Allocator, index: *DocIndex, src: [:0]const u8) !void {
    var ast = try Ast.parse(gpa, src, .zig);
    defer ast.deinit(gpa);
    const a = index.arena.allocator();

    try scanDecls(a, index, ast);
    // The file's own container is not a named type — pass "" so it isn't registered.
    try walkContainer(a, index, ast, "", ast.containerDeclRoot().ast.members, null);
}

/// Token-level pass: a run of `.doc_comment` tokens attaches to the declaration
/// (`fn`/`const`/`var`) that follows it (a `pub` in between is transparent). Simple
/// and over-broad — spurious entries (e.g. from a `*const T` type) are harmless
/// because callers only look up names they expect. Captures function decls (which
/// the container walk below does not), so route handlers are covered.
fn scanDecls(a: std.mem.Allocator, index: *DocIndex, ast: Ast) !void {
    const n: u32 = @intCast(ast.tokens.len);
    var doc_start: ?u32 = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        switch (ast.tokenTag(i)) {
            .doc_comment => if (doc_start == null) {
                doc_start = i;
            },
            .keyword_pub => {},
            .keyword_fn, .keyword_const, .keyword_var => {
                if (doc_start) |ds| {
                    if (i + 1 < n and ast.tokenTag(i + 1) == .identifier) {
                        const name = unquoteIdentifier(ast.tokenSlice(i + 1));
                        const doc = try joinDocComments(a, ast, ds);
                        try index.decls.put(a, try a.dupe(u8, name), doc);
                    }
                }
                doc_start = null;
            },
            else => doc_start = null,
        }
    }
}

/// AST pass: record each named container type (its own doc + per-field docs) under
/// its bare decl `name`, recursing into nested `const Name = struct {…}` decls.
fn walkContainer(
    a: std.mem.Allocator,
    index: *DocIndex,
    ast: Ast,
    name: []const u8,
    members: []const Ast.Node.Index,
    own_doc: ?[]const u8,
) !void {
    var field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var field_docs: std.ArrayListUnmanaged(FieldDoc) = .empty;

    for (members) |member| {
        if (ast.fullContainerField(member)) |field| {
            if (field.ast.tuple_like) continue;
            const field_name = try a.dupe(u8, unquoteIdentifier(ast.tokenSlice(field.ast.main_token)));
            try field_names.append(a, field_name);
            if (try docBefore(a, ast, field.firstToken())) |doc| {
                try field_docs.append(a, .{ .name = field_name, .doc = doc });
            }
            continue;
        }
        if (ast.fullVarDecl(member)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            var buf: [2]Ast.Node.Index = undefined;
            const container = ast.fullContainerDecl(&buf, init_node) orelse continue;
            const decl_name = unquoteIdentifier(ast.tokenSlice(var_decl.ast.mut_token + 1));
            const decl_doc = try docBefore(a, ast, var_decl.firstToken());
            try walkContainer(a, index, ast, decl_name, container.ast.members, decl_doc);
        }
    }

    // A `///` decl comment wins; otherwise fall back to a `//!` container comment.
    const doc = own_doc orelse try containerDoc(a, ast, members);
    try registerType(a, index, name, doc, field_names.items, field_docs.items);
}

fn registerType(
    a: std.mem.Allocator,
    index: *DocIndex,
    name: []const u8,
    doc: ?[]const u8,
    field_names: []const []const u8,
    field_docs: []const FieldDoc,
) !void {
    // Skip the file's own container and wholly-undocumented types.
    if (name.len == 0) return;
    if (doc == null and field_docs.len == 0) return;
    const gop = try index.types.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = .empty;
    }
    try gop.value_ptr.append(a, .{
        .doc = doc,
        .field_names = field_names,
        .field_docs = field_docs,
    });
}

/// The `//!` container doc comment at the start of a container body, if any.
fn containerDoc(a: std.mem.Allocator, ast: Ast, members: []const Ast.Node.Index) !?[]const u8 {
    if (members.len == 0) return null;
    // Container doc tokens sit just before the first member; scan back over them.
    const first = ast.firstToken(members[0]);
    var start = first;
    while (start > 0 and ast.tokenTag(start - 1) == .container_doc_comment) start -= 1;
    if (start == first) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var t = start;
    var is_first = true;
    while (t < first and ast.tokenTag(t) == .container_doc_comment) : (t += 1) {
        if (!is_first) try out.append(a, '\n');
        is_first = false;
        try out.appendSlice(a, stripDocPrefix(ast.tokenSlice(t)));
    }
    return out.items;
}

/// Join the contiguous run of `.doc_comment` tokens ending just before `before`.
fn docBefore(a: std.mem.Allocator, ast: Ast, before: Ast.TokenIndex) !?[]const u8 {
    if (before == 0) return null;
    var start = before;
    while (start > 0 and ast.tokenTag(start - 1) == .doc_comment) start -= 1;
    if (start == before) return null;
    return try joinDocComments(a, ast, start);
}

/// Join a contiguous run of `.doc_comment` tokens starting at `start`, stripping the
/// leading `///` (and one space) from each line.
fn joinDocComments(a: std.mem.Allocator, ast: Ast, start: u32) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const n: u32 = @intCast(ast.tokens.len);
    var i = start;
    var first = true;
    while (i < n and ast.tokenTag(i) == .doc_comment) : (i += 1) {
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, stripDocPrefix(ast.tokenSlice(i)));
    }
    return out.items;
}

fn stripDocPrefix(line: []const u8) []const u8 {
    var s = line;
    if (std.mem.startsWith(u8, s, "///")) s = s[3..];
    if (std.mem.startsWith(u8, s, "//!")) s = s[3..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    return s;
}

/// `@"GET /x"` → `GET /x`; a plain identifier is returned unchanged.
fn unquoteIdentifier(tok: []const u8) []const u8 {
    if (tok.len >= 3 and tok[0] == '@' and tok[1] == '"' and tok[tok.len - 1] == '"') {
        return tok[2 .. tok.len - 1];
    }
    return tok;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "declDoc extracts doc comments by name, including quoted route names" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    const src =
        \\const std = @import("std");
        \\
        \\/// A heartbeat payload.
        \\pub const HeartbeatMessage = struct {
        \\    /// Unix timestamp in seconds.
        \\    timestamp: u64,
        \\};
        \\
        \\const Routes = struct {
        \\    /// List all users.
        \\    /// Second line.
        \\    pub fn @"GET /api/v1/users @listUsers"() void {}
        \\
        \\    pub fn @"GET /undocumented"() void {}
        \\};
    ;
    try indexSource(std.testing.allocator, &index, src);

    try std.testing.expectEqualStrings("A heartbeat payload.", index.declDoc("HeartbeatMessage").?);
    try std.testing.expectEqualStrings(
        "List all users.\nSecond line.",
        index.declDoc("GET /api/v1/users @listUsers").?,
    );
    try std.testing.expect(index.declDoc("GET /undocumented") == null);
    try std.testing.expect(index.declDoc("nonexistent") == null);
}

test "typeDoc and fieldDoc resolve by bare decl name" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    const src =
        \\/// A heartbeat payload.
        \\pub const HeartbeatMessage = struct {
        \\    /// Unix timestamp in seconds.
        \\    timestamp: u64,
        \\    count: u64,
        \\};
    ;
    try indexSource(std.testing.allocator, &index, src);

    const fields = &.{ "timestamp", "count" };
    try std.testing.expectEqualStrings("A heartbeat payload.", index.typeDoc("HeartbeatMessage", fields).?);
    try std.testing.expectEqualStrings("Unix timestamp in seconds.", index.fieldDoc("HeartbeatMessage", "timestamp", fields).?);
    try std.testing.expect(index.fieldDoc("HeartbeatMessage", "count", fields) == null);
    try std.testing.expect(index.typeDoc("Nope", &.{}) == null);
    // Wrong field set (e.g. a different same-named type) does not match.
    try std.testing.expect(index.typeDoc("HeartbeatMessage", &.{"other"}) == null);
}

test "container //! doc is used when there is no decl doc" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    const src =
        \\pub const Config = struct {
        \\    //! Application configuration.
        \\    port: u16,
        \\};
    ;
    try indexSource(std.testing.allocator, &index, src);
    try std.testing.expectEqualStrings("Application configuration.", index.typeDoc("Config", &.{"port"}).?);
}

test "same-named types are disambiguated by field set" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    // Two different `Body` types (as if from different files).
    try indexSource(std.testing.allocator, &index,
        \\/// First body.
        \\pub const Body = struct { a: u8 };
    );
    try indexSource(std.testing.allocator, &index,
        \\/// Second body.
        \\pub const Body = struct { b: u8, c: u8 };
    );

    try std.testing.expectEqualStrings("First body.", index.typeDoc("Body", &.{"a"}).?);
    try std.testing.expectEqualStrings("Second body.", index.typeDoc("Body", &.{ "b", "c" }).?);
    // A field set matching neither is ambiguous → null.
    try std.testing.expect(index.typeDoc("Body", &.{"z"}) == null);
}
