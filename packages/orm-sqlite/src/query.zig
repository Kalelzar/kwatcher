const std = @import("std");
const model = @import("model.zig");
const dbm = @import("db.zig");

const Db = dbm.Db;
const Stmt = dbm.Stmt;
const execNext = dbm.execNext;

// Typestate chain: Query.from -> FromQuery(join, select) ->
// SelectedQuery(where, orderby) -> WhereQuery(orderby) -> OrderedQuery.
// Illegal orders (where after orderby, select twice) simply don't have
// the method. SQL text is comptime; bound values travel as fields.

pub const Op = enum { equals, not_equals, lt, lte, gt, gte, like };
pub const Dir = enum { asc, desc };

fn opSql(comptime op: Op) []const u8 {
    return switch (op) {
        .equals => "=",
        .not_equals => "<>",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        .like => "LIKE",
    };
}

const QTable = struct { alias: []const u8, T: type };
const QSelect = struct { table: []const u8, column: []const u8, out: [:0]const u8 };
const QState = struct {
    tables: []const QTable,
    from_join: []const u8,
    selects: []const QSelect = &.{},
};

fn tableByAlias(comptime s: QState, comptime alias: []const u8) type {
    for (s.tables) |t| {
        if (std.mem.eql(u8, t.alias, alias)) return t.T;
    }
    @compileError("Unknown table alias '" ++ alias ++ "'");
}

/// The Zig type a select on this column yields (markers stripped).
fn columnZigType(comptime T: type, comptime col: []const u8) type {
    const F = @FieldType(@FieldType(T, "data"), col);
    const ti = @typeInfo(F);
    if (ti == .optional) return ?model.stripMarker(ti.optional.child);
    if (ti == .pointer and ti.pointer.size == .slice and ti.pointer.child != u8) {
        @compileError("'" ++ col ++ "' is a relation, not a column.");
    }
    return model.stripMarker(F);
}

const Resolved = struct { sql: []const u8, T: type };

/// Maps an output alias from select() back to its qualified column.
fn resolveOut(comptime s: QState, comptime out: []const u8) Resolved {
    for (s.selects) |sel| {
        if (std.mem.eql(u8, sel.out, out)) {
            return .{
                .sql = sel.table ++ "." ++ sel.column,
                .T = columnZigType(tableByAlias(s, sel.table), sel.column),
            };
        }
    }
    @compileError("Unknown output alias '" ++ out ++ "'. Aliases come from select().");
}

fn OutType(comptime s: QState, comptime col: @Type(.enum_literal)) type {
    return resolveOut(s, @tagName(col)).T;
}

fn whereFrag(comptime s: QState, comptime col: @Type(.enum_literal), comptime op: Op) []const u8 {
    return resolveOut(s, @tagName(col)).sql ++ " " ++ opSql(op) ++ " ?";
}

fn orderFrag(comptime s: QState, comptime col: @Type(.enum_literal), comptime dir: Dir) []const u8 {
    return resolveOut(s, @tagName(col)).sql ++ switch (dir) {
        .asc => " ASC",
        .desc => " DESC",
    };
}

fn buildSql(comptime s: QState, comptime where_frag: ?[]const u8, comptime order_frag: ?[]const u8) []const u8 {
    comptime var sql: []const u8 = "SELECT ";
    for (s.selects, 0..) |sel, i| {
        if (i != 0) sql = sql ++ ",";
        sql = sql ++ sel.table ++ "." ++ sel.column ++ " AS " ++ sel.out;
    }
    sql = sql ++ " FROM " ++ s.from_join;
    if (where_frag) |w| sql = sql ++ " WHERE " ++ w;
    if (order_frag) |o| sql = sql ++ " ORDER BY " ++ o;
    return sql;
}

/// The result-row struct for a projection: field names are the output
/// aliases, field types come from the underlying columns.
pub fn RowType(comptime s: QState) type {
    comptime var fields: [s.selects.len]std.builtin.Type.StructField = undefined;
    for (s.selects, 0..) |sel, i| {
        const T = columnZigType(tableByAlias(s, sel.table), sel.column);
        fields[i] = .{
            .name = sel.out,
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn fromState(comptime alias: @Type(.enum_literal), comptime T: type) QState {
    model.assertTable(T);
    const a = @tagName(alias);
    return .{
        .tables = &.{.{ .alias = a, .T = T }},
        .from_join = @tagName(T.name) ++ " " ++ a,
    };
}

fn appendJoin(comptime s: QState, comptime a: []const u8, comptime T: type, comptime on: []const u8) QState {
    for (s.tables) |t| {
        if (std.mem.eql(u8, t.alias, a)) @compileError("Duplicate table alias '" ++ a ++ "'");
    }
    return .{
        .tables = s.tables ++ &[_]QTable{.{ .alias = a, .T = T }},
        .from_join = s.from_join ++ " JOIN " ++ @tagName(T.name) ++ " " ++ a ++ " ON " ++ on,
        .selects = s.selects,
    };
}

fn joinState(comptime s: QState, comptime alias: @Type(.enum_literal), comptime T: type) QState {
    model.assertTable(T);
    const a = @tagName(alias);
    // Infer the join condition from FK metadata, in either direction.
    // Exactly one candidate must exist; more than one means the schema
    // has several FK paths and the caller must pick with joinOn.
    comptime var candidates: []const []const u8 = &.{};
    for (s.tables) |t| {
        for (model.fkFieldNames(T, t.T)) |col| {
            candidates = candidates ++ &[_][]const u8{a ++ "." ++ col ++ " = " ++ t.alias ++ "." ++ model.PrimaryOf(t.T)};
        }
        for (model.fkFieldNames(t.T, T)) |col| {
            candidates = candidates ++ &[_][]const u8{t.alias ++ "." ++ col ++ " = " ++ a ++ "." ++ model.PrimaryOf(T)};
        }
    }
    if (candidates.len == 0) {
        @compileError("No foreign-key relation between '" ++ @tagName(T.name) ++ "' and any joined table.");
    }
    if (candidates.len > 1) {
        comptime var list: []const u8 = "";
        for (candidates, 0..) |cand, i| {
            if (i != 0) list = list ++ ", ";
            list = list ++ cand;
        }
        @compileError("Ambiguous join for '" ++ @tagName(T.name) ++ "' (candidates: " ++ list ++ "). Use joinOn(alias, Table, .fk_column) to pick one.");
    }
    return appendJoin(s, a, T, candidates[0]);
}

fn joinOnState(comptime s: QState, comptime alias: @Type(.enum_literal), comptime T: type, comptime fk_col: @Type(.enum_literal)) QState {
    model.assertTable(T);
    const a = @tagName(alias);
    const colname = @tagName(fk_col);
    comptime var matches: []const []const u8 = &.{};
    for (s.tables) |t| {
        for (model.fkFieldNames(T, t.T)) |col| {
            if (std.mem.eql(u8, col, colname)) {
                matches = matches ++ &[_][]const u8{a ++ "." ++ col ++ " = " ++ t.alias ++ "." ++ model.PrimaryOf(t.T)};
            }
        }
        for (model.fkFieldNames(t.T, T)) |col| {
            if (std.mem.eql(u8, col, colname)) {
                matches = matches ++ &[_][]const u8{t.alias ++ "." ++ col ++ " = " ++ a ++ "." ++ model.PrimaryOf(T)};
            }
        }
    }
    if (matches.len == 0) {
        @compileError("No foreign-key column '" ++ colname ++ "' connecting '" ++ @tagName(T.name) ++ "' with the joined tables.");
    }
    if (matches.len > 1) {
        @compileError("Foreign-key column '" ++ colname ++ "' is ambiguous across the joined tables.");
    }
    return appendJoin(s, a, T, matches[0]);
}

fn selectState(comptime s: QState, comptime proj: anytype) QState {
    comptime var sels: []const QSelect = &.{};
    for (std.meta.fields(@TypeOf(proj))) |tf| {
        const T = tableByAlias(s, tf.name);
        const inner = @field(proj, tf.name);
        for (std.meta.fields(@TypeOf(inner))) |cf| {
            if (!@hasField(@FieldType(T, "data"), cf.name)) {
                @compileError("Table alias '" ++ tf.name ++ "' has no column '" ++ cf.name ++ "'");
            }
            const outname = @tagName(@field(inner, cf.name));
            for (sels) |sel| {
                if (std.mem.eql(u8, sel.out, outname)) {
                    @compileError("Duplicate output alias '" ++ outname ++ "'");
                }
            }
            sels = sels ++ &[_]QSelect{.{ .table = tf.name, .column = cf.name, .out = outname }};
        }
    }
    if (sels.len == 0) @compileError("Empty selection.");
    return .{ .tables = s.tables, .from_join = s.from_join, .selects = sels };
}

fn FromQuery(comptime s: QState) type {
    return struct {
        const Self = @This();
        pub fn join(self: Self, comptime alias: @Type(.enum_literal), comptime T: type) FromQuery(joinState(s, alias, T)) {
            _ = self;
            return .{};
        }
        /// Explicit FK-column pick for when join() would be ambiguous
        /// (several FKs between the two tables).
        pub fn joinOn(self: Self, comptime alias: @Type(.enum_literal), comptime T: type, comptime fk_col: @Type(.enum_literal)) FromQuery(joinOnState(s, alias, T, fk_col)) {
            _ = self;
            return .{};
        }
        pub fn select(self: Self, comptime proj: anytype) SelectedQuery(selectState(s, proj)) {
            _ = self;
            return .{};
        }
    };
}

fn SelectedQuery(comptime s: QState) type {
    return struct {
        const Self = @This();
        pub const Row = RowType(s);
        stmt: ?Stmt = null,
        pub fn where(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: OutType(s, col)) WhereQuery(s, whereFrag(s, col, op), &.{OutType(s, col)}) {
            _ = self;
            return .{ .args = .{value} };
        }
        pub fn orderby(self: Self, comptime col: @Type(.enum_literal), comptime dir: Dir) OrderedQuery(s, null, orderFrag(s, col, dir), &.{}) {
            _ = self;
            return .{ .args = .{} };
        }
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime buildSql(s, null, null);
        }
        pub fn next(self: *Self, db: *Db, allocator: std.mem.Allocator) !?Row {
            return execNext(Row, self.sql(), &self.stmt, .{}, db, allocator);
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator; // row data is caller-owned; nothing duped here
            if (self.stmt) |stmt| stmt.deinit();
            self.stmt = null;
        }
    };
}

fn WhereQuery(comptime s: QState, comptime where_frag: []const u8, comptime Vs: []const type) type {
    return struct {
        const Self = @This();
        pub const Row = RowType(s);
        args: std.meta.Tuple(Vs),
        stmt: ?Stmt = null,
        // Conditions chain flat, so SQL precedence applies (AND binds
        // tighter than OR); grouping/parens are a later feature.
        pub fn andWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: OutType(s, col)) WhereQuery(s, where_frag ++ " AND " ++ whereFrag(s, col, op), Vs ++ &[_]type{OutType(s, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{OutType(s, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn orWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: OutType(s, col)) WhereQuery(s, where_frag ++ " OR " ++ whereFrag(s, col, op), Vs ++ &[_]type{OutType(s, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{OutType(s, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn orderby(self: Self, comptime col: @Type(.enum_literal), comptime dir: Dir) OrderedQuery(s, where_frag, orderFrag(s, col, dir), Vs) {
            return .{ .args = self.args };
        }
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime buildSql(s, where_frag, null);
        }
        pub fn next(self: *Self, db: *Db, allocator: std.mem.Allocator) !?Row {
            return execNext(Row, self.sql(), &self.stmt, self.args, db, allocator);
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator; // row data is caller-owned; nothing duped here
            if (self.stmt) |stmt| stmt.deinit();
            self.stmt = null;
        }
    };
}

fn OrderedQuery(comptime s: QState, comptime where_frag: ?[]const u8, comptime order_frag: []const u8, comptime Vs: []const type) type {
    return struct {
        const Self = @This();
        pub const Row = RowType(s);
        args: std.meta.Tuple(Vs),
        stmt: ?Stmt = null,
        // Deliberately no where(): WHERE cannot follow ORDER BY.
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime buildSql(s, where_frag, order_frag);
        }
        pub fn next(self: *Self, db: *Db, allocator: std.mem.Allocator) !?Row {
            return execNext(Row, self.sql(), &self.stmt, self.args, db, allocator);
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator; // row data is caller-owned; nothing duped here
            if (self.stmt) |stmt| stmt.deinit();
            self.stmt = null;
        }
    };
}

// ==== DML: insert / update / delete ================================
// Single-table, comptime column lists, typed binds, same typestate
// style as the select chain:
//   Query.insertInto(T).values(.{...}).exec(db)
//   Query.update(T).set(.{...}).where(...).exec(db)
//   Query.delete(T).where(...).exec(db)
// DML where() takes raw column names (there is no projection to alias).

fn ColType(comptime T: type, comptime col: @Type(.enum_literal)) type {
    const name = @tagName(col);
    if (!@hasField(@FieldType(T, "data"), name)) {
        @compileError("Table '" ++ @tagName(T.name) ++ "' has no column '" ++ name ++ "'");
    }
    return columnZigType(T, name);
}

fn dmlWhereFrag(comptime T: type, comptime col: @Type(.enum_literal), comptime op: Op) []const u8 {
    _ = ColType(T, col); // column-existence check
    return @tagName(col) ++ " " ++ opSql(op) ++ " ?";
}

/// The column names named by an anonymous `.{ .col = value, ... }` literal,
/// validated against the table. Order = literal order = bind order.
fn dmlCols(comptime T: type, comptime V: type) []const []const u8 {
    comptime var cols: []const []const u8 = &.{};
    for (std.meta.fields(V)) |f| {
        if (!@hasField(@FieldType(T, "data"), f.name)) {
            @compileError("Table '" ++ @tagName(T.name) ++ "' has no column '" ++ f.name ++ "'");
        }
        cols = cols ++ &[_][]const u8{f.name};
    }
    if (cols.len == 0) @compileError("Empty column list.");
    return cols;
}

fn colTypes(comptime T: type, comptime cols: []const []const u8) []const type {
    comptime var ts: []const type = &.{};
    for (cols) |c| ts = ts ++ &[_]type{columnZigType(T, c)};
    return ts;
}

fn insertSql(comptime T: type, comptime cols: []const []const u8) []const u8 {
    comptime var res: []const u8 = "INSERT INTO " ++ @tagName(T.name) ++ " (";
    for (cols, 0..) |c, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ c;
    }
    res = res ++ ") VALUES (";
    for (cols, 0..) |_, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ "?";
    }
    return res ++ ")";
}

fn updateSql(comptime T: type, comptime cols: []const []const u8, comptime where_frag: ?[]const u8) []const u8 {
    comptime var res: []const u8 = "UPDATE " ++ @tagName(T.name) ++ " SET ";
    for (cols, 0..) |c, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ c ++ " = ?";
    }
    if (where_frag) |w| res = res ++ " WHERE " ++ w;
    return res;
}

fn deleteSql(comptime T: type, comptime where_frag: ?[]const u8) []const u8 {
    comptime var res: []const u8 = "DELETE FROM " ++ @tagName(T.name);
    if (where_frag) |w| res = res ++ " WHERE " ++ w;
    return res;
}

fn InsertQuery(comptime T: type, comptime cols: []const []const u8) type {
    return struct {
        const Self = @This();
        args: std.meta.Tuple(colTypes(T, cols)),
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime insertSql(T, cols);
        }
        pub fn exec(self: Self, db: *Db) !void {
            return dbm.execDml(db, self.sql(), self.args);
        }
    };
}

fn InsertInto(comptime T: type) type {
    return struct {
        /// Columns omitted from the literal fall back to sqlite's defaults
        /// (e.g. an omitted INTEGER PRIMARY KEY gets the next rowid).
        pub fn values(self: @This(), vals: anytype) InsertQuery(T, dmlCols(T, @TypeOf(vals))) {
            _ = self;
            var args: std.meta.Tuple(colTypes(T, dmlCols(T, @TypeOf(vals)))) = undefined;
            inline for (std.meta.fields(@TypeOf(vals)), 0..) |f, i| {
                args[i] = @field(vals, f.name);
            }
            return .{ .args = args };
        }
    };
}

fn UpdateSet(comptime T: type, comptime cols: []const []const u8) type {
    return struct {
        const Self = @This();
        args: std.meta.Tuple(colTypes(T, cols)),
        pub fn where(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) UpdateWhere(T, cols, dmlWhereFrag(T, col, op), colTypes(T, cols) ++ &[_]type{ColType(T, col)}) {
            var args: std.meta.Tuple(colTypes(T, cols) ++ &[_]type{ColType(T, col)}) = undefined;
            inline for (0..cols.len) |i| args[i] = self.args[i];
            args[cols.len] = value;
            return .{ .args = args };
        }
        /// No where(): updates every row. Deliberate, but spell it out.
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime updateSql(T, cols, null);
        }
        pub fn exec(self: Self, db: *Db) !void {
            return dbm.execDml(db, self.sql(), self.args);
        }
    };
}

fn UpdateWhere(comptime T: type, comptime cols: []const []const u8, comptime where_frag: []const u8, comptime Vs: []const type) type {
    return struct {
        const Self = @This();
        args: std.meta.Tuple(Vs),
        pub fn andWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) UpdateWhere(T, cols, where_frag ++ " AND " ++ dmlWhereFrag(T, col, op), Vs ++ &[_]type{ColType(T, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{ColType(T, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn orWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) UpdateWhere(T, cols, where_frag ++ " OR " ++ dmlWhereFrag(T, col, op), Vs ++ &[_]type{ColType(T, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{ColType(T, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime updateSql(T, cols, where_frag);
        }
        pub fn exec(self: Self, db: *Db) !void {
            return dbm.execDml(db, self.sql(), self.args);
        }
    };
}

fn UpdateTable(comptime T: type) type {
    return struct {
        pub fn set(self: @This(), vals: anytype) UpdateSet(T, dmlCols(T, @TypeOf(vals))) {
            _ = self;
            var args: std.meta.Tuple(colTypes(T, dmlCols(T, @TypeOf(vals)))) = undefined;
            inline for (std.meta.fields(@TypeOf(vals)), 0..) |f, i| {
                args[i] = @field(vals, f.name);
            }
            return .{ .args = args };
        }
    };
}

fn DeleteQuery(comptime T: type) type {
    return struct {
        const Self = @This();
        pub fn where(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) DeleteWhere(T, dmlWhereFrag(T, col, op), &.{ColType(T, col)}) {
            _ = self;
            return .{ .args = .{value} };
        }
        /// No where(): deletes every row. Deliberate, but spell it out.
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime deleteSql(T, null);
        }
        pub fn exec(self: Self, db: *Db) !void {
            return dbm.execDml(db, self.sql(), .{});
        }
    };
}

fn DeleteWhere(comptime T: type, comptime where_frag: []const u8, comptime Vs: []const type) type {
    return struct {
        const Self = @This();
        args: std.meta.Tuple(Vs),
        pub fn andWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) DeleteWhere(T, where_frag ++ " AND " ++ dmlWhereFrag(T, col, op), Vs ++ &[_]type{ColType(T, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{ColType(T, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn orWhere(self: Self, comptime col: @Type(.enum_literal), comptime op: Op, value: ColType(T, col)) DeleteWhere(T, where_frag ++ " OR " ++ dmlWhereFrag(T, col, op), Vs ++ &[_]type{ColType(T, col)}) {
            var args: std.meta.Tuple(Vs ++ &[_]type{ColType(T, col)}) = undefined;
            inline for (0..Vs.len) |i| args[i] = self.args[i];
            args[Vs.len] = value;
            return .{ .args = args };
        }
        pub fn sql(self: Self) []const u8 {
            _ = self;
            return comptime deleteSql(T, where_frag);
        }
        pub fn exec(self: Self, db: *Db) !void {
            return dbm.execDml(db, self.sql(), self.args);
        }
    };
}

pub const Query = struct {
    pub fn from(comptime alias: @Type(.enum_literal), comptime T: type) FromQuery(fromState(alias, T)) {
        return .{};
    }
    pub fn insertInto(comptime T: type) InsertInto(T) {
        comptime model.assertTable(T);
        return .{};
    }
    pub fn update(comptime T: type) UpdateTable(T) {
        comptime model.assertTable(T);
        return .{};
    }
    pub fn delete(comptime T: type) DeleteQuery(T) {
        comptime model.assertTable(T);
        return .{};
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
