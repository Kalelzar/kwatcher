//! kw-orm-sqlite: a comptime schema/ORM sketch over the zqlite bindings.
//!
//! Tables are declared with the `Table`/`PK`/`FK` markers (model.zig); the
//! reflection walk turns them into a serializable IR (ir.zig) that the DDL
//! generator (generator.zig) renders. Queries are built with a typestate
//! chain (query.zig) and run against a connection (db.zig) that wraps zqlite.

const std = @import("std");

pub const model = @import("model.zig");
pub const ir = @import("ir.zig");
pub const generator = @import("generator.zig");
pub const migration = @import("migration.zig");
pub const runner = @import("runner.zig");
pub const query = @import("query.zig");
pub const db = @import("db.zig");

// ==== Public surface ===============================================

// Schema declaration.
pub const Table = model.Table;
pub const PK = model.PK;
pub const FK = model.FK;
pub const Unique = model.Unique;
pub const PrimaryOf = model.PrimaryOf;

// Schema IR + reflection.
pub const Affinity = ir.Affinity;
pub const FkIr = ir.FkIr;
pub const ColumnIr = ir.ColumnIr;
pub const TableIr = ir.TableIr;
pub const Schema = ir.Schema;
pub const TableIrOf = ir.TableIrOf;
pub const SchemaIr = ir.SchemaIr;

// DDL generation.
pub const renderTable = generator.renderTable;
pub const TableGen = generator.TableGen;

// Migrations.
pub const MigrationOp = migration.MigrationOp;
pub const diff = migration.diff;
pub const renderMigration = migration.renderMigration;

// Query building.
pub const Query = query.Query;
pub const Op = query.Op;
pub const Dir = query.Dir;

// Connection.
pub const Db = db.Db;
pub const Stmt = db.Stmt;

// ==== Tests ========================================================
// The example tables double as usage documentation and as fixtures for
// the tests below.

const Entity = Table(
    .entity,
    struct {
        id: PK(u64),
        // Reverse side of Other.parent (one-to-many): emits no column of its
        // own. If Other's side were also a slice, this would need a junction
        // table (many-to-many, not implemented yet).
        next_id: []FK(Other, u64),
        name: []const u8,
    },
);

const Other = Table(
    .other,
    struct {
        id: PK(u64),
        parent: FK(Entity, u64),
        kind: []const u8,
        note: ?[]const u8,
        flag: bool,
    },
);

const User = Table(
    .user,
    struct {
        id: PK(u64),
        login: []const u8,
    },
);

// Two FKs to the same table: join(.u, User) is ambiguous here and
// requires joinOn(.u, User, .author_id / .editor_id).
const Post = Table(
    .post,
    struct {
        id: PK(u64),
        author_id: FK(User, u64),
        editor_id: FK(User, u64),
        title: []const u8,
    },
);

fn getAllKinds(conn: *Db, id: u64, allocator: std.mem.Allocator) ![]const []const u8 {
    // This is just a prepared statement.
    var q = Query
        .from(.o, Other)
        .select(.{
            .o = .{ .kind = .kind, .parent = .id },
        })
        .where(.id, .equals, id);

    var al: std.ArrayList([]const u8) = .empty;
    defer al.deinit(allocator);
    defer q.deinit(allocator);
    while (try q.next(conn, allocator)) |n| {
        // n here is a struct { kind: []const u8, id: u64 };
        // kind is allocated with the allocator given to next.
        try al.append(allocator, n.kind);
    }

    return try al.toOwnedSlice(allocator);
}

fn openSeededDb() !Db {
    var conn = try Db.open(":memory:");
    errdefer conn.close();
    try conn.exec(TableGen(Entity));
    try conn.exec(TableGen(Other));
    try conn.exec("INSERT INTO entity (id, name) VALUES (1, 'root')");
    try conn.exec("INSERT INTO other (id, parent, kind, note, flag) VALUES (1, 1, 'sensor', NULL, 1)");
    try conn.exec("INSERT INTO other (id, parent, kind, note, flag) VALUES (2, 1, 'actuator', 'spare', 0)");
    return conn;
}

test "IR rendering matches the legacy string output" {
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS entity(id INTEGER PRIMARY KEY NOT NULL,name TEXT NOT NULL)",
        TableGen(Entity),
    );
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS other(id INTEGER PRIMARY KEY NOT NULL,parent INTEGER REFERENCES entity(id) NOT NULL,kind TEXT NOT NULL,note TEXT,flag INTEGER NOT NULL)",
        TableGen(Other),
    );
}

test "relation-only fields emit no column" {
    const schema = comptime SchemaIr(.{ Entity, Other });
    try std.testing.expectEqual(@as(usize, 2), schema.tables[0].columns.len);
    try std.testing.expectEqualStrings("id", schema.tables[0].columns[0].name);
    try std.testing.expectEqualStrings("name", schema.tables[0].columns[1].name);
    try std.testing.expect(schema.tables[1].columns[3].nullable); // note
    try std.testing.expectEqualStrings("entity", schema.tables[1].columns[1].fk.?.table);
}

test "query builder: sketch query SQL, row type, bound arg" {
    var conn = try openSeededDb();
    defer conn.close();
    var q = Query
        .from(.o, Other)
        .select(.{ .o = .{ .kind = .kind, .parent = .id } })
        .where(.id, .equals, @as(u64, 7));
    defer q.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "SELECT o.kind AS kind,o.parent AS id FROM other o WHERE o.parent = ?",
        q.sql(),
    );
    const Q = @TypeOf(q);
    try std.testing.expect(@FieldType(Q.Row, "kind") == []const u8);
    try std.testing.expect(@FieldType(Q.Row, "id") == u64);
    try std.testing.expectEqual(@as(u64, 7), q.args[0]);
    // parent 7 has no rows; the query still round-trips through sqlite.
    try std.testing.expect((try q.next(&conn, std.testing.allocator)) == null);
}

test "end-to-end: joined query with optional column against sqlite3" {
    var conn = try openSeededDb();
    defer conn.close();
    var q = Query
        .from(.e, Entity)
        .join(.o, Other)
        .select(.{ .o = .{ .kind = .kind, .note = .note }, .e = .{ .id = .oid } })
        .where(.oid, .equals, @as(u64, 1))
        .orderby(.kind, .asc);
    defer q.deinit(std.testing.allocator);

    const r1 = (try q.next(&conn, std.testing.allocator)).?;
    defer std.testing.allocator.free(r1.kind);
    defer if (r1.note) |n| std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("actuator", r1.kind);
    try std.testing.expectEqualStrings("spare", r1.note.?);
    try std.testing.expectEqual(@as(u64, 1), r1.oid);

    const r2 = (try q.next(&conn, std.testing.allocator)).?;
    defer std.testing.allocator.free(r2.kind);
    try std.testing.expectEqualStrings("sensor", r2.kind);
    try std.testing.expectEqual(@as(?[]const u8, null), r2.note);

    try std.testing.expect((try q.next(&conn, std.testing.allocator)) == null);
}

test "query builder: and/or where chaining" {
    const q = Query
        .from(.o, Other)
        .select(.{ .o = .{ .kind = .kind, .parent = .pid, .flag = .flag } })
        .where(.pid, .equals, @as(u64, 1))
        .andWhere(.flag, .equals, true)
        .orWhere(.kind, .like, "sensor-%");
    try std.testing.expectEqualStrings(
        "SELECT o.kind AS kind,o.parent AS pid,o.flag AS flag FROM other o" ++
            " WHERE o.parent = ? AND o.flag = ? OR o.kind LIKE ?",
        q.sql(),
    );
    try std.testing.expectEqual(@as(u64, 1), q.args[0]);
    try std.testing.expectEqual(true, q.args[1]);
    try std.testing.expectEqualStrings("sensor-%", q.args[2]);

    // Ordering after a chained where keeps the args tuple intact.
    const q2 = q.orderby(.kind, .asc);
    try std.testing.expectEqual(@as(u64, 1), q2.args[0]);
}

test "query builder: inferred joins in both directions" {
    const q = Query
        .from(.e, Entity)
        .join(.o, Other)
        .select(.{ .o = .{ .kind = .kind }, .e = .{ .id = .oid } })
        .where(.oid, .equals, @as(u64, 3))
        .orderby(.kind, .desc);
    try std.testing.expectEqualStrings(
        "SELECT o.kind AS kind,e.id AS oid FROM entity e JOIN other o ON o.parent = e.id WHERE e.id = ? ORDER BY o.kind DESC",
        q.sql(),
    );

    const q2 = Query
        .from(.o, Other)
        .join(.e, Entity)
        .select(.{ .e = .{ .name = .ename } })
        .orderby(.ename, .asc);
    try std.testing.expectEqualStrings(
        "SELECT e.name AS ename FROM other o JOIN entity e ON o.parent = e.id ORDER BY e.name ASC",
        q2.sql(),
    );
}

test "joinOn disambiguates multiple FKs to the same table" {
    var conn = try Db.open(":memory:");
    defer conn.close();
    try conn.exec(TableGen(User));
    try conn.exec(TableGen(Post));
    try conn.exec("INSERT INTO user (id, login) VALUES (1, 'alice')");
    try conn.exec("INSERT INTO user (id, login) VALUES (2, 'bob')");
    try conn.exec("INSERT INTO post (id, author_id, editor_id, title) VALUES (1, 1, 2, 'hello')");

    var q = Query
        .from(.p, Post)
        .joinOn(.u, User, .author_id)
        .select(.{ .u = .{ .login = .author }, .p = .{ .title = .title } })
        .where(.title, .equals, "hello");
    defer q.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "SELECT u.login AS author,p.title AS title FROM post p JOIN user u ON p.author_id = u.id WHERE p.title = ?",
        q.sql(),
    );
    const r = (try q.next(&conn, std.testing.allocator)).?;
    defer std.testing.allocator.free(r.author);
    defer std.testing.allocator.free(r.title);
    try std.testing.expectEqualStrings("alice", r.author);

    var q2 = Query
        .from(.p, Post)
        .joinOn(.u, User, .editor_id)
        .select(.{ .u = .{ .login = .editor } });
    defer q2.deinit(std.testing.allocator);
    const r2 = (try q2.next(&conn, std.testing.allocator)).?;
    defer std.testing.allocator.free(r2.editor);
    try std.testing.expectEqualStrings("bob", r2.editor);
    try std.testing.expect((try q2.next(&conn, std.testing.allocator)) == null);

    // Reverse direction: the FK column lives on the newly joined table.
    const q3 = Query
        .from(.u, User)
        .joinOn(.p, Post, .editor_id)
        .select(.{ .p = .{ .title = .title } });
    try std.testing.expectEqualStrings(
        "SELECT p.title AS title FROM user u JOIN post p ON p.editor_id = u.id",
        q3.sql(),
    );
}

// Hand-built IR fixtures for the differ tests: file scope so they are
// comptime-known.
const differ_old = Schema{ .tables = &.{
    .{ .name = "foo", .columns = &.{
        .{ .name = "id", .affinity = .integer, .pk = true },
        .{ .name = "name", .affinity = .text },
        .{ .name = "tmp", .affinity = .integer },
    } },
    .{ .name = "gone", .columns = &.{.{ .name = "id", .affinity = .integer, .pk = true }} },
} };
const differ_new = Schema{ .tables = &.{
    .{ .name = "foo", .columns = &.{
        .{ .name = "id", .affinity = .integer, .pk = true },
        .{ .name = "name", .affinity = .text },
        .{ .name = "note", .affinity = .text, .nullable = true },
    } },
    .{ .name = "bar", .columns = &.{.{ .name = "id", .affinity = .integer, .pk = true }} },
} };

const rebuild_old = Schema{ .tables = &.{.{ .name = "foo", .columns = &.{
    .{ .name = "id", .affinity = .integer, .pk = true },
    .{ .name = "name", .affinity = .text },
} }} };
const rebuild_new = Schema{ .tables = &.{.{ .name = "foo", .columns = &.{
    .{ .name = "id", .affinity = .integer, .pk = true },
    .{ .name = "name", .affinity = .text, .nullable = true },
    .{ .name = "added", .affinity = .integer },
} }} };

test "differ: identical schemas produce no ops" {
    const schema = comptime SchemaIr(.{ Entity, Other, User, Post });
    try std.testing.expectEqual(@as(usize, 0), comptime diff(schema, schema).len);
}

test "differ: cheap column and table ops render both directions" {
    const ops = comptime diff(differ_old, differ_new);
    try std.testing.expectEqual(@as(usize, 4), ops.len);
    try std.testing.expectEqualStrings(
        "ALTER TABLE foo ADD COLUMN note TEXT;\n" ++
            "ALTER TABLE foo DROP COLUMN tmp;\n" ++
            "CREATE TABLE IF NOT EXISTS bar(id INTEGER PRIMARY KEY NOT NULL);\n" ++
            "DROP TABLE gone;\n",
        comptime renderMigration(ops, .up),
    );
    // Down runs the inverse ops in reverse order; the re-added NOT NULL
    // column gets a zero default so the backfill can't fail.
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS gone(id INTEGER PRIMARY KEY NOT NULL);\n" ++
            "DROP TABLE bar;\n" ++
            "ALTER TABLE foo ADD COLUMN tmp INTEGER NOT NULL DEFAULT 0;\n" ++
            "ALTER TABLE foo DROP COLUMN note;\n",
        comptime renderMigration(ops, .down),
    );
}

test "differ: PK/FK column changes force a rebuild" {
    // Nullability change on 'name' + added NOT NULL column: rebuild.
    const ops = comptime diff(rebuild_old, rebuild_new);
    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expect(ops[0] == .rebuild);
}

test "differ: rebuild round-trips against sqlite with data intact" {
    const ops = comptime diff(rebuild_old, rebuild_new);

    var conn = try Db.open(":memory:");
    defer conn.close();
    try conn.exec(comptime renderTable(rebuild_old.tables[0]));
    try conn.exec("INSERT INTO foo (id, name) VALUES (1, 'x')");

    try conn.execAll(comptime renderMigration(ops, .up));
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM foo"));
    // Data survived; the new NOT NULL column was zero-backfilled.
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM foo WHERE name = 'x' AND added = 0"));
    // The new shape accepts a NULL name.
    try conn.exec("INSERT INTO foo (id, name, added) VALUES (2, NULL, 5)");

    try conn.execAll(comptime renderMigration(ops, .down));
    try std.testing.expectEqual(@as(i64, 2), try conn.scalarInt("SELECT COUNT(*) FROM foo"));
    // Row 2's NULL name was zero-filled by the COALESCE guard on the way back.
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM foo WHERE name = ''"));
    // NOT NULL is enforced again.
    try std.testing.expect(std.meta.isError(conn.exec("INSERT INTO foo (id, name) VALUES (3, NULL)")));
}

const Account = Table(
    .account,
    struct {
        id: PK(u64),
        login: Unique([]const u8),
        contact: ?Unique([]const u8),
        referrer: Unique(FK(User, u64)),
    },
);

test "Unique: markers flatten and compose in either order" {
    // Same shape regardless of wrapping order.
    const A = Unique(PK(u64));
    const B = PK(Unique(u64));
    try std.testing.expectEqual(model.Kind.primary_key, A.kind);
    try std.testing.expectEqual(model.Kind.primary_key, B.kind);
    try std.testing.expect(@FieldType(A, "value") == u64);
    try std.testing.expect(@FieldType(B, "value") == u64);
    try std.testing.expect(model.hasProperty(A, .unique));
    try std.testing.expect(model.hasProperty(B, .unique));
    // FK target survives the wrap in both directions.
    try std.testing.expect(Unique(FK(User, u64)).Target == User);
    try std.testing.expect(FK(User, Unique(u64)).Target == User);
    // Plain markers carry no properties.
    try std.testing.expect(!model.hasProperty(PK(u64), .unique));
}

test "Unique: rendered DDL and live constraint enforcement" {
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS account(" ++
            "id INTEGER PRIMARY KEY NOT NULL," ++
            "login TEXT UNIQUE NOT NULL," ++
            "contact TEXT UNIQUE," ++
            "referrer INTEGER UNIQUE REFERENCES user(id) NOT NULL)",
        TableGen(Account),
    );

    var conn = try Db.open(":memory:");
    defer conn.close();
    try conn.exec(TableGen(User));
    try conn.exec(TableGen(Account));
    try conn.exec("INSERT INTO user (id, login) VALUES (1, 'alice')");
    try Query.insertInto(Account).values(.{ .login = "kal", .contact = null, .referrer = @as(u64, 1) }).exec(&conn);
    // Second row with the same unique login must be rejected.
    const dup = Query.insertInto(Account).values(.{ .login = "kal", .contact = null, .referrer = @as(u64, 1) });
    try std.testing.expect(std.meta.isError(dup.exec(&conn)));
}

test "Unique: IR flag set and a uniqueness flip forces a rebuild" {
    const account_ir = comptime TableIrOf(Account);
    try std.testing.expect(account_ir.columns[1].unique);
    try std.testing.expect(account_ir.columns[2].unique and account_ir.columns[2].nullable);
    try std.testing.expect(account_ir.columns[3].unique and account_ir.columns[3].fk != null);
    try std.testing.expect(!account_ir.columns[0].unique);

    const plain = Schema{ .tables = &.{.{ .name = "foo", .columns = &.{
        .{ .name = "id", .affinity = .integer, .pk = true },
        .{ .name = "tag", .affinity = .text },
    } }} };
    const uniqued = Schema{ .tables = &.{.{ .name = "foo", .columns = &.{
        .{ .name = "id", .affinity = .integer, .pk = true },
        .{ .name = "tag", .affinity = .text, .unique = true },
    } }} };
    const ops = comptime diff(plain, uniqued);
    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expect(ops[0] == .rebuild);
}

test "DML: insert/update/delete builders round-trip" {
    var conn = try openSeededDb();
    defer conn.close();

    const ins = Query.insertInto(Other).values(.{
        .parent = @as(u64, 1),
        .kind = "probe",
        .note = null,
        .flag = true,
    });
    try std.testing.expectEqualStrings(
        "INSERT INTO other (parent,kind,note,flag) VALUES (?,?,?,?)",
        ins.sql(),
    );
    try ins.exec(&conn);
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM other WHERE kind = 'probe' AND note IS NULL AND flag = 1"));

    const upd = Query.update(Other)
        .set(.{ .note = @as(?[]const u8, "checked"), .flag = false })
        .where(.kind, .equals, "probe");
    try std.testing.expectEqualStrings(
        "UPDATE other SET note = ?,flag = ? WHERE kind = ?",
        upd.sql(),
    );
    try upd.exec(&conn);
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM other WHERE note = 'checked' AND flag = 0"));

    const del = Query.delete(Other).where(.kind, .equals, "probe").andWhere(.flag, .equals, false);
    try std.testing.expectEqualStrings(
        "DELETE FROM other WHERE kind = ? AND flag = ?",
        del.sql(),
    );
    try del.exec(&conn);
    try std.testing.expectEqual(@as(i64, 0), try conn.scalarInt("SELECT COUNT(*) FROM other WHERE kind = 'probe'"));
    // The seeded rows are untouched.
    try std.testing.expectEqual(@as(i64, 2), try conn.scalarInt("SELECT COUNT(*) FROM other"));
}

// ==== Migration runner tests =======================================

const mig_one = runner.Committed{
    .version = "0001.create_box",
    .up = "CREATE TABLE box(id INTEGER PRIMARY KEY NOT NULL,label TEXT NOT NULL)",
};
const mig_two = runner.Committed{
    .version = "0002.add_size",
    .up = "ALTER TABLE box ADD COLUMN size INTEGER NOT NULL DEFAULT 0",
};
const cand_a = runner.Candidate{
    .up = "ALTER TABLE box ADD COLUMN colour TEXT",
    .down = "ALTER TABLE box DROP COLUMN colour",
};
const cand_b = runner.Candidate{
    .up = "ALTER TABLE box ADD COLUMN weight INTEGER NOT NULL DEFAULT 0",
    .down = "ALTER TABLE box DROP COLUMN weight",
};

test "runner: applies committed migrations once, in order" {
    var conn = try Db.open(":memory:");
    defer conn.close();
    try runner.apply(&conn, &.{ mig_one, mig_two }, null, std.testing.allocator);
    try conn.exec("INSERT INTO box (label, size) VALUES ('a', 3)");
    // Idempotent re-run.
    try runner.apply(&conn, &.{ mig_one, mig_two }, null, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM box"));
    try std.testing.expectEqual(@as(i64, 2), try conn.scalarInt("SELECT COUNT(*) FROM _db_migrations"));
}

test "runner: committed migrations are immutable (CRC check)" {
    var conn = try Db.open(":memory:");
    defer conn.close();
    try runner.apply(&conn, &.{mig_one}, null, std.testing.allocator);
    const tampered = runner.Committed{ .version = mig_one.version, .up = "CREATE TABLE box(id INTEGER PRIMARY KEY NOT NULL)" };
    try std.testing.expectError(error.CrcMismatch, runner.apply(&conn, &.{tampered}, null, std.testing.allocator));
}

test "runner: candidate lifecycle — bring up, keep, supersede, tear down" {
    var conn = try Db.open(":memory:");
    defer conn.close();

    // Bring up candidate A.
    try runner.apply(&conn, &.{mig_one}, cand_a, std.testing.allocator);
    try conn.exec("INSERT INTO box (label, colour) VALUES ('a', 'red')");

    // Same candidate again: nothing happens, data survives.
    try runner.apply(&conn, &.{mig_one}, cand_a, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM box WHERE colour = 'red'"));

    // Candidate changed: A is torn down (colour dropped), B applied.
    try runner.apply(&conn, &.{mig_one}, cand_b, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM box WHERE weight = 0"));
    try std.testing.expect(std.meta.isError(conn.scalarInt("SELECT colour FROM box")));

    // Candidate gone: B torn down, only the committed migration remains.
    try runner.apply(&conn, &.{mig_one}, null, std.testing.allocator);
    try std.testing.expect(std.meta.isError(conn.scalarInt("SELECT weight FROM box")));
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM _db_migrations"));
}

test "runner: committing a candidate promotes the row and keeps its data" {
    var conn = try Db.open(":memory:");
    defer conn.close();

    // Dev loop: candidate applied, data written under it.
    try runner.apply(&conn, &.{mig_one}, cand_a, std.testing.allocator);
    try conn.exec("INSERT INTO box (label, colour) VALUES ('a', 'red')");

    // Commit: the same SQL is now migration 0002; no candidate anymore.
    const committed_a = runner.Committed{ .version = "0002.add_colour", .up = cand_a.up };
    try runner.apply(&conn, &.{ mig_one, committed_a }, null, std.testing.allocator);

    // Promoted, not torn down: the row and its data survived.
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM box WHERE colour = 'red'"));
    try std.testing.expectEqual(@as(i64, 2), try conn.scalarInt("SELECT COUNT(*) FROM _db_migrations"));
    try std.testing.expectEqual(@as(i64, 0), try conn.scalarInt("SELECT COUNT(*) FROM _db_migrations WHERE version = '_candidate'"));
    try std.testing.expectEqual(@as(i64, 1), try conn.scalarInt("SELECT COUNT(*) FROM _db_migrations WHERE version = '0002.add_colour'"));
}

test "getAllKinds returns both kinds for parent 1" {
    var conn = try openSeededDb();
    defer conn.close();
    const kinds = try getAllKinds(&conn, 1, std.testing.allocator);
    defer {
        for (kinds) |k| std.testing.allocator.free(k);
        std.testing.allocator.free(kinds);
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.len);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
