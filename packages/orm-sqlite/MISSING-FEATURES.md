# kw-orm-sqlite: gaps blocking the kalpack migration

Derived from an attempt to replace all manual zqlite use in
[kalpack](../../../kalpack) with this package. SQLite there is confined to two
files: `src/index.zig` (~25 DB operations) and `src/migration.zig` (the
migration runner).

Status as of this writing: **4 of ~25 operations are expressible**, and all four
lose their `LIMIT 1`. The blocker is that the package is read-only.

Line references point at this package unless prefixed with `kalpack:`.

---

## 1. Write path — the hard blocker

`db.zig:28` is the entire write surface:

```zig
pub fn exec(self: *Db, sql_text: []const u8) !void {
    try self.conn.exec(sql_text, .{});   // no bind args
}
```

`query.zig` only ever builds `SELECT`. So there is no way to write a row, and no
way to bind a parameter to a non-`SELECT` statement at all. The only escape
hatch is reaching through the public `db.conn` field into raw zqlite, which is a
rename rather than a replacement.

| Gap | kalpack call sites |
|---|---|
| `INSERT` builder | `addRepository`, `addPackage`, `getOrCreateTag`, `getOrCreateTarget`, `installPackage` |
| `UPDATE` builder | `updateRepositorySignature`, `addPackage` (update branch) |
| `DELETE` builder | `removePackage` |
| `INSERT OR IGNORE` | `addRepositoryTags`, `addPackageTags`, `addPackageTargets` |
| `INSERT OR REPLACE` | `installPackage` |
| `lastInsertedRowId()` | `addRepository`, `addPackage`, `getOrCreateTag`, `getOrCreateTarget` — each returns the new id to its caller |
| Parameterized raw `exec` | `kalpack:migration.zig:85` (migration ledger insert) |
| `transaction()` / `commit()` / `rollback()` | `kalpack:migration.zig:54-89` — the whole migration run is one transaction |

Landing this section alone moves the mutation half of `index.zig` over.

## 2. Query builder

Ordered roughly by how much each unblocks.

- **`LEFT JOIN`** — 11 sites. Every package listing left-joins
  `installed_packages` to compute installed-or-not. `query.zig:134` (`appendJoin`)
  hardcodes `" JOIN "`.
- **`LIMIT`** — 11 sites. Cheap; today emulated by calling `next()` once and
  never stepping again, which works but leaves the statement open.
- **Computed / literal projections** — 7 `CASE WHEN ... THEN 1 ELSE 0 END`
  sites plus `SELECT 1` in `isPackageInstalled`. `query.zig:194` (`selectState`)
  requires every projection be a declared column of a declared table.
- **`DISTINCT`** — 13 sites.
- **Aggregates + `GROUP BY` / `HAVING`** — `COUNT(DISTINCT ...)` and
  `GROUP_CONCAT(DISTINCT ...)` (6 sites) in `getPackageInfo`,
  `getPackageInfoByRepo`, `getPackageConflicts`, `findPackageByName`.
- **SQL functions in predicates** — `LOWER(p.name) = LOWER(?)`, 6 predicates.
- **Column-to-column predicates** — `p.version != ip.version` in
  `getAllOutdated`. `where`/`andWhere`/`orWhere` only compare a column against a
  bound value (`query.zig:74`, `whereFrag`).
- **Multi-key `ORDER BY`** — `ORDER BY p.name, r.name`. `orderby` is terminal
  (returns `OrderedQuery`, which has no further `orderby`).
- **`LIKE ... ESCAPE '\'`** — `Op.like` exists but `opSql` emits no `ESCAPE`
  clause. Used throughout `searchPackages`.
- **Predicate grouping / parens** — already noted as a later feature at
  `query.zig:270`.
- **CTEs (`WITH`) and `EXISTS` subqueries** — `searchPackages` is built entirely
  out of both, with a computed `match_priority` column driving the ordering.

`searchPackages`, `getPackageInfo`, and `getPackageInfoByRepo` are probably not
worth expressing in the builder. A **typed raw-SQL escape hatch** — arbitrary
SQL text + bind args + a row struct to materialize into, reusing
`db.zig:execNext` — would cover them and is likely cheaper than CTE support.

## 3. Schema / model layer

kalpack's schema lives in `migrations/*.sql`, so this section only matters if
the models are meant to become the source of truth. It is not needed to unblock
the query work.

- **Junction tables.** `repository_tags`, `package_tags`, and `package_targets`
  are pure many-to-many. `ir.zig:93` is an explicit
  `@compileError("Many-to-many relationships need a junction table (not implemented yet)")`.
- **Composite primary keys.** All three junction tables use them.
  `model.PrimaryOf` returns the first `PK` field it finds, and `generator.zig:17`
  emits `PRIMARY KEY` per column.
- **DDL the generator cannot emit:** `AUTOINCREMENT`, `UNIQUE` (column- and
  table-level), `DEFAULT` (`_db_migrations.applied_at` needs
  `DEFAULT CURRENT_TIMESTAMP`), and secondary `CREATE INDEX`.
- **No migration runner / differ.** kalpack owns its schema through versioned,
  CRC-tracked SQL files; this package owns it through
  `CREATE TABLE IF NOT EXISTS` generated from models. Two different
  schema-ownership stories. The differ anticipated at `ir.zig:6` and
  `generator.zig:5` does not exist yet.

## 4. Connection

- **`lastError()`** — 29 sites across the two files use it for diagnostics.
  `Db` exposes no equivalent, so every error path would lose its message.
- **Open flags / pragmas.** `Db.open` (`db.zig:11`) hardcodes
  `Create | ReadWrite | EXResCode` and `PRAGMA foreign_keys = ON`. kalpack opens
  with `Create | EXResCode` and additionally sets `journal_mode=WAL` and
  `synchronous=NORMAL`. Minor — the two pragmas can go through `exec` today.

---

## What is expressible today

Four reads, all losing `LIMIT 1`:

- `getCurrentSignature` — `u64` signature round-trips fine via the bit-cast in
  `db.zig:43`/`db.zig:55`
- `packageExists`
- `getInstalledVersion`
- `isPackageInstalled` — needs rewriting to select `package_id` instead of `1`

`migration.zig`'s ledger read is close, but needs `_db_migrations` modeled, which
needs `DEFAULT`.

Converting only these is not worth doing: kalpack would hold an ORM `Db` *and* a
raw `zqlite.Conn` against the same file — two connections, two WAL readers, and
the migration transaction would no longer cover the ORM's work.

## Suggested order

1. **Writes** (§1) — unblocks the mutation half of `index.zig` in one pass.
2. **Reads** (§2), starting with `LEFT JOIN`, `LIMIT`, computed projections,
   and `DISTINCT` — unblocks the package-listing queries.
3. **Raw-SQL escape hatch** — retires `searchPackages` and `getPackageInfo*`
   without needing CTE support.
4. §3 and §4 only if the models should become the schema source of truth.

Migrating in two passes (writes, then reads) keeps `index.zig` from ever being
split across two connections.
