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

//! Migration runner: applies committed migrations (kalpack-style — sorted,
//! CRC-checked for immutability, transactional) and manages the build-time
//! generated *candidate* migration on top:
//!
//! - A candidate is applied at startup and recorded under the reserved
//!   version `_candidate`, with its down SQL stored in the row.
//! - When the candidate changes or disappears (schema edited, or reverted),
//!   the recorded down SQL tears the old one down before anything else runs.
//! - When the candidate gets committed (`zig build commit-migration`), the
//!   next startup finds an unapplied committed migration with the same CRC
//!   and *promotes* the row instead of tearing down and re-applying — data
//!   written under the candidate survives the commit.
//!
//! The whole sequence runs inside one transaction, with foreign keys
//! disabled around it (rebuild recipes contain DROP TABLE; the pragma is a
//! no-op inside a transaction, so it must be toggled outside).
//!
//! The bookkeeping table is itself an ORM table; the only raw SQL in here
//! is the migrations' own payload.

const std = @import("std");
const model = @import("model.zig");
const generator = @import("generator.zig");
const Query = @import("query.zig").Query;
const Db = @import("db.zig").Db;

const log = std.log.scoped(.kw_orm_migrate);

pub const Committed = struct {
    version: []const u8,
    up: []const u8,
};

pub const Candidate = struct {
    up: []const u8,
    down: []const u8,
};

/// Reserved version key for the applied-candidate bookkeeping row.
pub const candidate_version = "_candidate";

pub const DbMigrations = model.Table(._db_migrations, struct {
    version: model.PK([]const u8),
    applied_at: i64,
    crc: u32,
    down_sql: ?[]const u8,
});

const AppliedCandidate = struct {
    crc: u32,
    down: []const u8,
};

fn sqlErr(e: anyerror, comptime fmt: []const u8, db: *Db) anyerror {
    log.err(fmt, .{db.conn.lastError()});
    return e;
}

pub fn apply(db: *Db, committed: []const Committed, candidate: ?Candidate, allocator: std.mem.Allocator) !void {
    db.exec(comptime generator.TableGen(DbMigrations)) catch |e|
        return sqlErr(e, "Failed to create the migration table: {s}", db);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var applied = std.StringHashMap(u32).init(a);
    var cand_row: ?AppliedCandidate = null;
    {
        var q = Query
            .from(.m, DbMigrations)
            .select(.{ .m = .{ .version = .version, .crc = .crc, .down_sql = .down_sql } });
        defer q.deinit(a);
        while (q.next(db, a) catch |e| return sqlErr(e, "Failed to query applied migrations: {s}", db)) |row| {
            if (std.mem.eql(u8, row.version, candidate_version)) {
                cand_row = .{ .crc = row.crc, .down = row.down_sql orelse "" };
            } else {
                try applied.put(row.version, row.crc);
            }
        }
    }

    const cand_crc: ?u32 = if (candidate) |cnd|
        (if (cnd.up.len != 0) std.hash.Crc32.hash(cnd.up) else null)
    else
        null;

    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {
        log.err("Failed to re-enable foreign keys after migrating.", .{});
    };

    db.conn.transaction() catch |e| return sqlErr(e, "Failed to begin the migration transaction: {s}", db);
    errdefer db.conn.rollback();

    // 1. Reconcile the previously applied candidate, if any.
    if (cand_row) |cr| {
        const promoted: ?[]const u8 = blk: {
            for (committed) |m| {
                if (applied.contains(m.version)) continue;
                if (std.hash.Crc32.hash(m.up) == cr.crc) break :blk m.version;
            }
            break :blk null;
        };
        if (promoted) |version| {
            // The candidate was committed as `version`: adopt the row
            // without running any SQL, so its data survives the commit.
            log.info("Promoting the applied candidate migration to '{s}'.", .{version});
            Query.update(DbMigrations)
                .set(.{ .version = version, .down_sql = null })
                .where(.version, .equals, candidate_version)
                .exec(db) catch |e| return sqlErr(e, "Failed to promote the candidate migration: {s}", db);
            try applied.put(version, cr.crc);
            cand_row = null;
        } else if (cand_crc != null and cand_crc.? == cr.crc) {
            // Still the current candidate: leave it in place.
        } else {
            log.info("Tearing down the superseded candidate migration.", .{});
            db.execAll(cr.down) catch |e| return sqlErr(e, "Failed to tear down the candidate migration: {s}", db);
            Query.delete(DbMigrations)
                .where(.version, .equals, candidate_version)
                .exec(db) catch |e| return sqlErr(e, "Failed to delete the candidate migration row: {s}", db);
            cand_row = null;
        }
    }

    // 2. Committed migrations, in order.
    for (committed) |m| {
        const crc = std.hash.Crc32.hash(m.up);
        if (applied.get(m.version)) |existing| {
            if (existing != crc) {
                // warn, not err: the returned error is the signal, and the
                // default test runner fails any test that logs an error.
                log.warn(
                    "Migration '{s}' was previously applied with a different checksum (expected {d}, found {d}). Committed migrations are immutable.",
                    .{ m.version, existing, crc },
                );
                return error.CrcMismatch;
            }
            continue;
        }
        log.info("Applying migration '{s}'.", .{m.version});
        db.execAll(m.up) catch |e| return sqlErr(e, "Failed to apply the migration: {s}", db);
        Query.insertInto(DbMigrations).values(.{
            .version = m.version,
            .applied_at = std.time.timestamp(),
            .crc = crc,
            .down_sql = null,
        }).exec(db) catch |e| return sqlErr(e, "Failed to record the migration: {s}", db);
    }

    // 3. Bring up the current candidate.
    if (cand_crc) |crc| {
        const still_applied = cand_row != null and cand_row.?.crc == crc;
        if (!still_applied) {
            const cnd = candidate.?;
            log.info("Applying the candidate migration (make it permanent with `zig build commit-migration`).", .{});
            db.execAll(cnd.up) catch |e| return sqlErr(e, "Failed to apply the candidate migration: {s}", db);
            Query.insertInto(DbMigrations).values(.{
                .version = candidate_version,
                .applied_at = std.time.timestamp(),
                .crc = crc,
                .down_sql = cnd.down,
            }).exec(db) catch |e| return sqlErr(e, "Failed to record the candidate migration: {s}", db);
        }
    }

    db.conn.commit() catch |e| return sqlErr(e, "Failed to commit the migration transaction: {s}", db);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
