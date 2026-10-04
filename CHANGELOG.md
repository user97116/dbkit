# 0.4.0

- Simplified API (breaking): removed exact-duplicate aliases — use
  `nullable()` (not `allowNull()`), `orderBy()` / `orderByDesc()` (not
  `orderByAsc()` / `latest()` / `oldest()`).
- Generated `all()` now delegates to `list()` instead of carrying a second
  implementation.
- Docs: README rewritten as a step-by-step guide around the single
  canonical API; examples use canonical methods only.

# 0.3.1

- `MemoryAdapter` now clears stored rows on `DROP TABLE`, so schema helpers
  like the `dbkit_gen`-generated `dropXxxTables()` behave the same on the
  fake as on SQLite.
- New sibling package `dbkit_gen`: annotate model classes and run
  `build_runner` to get typed models, table repositories with query
  helpers, column constants, relationship loaders and link helpers,
  eager-load wrappers, and schema setup functions.

# 0.3.0

- Text search without `%` wildcards: `contains` / `startsWith` / `endsWith`
  (plus `notContains` / `notStartsWith` / `notEndsWith`) now escape `%`, `_`
  and `\` and compile with `ESCAPE '\'`, on both backends. New shortcuts
  `whereContains` / `whereStartsWith` / `whereEndsWith` on `TableRef` and
  `TableQuery`; raw `like` / `notLike` / `whereLike` stay as the explicit
  pattern hatch.
- Relationships: new `TableRef.load(row, relation)` lazy-loads one row's
  relation (`List` for `hasMany` / many-to-many, `Map?` for `hasOne` /
  `belongsTo`); `withOne(..., constrain)` is now honored for `belongsTo`
  instead of silently ignored.

# 0.2.0

- Production defaults: `Db.open`/`Db.memory` now enable `foreign_keys=ON`
  and a 5s `busy_timeout`; file-backed databases also use WAL mode with
  `NORMAL` synchronous writes. Orphan foreign keys now fail instead of
  silently succeeding.
- Transactions use `BEGIN IMMEDIATE` with `SAVEPOINT` support, so nested
  transactions roll back the inner scope only; `close()` is idempotent.
- Atomic `increment`/`decrement`: single `UPDATE col = col + ?` on SQL
  backends via new `DbAdapter.updateIncrement` (custom adapters implementing
  `DbAdapter` must add this method).
- Filtered `TableQuery.count()` runs a single `COUNT(*)` instead of fetching
  all rows (fetch fallback kept for joins/grouping/eager loads).
- `List`/`Map` values are stored as JSON (`jsonEncode`) instead of Dart
  `toString()`.
- Fail-fast `ArgumentError` (works in release builds, unlike `assert`) for
  empty rows/values, negative `limit`/`offset`, invalid `page`, and empty
  table names/identifiers.

# 0.1.0

- Initial release: fluent Table API, query builder, filters, relationships
  (hasMany/hasOne/belongsTo/manyToMany + eager loading), schema builder,
  migrations, transactions, sqlite3 + in-memory adapters.
