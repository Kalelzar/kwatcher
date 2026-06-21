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

/// A reconstructed `schema.Schema(...)` payload of one `(name, version)`: its doc and its
/// merged field docs. Named by reflection from `(name, version)`, not stored here.
pub const SchemaEntry = struct {
    version: u32,
    doc: ?[]const u8 = null,
    field_docs: []const FieldDoc = &.{},
};

/// The fields `core.schema.SchemaUtils` contributes to every `schema.Schema(...)`
/// payload (it is `MergeStructs(SchemaUtils(ver, name), Payload)`). Reflection sees
/// the merged struct, but the doc index parses source text and cannot evaluate the
/// generic, so the envelope is mirrored here to reconstruct the merged field set and
/// its docs. Keep in sync with `SchemaUtils` in core/schema.zig.
const schema_envelope = [_]FieldDoc{
    .{ .name = "schema_version", .doc = "The version of the schema." },
    .{ .name = "schema_name", .doc = "The name of the schema" },
};

pub const DocIndex = struct {
    arena: std.heap.ArenaAllocator,
    /// Declaration name (exactly as written) → joined doc-comment text.
    decls: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Type FQN → candidate entries (more than one only on basename collision).
    types: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TypeEntry)) = .empty,
    /// `schema.Schema(...)` wire name (e.g. `client`) → its reconstructed merged type(s).
    /// A name may have several versions (`client` v1 and v2), so entries are a list keyed
    /// by `schema_version`; identity is `(name, version)`.
    schemas: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SchemaEntry)) = .empty,

    pub fn deinit(self: *DocIndex) void {
        self.arena.deinit();
    }

    /// Whether a `Schema(...)` of `(name, version)` was collected (a concrete
    /// `const = Schema(...)` decl, not a generic). Used to decide componentization.
    pub fn hasSchema(self: *const DocIndex, schema_name: []const u8, version: u32) bool {
        return self.findSchema(schema_name, version) != null;
    }

    /// Type doc for a `Schema(...)` payload of `(name, version)`, or `null`.
    pub fn schemaDoc(self: *const DocIndex, schema_name: []const u8, version: u32) ?[]const u8 {
        const entry = self.findSchema(schema_name, version) orelse return null;
        return entry.doc;
    }

    /// Field doc for a `Schema(...)` payload field, by `(name, version)` + field, or `null`.
    pub fn schemaFieldDoc(self: *const DocIndex, schema_name: []const u8, version: u32, field_name: []const u8) ?[]const u8 {
        const entry = self.findSchema(schema_name, version) orelse return null;
        for (entry.field_docs) |fd| {
            if (std.mem.eql(u8, fd.name, field_name)) return fd.doc;
        }
        return null;
    }

    fn findSchema(self: *const DocIndex, schema_name: []const u8, version: u32) ?*const SchemaEntry {
        const list = self.schemas.getPtr(schema_name) orelse return null;
        for (list.items) |*entry| {
            if (entry.version == version) return entry;
        }
        return null;
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
    var merge: MergeCtx = .{};
    try walkContainer(a, index, ast, "", ast.containerDeclRoot().ast.members, null, &merge);
    try resolveSchemaMerges(a, index, ast, &merge);
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
    merge: *MergeCtx,
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
            const decl_name = unquoteIdentifier(ast.tokenSlice(var_decl.ast.mut_token + 1));
            // Remember every `const Name = <expr>` so a `Schema(...)` payload reference
            // can be resolved later by name, however it was built (struct, MergeStructs,
            // another alias) and wherever in the file it sits.
            try merge.decls.put(a, try a.dupe(u8, decl_name), init_node);
            var buf: [2]Ast.Node.Index = undefined;
            if (ast.fullContainerDecl(&buf, init_node)) |container| {
                const decl_doc = try docBefore(a, ast, var_decl.firstToken());
                try walkContainer(a, index, ast, decl_name, container.ast.members, decl_doc, merge);
            } else {
                try collectSchemaDecl(a, ast, var_decl, init_node, merge);
            }
        }
    }

    // A `///` decl comment wins; otherwise fall back to a `//!` container comment.
    const doc = own_doc orelse try containerDoc(a, ast, members);
    try registerType(a, index, name, doc, field_names.items, field_docs.items);
}

/// A `pub const V = schema.Schema(ver, "wire.name", Payload)` decl awaiting
/// reconstruction: `name`/`version` are the schema identity, `payload` the AST node of
/// the payload type expression, `doc` the comment on the decl.
const SchemaDecl = struct { name: []const u8, version: u32, payload: Ast.Node.Index, doc: ?[]const u8 };

/// Per-file scratch threaded through the `walkContainer` recursion: every named decl's
/// init expression (so a `Schema()` payload can be resolved by name once the whole file
/// is seen) and the list of `Schema()` decls to reconstruct.
const MergeCtx = struct {
    decls: std.StringHashMapUnmanaged(Ast.Node.Index) = .empty,
    pending: std.ArrayListUnmanaged(SchemaDecl) = .empty,
};

/// If `init_node` is a `Schema(ver, "name", Payload)` call, record it for later
/// reconstruction. Anything else is ignored.
fn collectSchemaDecl(
    a: std.mem.Allocator,
    ast: Ast,
    var_decl: Ast.full.VarDecl,
    init_node: Ast.Node.Index,
    merge: *MergeCtx,
) !void {
    var buf: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buf, init_node) orelse return;

    // The callee's last token names the function: `schema.Schema` or `Schema`.
    const callee = ast.lastToken(call.ast.fn_expr);
    if (ast.tokenTag(callee) != .identifier) return;
    if (!std.mem.eql(u8, unquoteIdentifier(ast.tokenSlice(callee)), "Schema")) return;
    if (call.ast.params.len < 3) return;

    const version = intLiteralValue(ast, call.ast.params[0]) orelse return;
    const wire_name = stringLiteralValue(a, ast, call.ast.params[1]) catch return orelse return;
    try merge.pending.append(a, .{
        .name = wire_name,
        .version = version,
        .payload = call.ast.params[2],
        .doc = try docBefore(a, ast, var_decl.firstToken()),
    });
}

/// For each collected `Schema()` decl, register its reconstructed merged type under its
/// `(name, version)`: the envelope fields, then the payload's fields resolved through any
/// `MergeStructs`/alias/inline-struct nesting, carrying over every doc comment found.
fn resolveSchemaMerges(a: std.mem.Allocator, index: *DocIndex, ast: Ast, merge: *MergeCtx) !void {
    for (merge.pending.items) |sd| {
        const payload = try resolveFields(a, ast, sd.payload, merge, 0);

        // Envelope field docs first, then the payload's.
        const docs = try a.alloc(FieldDoc, schema_envelope.len + payload.len);
        inline for (schema_envelope, 0..) |f, i| docs[i] = f;
        @memcpy(docs[schema_envelope.len..], payload);

        const gop = try index.schemas.getOrPut(a, sd.name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, sd.name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(a, .{
            .version = sd.version,
            .doc = sd.doc,
            .field_docs = docs,
        });
    }
}

/// The documented fields of a type expression node: an inline `struct {…}` is parsed
/// directly; a `MergeStructs(A, B)` (or nested `Schema(...)`) call is resolved
/// component-wise; a bare identifier is followed to its decl. An unresolvable reference
/// (e.g. an imported type) contributes nothing rather than failing. `depth` guards
/// against decl cycles.
fn resolveFields(a: std.mem.Allocator, ast: Ast, node: Ast.Node.Index, merge: *MergeCtx, depth: u8) std.mem.Allocator.Error![]const FieldDoc {
    if (depth > 16) return &.{};

    var cbuf: [2]Ast.Node.Index = undefined;
    if (ast.fullContainerDecl(&cbuf, node)) |container| {
        return try parseStructFieldDocs(a, ast, container.ast.members);
    }

    var callbuf: [1]Ast.Node.Index = undefined;
    if (ast.fullCall(&callbuf, node)) |call| {
        const callee = unquoteIdentifier(ast.tokenSlice(ast.lastToken(call.ast.fn_expr)));
        if (std.mem.eql(u8, callee, "MergeStructs") and call.ast.params.len >= 2) {
            const lhs = try resolveFields(a, ast, call.ast.params[0], merge, depth + 1);
            const rhs = try resolveFields(a, ast, call.ast.params[1], merge, depth + 1);
            return try std.mem.concat(a, FieldDoc, &.{ lhs, rhs });
        }
        if (std.mem.eql(u8, callee, "Schema") and call.ast.params.len >= 3) {
            return try resolveFields(a, ast, call.ast.params[2], merge, depth + 1);
        }
        return &.{};
    }

    // A bare identifier: follow it to its decl if it is local.
    const first = ast.firstToken(node);
    if (first == ast.lastToken(node) and ast.tokenTag(first) == .identifier) {
        const ref = unquoteIdentifier(ast.tokenSlice(first));
        if (merge.decls.get(ref)) |decl_node| return try resolveFields(a, ast, decl_node, merge, depth + 1);
    }
    return &.{};
}

/// The `///`-documented fields directly declared in a struct body.
fn parseStructFieldDocs(a: std.mem.Allocator, ast: Ast, members: []const Ast.Node.Index) ![]const FieldDoc {
    var docs: std.ArrayListUnmanaged(FieldDoc) = .empty;
    for (members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        if (field.ast.tuple_like) continue;
        if (try docBefore(a, ast, field.firstToken())) |doc| {
            const field_name = try a.dupe(u8, unquoteIdentifier(ast.tokenSlice(field.ast.main_token)));
            try docs.append(a, .{ .name = field_name, .doc = doc });
        }
    }
    return docs.items;
}

/// The value of a string-literal node (`"client.heartbeat"` → `client.heartbeat`), or
/// null when the node is not a simple string literal.
fn stringLiteralValue(a: std.mem.Allocator, ast: Ast, node: Ast.Node.Index) !?[]const u8 {
    const tok = ast.firstToken(node);
    if (tok != ast.lastToken(node) or ast.tokenTag(tok) != .string_literal) return null;
    const raw = ast.tokenSlice(tok);
    return std.zig.string_literal.parseAlloc(a, raw) catch null;
}

/// The value of an integer-literal node (the `1` in `Schema(1, …)`), or null when the
/// node is not a simple integer literal that fits a `u32`.
fn intLiteralValue(ast: Ast, node: Ast.Node.Index) ?u32 {
    const tok = ast.firstToken(node);
    if (tok != ast.lastToken(node) or ast.tokenTag(tok) != .number_literal) return null;
    return std.fmt.parseInt(u32, ast.tokenSlice(tok), 0) catch null;
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

test "Schema() decls reconstruct the merged payload type, keyed by wire name" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    // Mirrors the protocol shape, covering all three payload forms: a bare struct, a
    // nested `MergeStructs` (of a struct + an inline struct), and an inline struct.
    const src =
        \\const schema = @import("schema.zig");
        \\const klib = @import("klib");
        \\pub const ClientHeartbeat = struct {
        \\    /// An id that identifies the client.
        \\    id: []const u8,
        \\};
        \\pub const ClientStatus = klib.meta.MergeStructs(ClientHeartbeat, struct {
        \\    /// The current power state.
        \\    status: u8,
        \\});
        \\pub const Client = struct {
        \\    pub const Heartbeat = struct {
        \\        /// Version 1 of the heartbeat schema.
        \\        pub const V1 = schema.Schema(1, "client.heartbeat", ClientHeartbeat);
        \\    };
        \\    pub const Status = struct {
        \\        pub const V1 = schema.Schema(1, "client.status", ClientStatus);
        \\    };
        \\    pub const Reannounce = struct {
        \\        pub const V1 = schema.Schema(1, "client.reannounce", struct {
        \\            /// Why the reannounce was requested.
        \\            reason: []const u8,
        \\        });
        \\    };
        \\};
    ;
    try indexSource(std.testing.allocator, &index, src);

    // Bare-struct payload: decl doc + payload field doc + envelope field doc.
    try std.testing.expectEqualStrings("Version 1 of the heartbeat schema.", index.schemaDoc("client.heartbeat", 1).?);
    try std.testing.expectEqualStrings("An id that identifies the client.", index.schemaFieldDoc("client.heartbeat", 1, "id").?);
    try std.testing.expectEqualStrings("The version of the schema.", index.schemaFieldDoc("client.heartbeat", 1, "schema_version").?);
    try std.testing.expect(index.hasSchema("client.heartbeat", 1));
    try std.testing.expect(!index.hasSchema("client.heartbeat", 2));

    // Nested MergeStructs payload: fields from both the aliased struct and the inline one.
    try std.testing.expectEqualStrings("An id that identifies the client.", index.schemaFieldDoc("client.status", 1, "id").?);
    try std.testing.expectEqualStrings("The current power state.", index.schemaFieldDoc("client.status", 1, "status").?);

    // Inline-struct payload.
    try std.testing.expectEqualStrings("Why the reannounce was requested.", index.schemaFieldDoc("client.reannounce", 1, "reason").?);

    try std.testing.expect(index.schemaDoc("nonexistent", 1) == null);

    // A bare type in the same file is unaffected: it still resolves through the
    // bare-name + field-set path (the road HTTP/OpenAPI bare types travel).
    try std.testing.expectEqualStrings(
        "An id that identifies the client.",
        index.fieldDoc("ClientHeartbeat", "id", &.{"id"}).?,
    );
}

test "same schema name, different versions resolve independently" {
    var index: DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();

    // `Client.V1` and `Client.V2` share the wire name "client" but differ in version
    // and fields — identity is (name, version), not name alone.
    const src =
        \\const schema = @import("schema.zig");
        \\pub const Client = struct {
        \\    /// Version 1 of the client schema.
        \\    pub const V1 = schema.Schema(1, "client", struct {
        \\        /// The client's display name.
        \\        name: []const u8,
        \\    });
        \\    /// Version 2 of the client schema.
        \\    pub const V2 = schema.Schema(2, "client", struct {
        \\        /// The client's stable id.
        \\        id: []const u8,
        \\    });
        \\};
    ;
    try indexSource(std.testing.allocator, &index, src);

    try std.testing.expectEqualStrings("Version 1 of the client schema.", index.schemaDoc("client", 1).?);
    try std.testing.expectEqualStrings("Version 2 of the client schema.", index.schemaDoc("client", 2).?);
    try std.testing.expectEqualStrings("The client's display name.", index.schemaFieldDoc("client", 1, "name").?);
    try std.testing.expectEqualStrings("The client's stable id.", index.schemaFieldDoc("client", 2, "id").?);
    // V1's field does not leak into V2 and vice versa.
    try std.testing.expect(index.schemaFieldDoc("client", 2, "name") == null);
    try std.testing.expect(index.schemaFieldDoc("client", 1, "id") == null);
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
