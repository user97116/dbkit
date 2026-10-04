import 'adapter.dart';
import 'errors.dart';
import 'filter.dart';
import 'query.dart';
import 'relation.dart';
import 'sql.dart';

/// High-level handle to a single table. No SQL strings required.
///
/// ```dart
/// final users = db.table('users');
/// await users.insert({'name': 'Ada', 'age': 36});
/// final all = await users.selectAll();
/// final ada = await users.findOneWhere((w) => w.eq('name', 'Ada'));
/// final adults = await users.where((w) => w.gte('age', 18)).orderBy('name').limit(10).get();
/// ```
class TableRef {
  final DbAdapter _adapter;
  final RelationRegistry _relations;

  /// The table this handle reads and writes.
  final String table;
  final bool Function()? _logSql;
  final void Function(String message)? _logger;

  /// Creates a handle to [table] (see [Db.table]).
  TableRef(this._adapter, this.table, this._relations,
      {bool Function()? logSql, void Function(String message)? logger})
      : _logSql = logSql,
        _logger = logger;

  void _log(CompiledSql c) {
    if (_logSql?.call() == true) {
      _logger?.call(debugSql(c));
    }
  }

  // -- query entry points -----------------------------------------------------

  /// Starts a chainable query: `users.query().select([...]).where(...).get()`.
  TableQuery query() => TableQuery._(this, SelectQuery(table));

  /// `SELECT * FROM table`
  Future<List<Map<String, Object?>>> selectAll(
      {String? orderBy, bool desc = false, int? limit, int? offset}) async {
    var q = query();
    if (orderBy != null) q = q.orderBy(orderBy, desc: desc);
    if (limit != null) q = q.limit(limit);
    if (offset != null) q = q.offset(offset);
    return q.get();
  }

  /// `SELECT * FROM table WHERE id = ?` (single row or null).
  Future<Map<String, Object?>?> findById(Object id,
      {String idColumn = 'id'}) async {
    return query().where((w) => w.eq(idColumn, id)).first();
  }

  /// Same as [findById] but throws [DbException] when missing.
  Future<Map<String, Object?>> findByIdOrFail(Object id,
      {String idColumn = 'id'}) async {
    final row = await findById(id, idColumn: idColumn);
    if (row == null) {
      throw DbException('$table#$id not found');
    }
    return row;
  }

  /// `SELECT * FROM table WHERE ... LIMIT 1` (single row or null).
  Future<Map<String, Object?>?> findOneWhere(
      Condition Function(Where w) build) {
    return query().where(build).first();
  }

  /// `SELECT * FROM table WHERE ...` (all matching rows).
  Future<List<Map<String, Object?>>> findWhere(
      Condition Function(Where w) build) {
    return query().where(build).get();
  }

  /// Chainable filter shortcut: `users.where((w) => w.gt('age', 18)).get()`.
  TableQuery where(Condition Function(Where w) build) => query().where(build);

  /// `where` shortcut for `[column] = [value]`.
  TableQuery whereEq(String column, Object? value) =>
      query().where((w) => w.eq(column, value));

  /// `where` shortcut for `[column] IN [values]`.
  TableQuery whereIn(String column, List<Object?> values) =>
      query().where((w) => w.inList(column, values));

  /// `where` shortcut for `[column] IS NULL`.
  TableQuery whereNull(String column) => query().where((w) => w.isNull(column));

  /// `where` shortcut for `[column] IS NOT NULL`.
  TableQuery whereNotNull(String column) =>
      query().where((w) => w.isNotNull(column));

  /// `column` contains `part` — no `%` wildcards needed.
  TableQuery whereContains(String column, String part) =>
      query().where((w) => w.contains(column, part));

  /// `column` starts with `prefix` — no wildcards needed.
  TableQuery whereStartsWith(String column, String prefix) =>
      query().where((w) => w.startsWith(column, prefix));

  /// `column` ends with `suffix` — no wildcards needed.
  TableQuery whereEndsWith(String column, String suffix) =>
      query().where((w) => w.endsWith(column, suffix));

  /// Counts rows, optionally filtered by [build].
  Future<int> count([Condition Function(Where w)? build]) async {
    if (build == null) return _adapter.count(table);
    return _adapter.count(table, build(const Where()));
  }

  /// Whether any row matches [build].
  Future<bool> existsWhere(Condition Function(Where w) build) =>
      _adapter.exists(table, build(const Where()));

  /// Whether the row with [id] exists.
  Future<bool> existsById(Object id, {String idColumn = 'id'}) =>
      _adapter.exists(table, const Where().eq(idColumn, id));

  /// Returns a single column across matching rows.
  Future<List<T>> pluck<T>(String column,
      {Condition Function(Where w)? where}) async {
    final q = SelectQuery(table).select([column]);
    if (where != null) q.where(where);
    final rows = await _runSelect(q);
    return rows.map((r) {
      final v = r[column] ?? r[column.split('.').last];
      return v as T;
    }).toList();
  }

  /// Simple pagination returning ([Page]).
  Future<Page> paginate(
      {required int page, required int perPage, TableQuery? base}) async {
    final where = base?._select.whereCondition;
    final total = await _adapter.count(table, where);
    final q = (base?._select.clone() ?? SelectQuery(table)).page(page, perPage);
    final items = await TableQuery._(this, q).get();
    return Page(items: items, page: page, perPage: perPage, total: total);
  }

  // -- writes -------------------------------------------------------------------

  /// Inserts [row], returning the new row id.
  Future<int> insert(Map<String, Object?> row) {
    if (row.isEmpty) {
      throw ArgumentError.value(row, 'row', 'must not be empty');
    }
    return _adapter.insert(table, row);
  }

  /// Inserts every row in [rows].
  Future<void> insertMany(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      if (row.isEmpty) {
        throw ArgumentError.value(row, 'rows', 'row maps must not be empty');
      }
    }
    return _adapter.insertMany(table, rows);
  }

  /// Insert or update on conflict (SQLite `ON CONFLICT DO UPDATE`).
  Future<void> upsert(Map<String, Object?> row,
      {List<String> onConflict = const ['id']}) {
    if (row.isEmpty) {
      throw ArgumentError.value(row, 'row', 'must not be empty');
    }
    return _adapter.upsert(table, row, onConflict: onConflict);
  }

  /// Insert and return the row (with generated id).
  Future<Map<String, Object?>> create(Map<String, Object?> row) async {
    final id = await insert(row);
    if (row.containsKey('id') && row['id'] != null) {
      return {'id': row['id'], ...row};
    }
    return {'id': id, ...row};
  }

  /// Updates the row with [id] to [values], returning the affected count.
  Future<int> updateById(Object id, Map<String, Object?> values,
      {String idColumn = 'id'}) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'must not be empty');
    }
    return _adapter.update(table, values, const Where().eq(idColumn, id));
  }

  /// Updates every row matching [build] to [values].
  Future<int> updateWhere(
      Condition Function(Where w) build, Map<String, Object?> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'must not be empty');
    }
    return _adapter.update(table, values, build(const Where()));
  }

  /// Deletes the row with [id], returning the affected count.
  Future<int> deleteById(Object id, {String idColumn = 'id'}) =>
      _adapter.delete(table, const Where().eq(idColumn, id));

  /// Deletes every row matching [build], returning the affected count.
  Future<int> deleteWhere(Condition Function(Where w) build) =>
      _adapter.delete(table, build(const Where()));

  /// Atomically adds [by] to [column] on every matching row
  /// (a single `UPDATE` on SQL backends — no read-modify-write race).
  Future<int> increment(String column,
      {int by = 1, Condition Function(Where w)? where}) {
    return _adapter.updateIncrement(
        table, column, by, where == null ? null : where(const Where()));
  }

  /// Atomically subtracts [by] from [column] on every matching row.
  Future<int> decrement(String column,
          {int by = 1, Condition Function(Where w)? where}) =>
      increment(column, by: -by, where: where);

  /// Deletes every row (`DELETE FROM table`).
  Future<int> truncate() => _adapter.delete(table);

  // -- relations ---------------------------------------------------------------

  /// Eager-loads [relationNames] onto every returned row.
  /// e.g. `users.withRelations(['posts', 'profile']).get()`.
  TableQuery withRelations(List<String> relationNames) =>
      query().withRelations(relationNames);

  /// Eager-loads a `hasMany` / many-to-many [relation] onto every row.
  TableQuery withMany(String relation,
          [void Function(SelectQuery q)? constrain]) =>
      query().withMany(relation, constrain);

  /// Eager-loads a `hasOne` / `belongsTo` [relation] onto every row.
  TableQuery withOne(String relation,
          [void Function(SelectQuery q)? constrain]) =>
      query().withOne(relation, constrain);

  /// Lazy-loads one [relation] for a single [row] you already have.
  ///
  /// Returns a `List` for `hasMany` / many-to-many, or a single `Map?`
  /// for `hasOne` / `belongsTo`:
  /// ```dart
  /// final user = await users.findByIdOrFail(1);
  /// final posts = await users.load(user, 'posts') as List;
  /// final profile = await users.load(user, 'profile') as Map?;
  /// final author = await postsTable.load(post, 'author') as Map?;
  /// ```
  Future<Object?> load(Map<String, Object?> row, String relation) async {
    final loaded = await _withEager([row], [EagerLoad(relation)]);
    return loaded.first[relation];
  }

  // -- internals -----------------------------------------------------------------
  Future<List<Map<String, Object?>>> _runSelect(SelectQuery q) async {
    _log(q.compile());
    return _adapter.select(q);
  }

  Relation? _relation(String name) => _relations.lookup(table, name);

  Future<List<Map<String, Object?>>> _withEager(
      List<Map<String, Object?>> rows, List<EagerLoad> eager) async {
    var out = rows;
    for (final e in eager) {
      out = await _loadRelation(out, e);
    }
    return out;
  }

  Future<List<Map<String, Object?>>> _loadRelation(
      List<Map<String, Object?>> parents, EagerLoad eager) async {
    final rel = _relation(eager.relation);
    if (rel == null) {
      throw DbException(
          'Unknown relation "${eager.relation}" on table "$table". Did you forget db.defineRelation()?');
    }
    if (parents.isEmpty) return parents;
    switch (rel.kind) {
      case RelationKind.hasMany:
      case RelationKind.hasOne:
        return _loadHasMany(parents, rel, eager);
      case RelationKind.belongsTo:
        return _loadBelongsTo(parents, rel, eager);
      case RelationKind.manyToMany:
        return _loadManyToMany(parents, rel, eager);
    }
  }

  Future<List<Map<String, Object?>>> _loadHasMany(
      List<Map<String, Object?>> parents, Relation rel, EagerLoad eager) async {
    final keys = parents
        .map((p) => p[rel.fromKey])
        .where((k) => k != null)
        .toSet()
        .toList();
    if (keys.isEmpty) {
      return [
        for (final p in parents)
          {
            ...p,
            rel.name: rel.kind == RelationKind.hasMany
                ? <Map<String, Object?>>[]
                : null
          }
      ];
    }
    final q = SelectQuery(rel.toTable).where((w) => w.inList(rel.toKey, keys));
    if (rel.filter != null) q.whereCond(rel.filter!(const Where()));
    if (rel.orderByColumn != null) {
      q.orderBy(rel.orderByColumn!, desc: rel.orderDesc);
    }
    if (eager.constrain != null) eager.constrain!(q);
    if (rel.limit != null && q.limitValue == null) q.limit(rel.limit!);
    _log(q.compile());
    final children = await _adapter.select(q);
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final c in children) {
      grouped.putIfAbsent('${c[rel.toKey]}', () => []).add(c);
    }
    return [
      for (final p in parents)
        {
          ...p,
          rel.name: rel.kind == RelationKind.hasMany
              ? (grouped['${p[rel.fromKey]}'] ?? <Map<String, Object?>>[])
              : ((grouped['${p[rel.fromKey]}'] ?? const []).isEmpty
                  ? null
                  : grouped['${p[rel.fromKey]}']!.first),
        }
    ];
  }

  Future<List<Map<String, Object?>>> _loadBelongsTo(
      List<Map<String, Object?>> children,
      Relation rel,
      EagerLoad eager) async {
    final fks = children
        .map((c) => c[rel.fromKey])
        .where((k) => k != null)
        .toSet()
        .toList();
    if (fks.isEmpty) {
      return [
        for (final c in children) {...c, rel.name: null}
      ];
    }
    final q = SelectQuery(rel.toTable).where((w) => w.inList(rel.toKey, fks));
    if (eager.constrain != null) eager.constrain!(q);
    _log(q.compile());
    final parents = await _adapter.select(q);
    final byKey = {for (final p in parents) '${p[rel.toKey]}': p};
    return [
      for (final c in children) {...c, rel.name: byKey['${c[rel.fromKey]}']}
    ];
  }

  Future<List<Map<String, Object?>>> _loadManyToMany(
      List<Map<String, Object?>> parents, Relation rel, EagerLoad eager) async {
    final keys = parents
        .map((p) => p[rel.fromKey])
        .where((k) => k != null)
        .toSet()
        .toList();
    if (keys.isEmpty) {
      return [
        for (final p in parents) {...p, rel.name: []}
      ];
    }
    final pivotQ = SelectQuery(rel.pivotTable!)
        .where((w) => w.inList(rel.pivotFromKey!, keys));
    _log(pivotQ.compile());
    final pivots = await _adapter.select(pivotQ);
    final targetIds = pivots
        .map((p) => p[rel.pivotToKey])
        .where((k) => k != null)
        .toSet()
        .toList();
    Map<String, Map<String, Object?>> byId = {};
    if (targetIds.isNotEmpty) {
      final tq =
          SelectQuery(rel.toTable).where((w) => w.inList(rel.toKey, targetIds));
      if (rel.filter != null) tq.whereCond(rel.filter!(const Where()));
      if (eager.constrain != null) eager.constrain!(tq);
      _log(tq.compile());
      final targets = await _adapter.select(tq);
      byId = {for (final t in targets) '${t[rel.toKey]}': t};
    }
    // pivotFrom -> [targets]
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final pv in pivots) {
      final from = '${pv[rel.pivotFromKey]}';
      final to = '${pv[rel.pivotToKey]}';
      final t = byId[to];
      if (t != null) {
        grouped.putIfAbsent(from, () => []).add(t);
      }
    }
    return [
      for (final p in parents)
        {...p, rel.name: grouped['${p[rel.fromKey]}'] ?? []}
    ];
  }
}

/// Chainable, awaitable query for one table.
///
/// Every terminal operation (`get`, `first`, `count`, `pluck`, ...) hits
/// the database; intermediate calls only refine the query.
class TableQuery {
  final TableRef _table;
  final SelectQuery _select;
  final List<EagerLoad> _eager = [];

  TableQuery._(this._table, this._select);

  // -- projection ---------------------------------------------------------
  /// Selects [columns] instead of `*`.
  TableQuery select(List<String> columns) {
    _select.select(columns);
    return this;
  }

  /// Adds [columns] to the projection (replaces a bare `*`).
  TableQuery selectAppend(List<String> columns) {
    _select.selectAppend(columns);
    return this;
  }

  /// Toggles `SELECT DISTINCT`.
  TableQuery distinct([bool v = true]) {
    _select.distinct(v);
    return this;
  }

  // -- joins --------------------------------------------------------------
  /// Joins [table] with a typed [on] condition.
  TableQuery join(String table, Condition on,
      {String kind = 'INNER', String? alias}) {
    _select.join(table, on, kind: kind, alias: alias);
    return this;
  }

  /// Joins [table] with a raw SQL [onSql] condition.
  TableQuery joinRaw(String table, String onSql,
      {String kind = 'INNER', String? alias}) {
    _select.joinRaw(table, onSql, kind: kind, alias: alias);
    return this;
  }

  /// `INNER JOIN [table] ON ([onSql])`.
  TableQuery innerJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'INNER', alias: alias);

  /// `LEFT JOIN [table] ON ([onSql])`.
  TableQuery leftJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'LEFT', alias: alias);

  // -- filters --------------------------------------------------------------
  /// Adds an `AND` filter built by [build].
  TableQuery where(Condition Function(Where w) build) {
    _select.where(build);
    return this;
  }

  /// Adds an `AND` filter [c].
  TableQuery whereCond(Condition c) {
    _select.whereCond(c);
    return this;
  }

  /// Adds an `OR` filter built by [build].
  TableQuery orWhere(Condition Function(Where w) build) {
    _select.orWhere(build);
    return this;
  }

  /// `where` shortcut for `[column] = [value]`.
  TableQuery whereEq(String column, Object? value) =>
      where((w) => w.eq(column, value));

  /// `where` shortcut for `[column] IN [values]`.
  TableQuery whereIn(String column, List<Object?> values) =>
      where((w) => w.inList(column, values));

  /// `where` shortcut for `[column] BETWEEN [lo] AND [hi]`.
  TableQuery whereBetween(String column, Object? lo, Object? hi) =>
      where((w) => w.between(column, lo, hi));

  /// `where` shortcut for `[column] IS NULL`.
  TableQuery whereNull(String column) => where((w) => w.isNull(column));

  /// `where` shortcut for `[column] IS NOT NULL`.
  TableQuery whereNotNull(String column) => where((w) => w.isNotNull(column));

  /// `where` shortcut for raw `LIKE [pattern]`.
  TableQuery whereLike(String column, String pattern) =>
      where((w) => w.like(column, pattern));

  /// `column` contains `part` — no `%` wildcards needed.
  TableQuery whereContains(String column, String part) =>
      where((w) => w.contains(column, part));

  /// `column` starts with `prefix` — no wildcards needed.
  TableQuery whereStartsWith(String column, String prefix) =>
      where((w) => w.startsWith(column, prefix));

  /// `column` ends with `suffix` — no wildcards needed.
  TableQuery whereEndsWith(String column, String suffix) =>
      where((w) => w.endsWith(column, suffix));

  /// Adds a raw SQL [fragment] filter with [args] (sqlite backend only).
  TableQuery whereRaw(String fragment, [List<Object?> args = const []]) {
    _select.whereRaw(fragment, args);
    return this;
  }

  // -- grouping / ordering / paging -------------------------------------------
  /// Adds `GROUP BY [columns]`.
  TableQuery groupBy(List<String> columns) {
    _select.groupBy(columns);
    return this;
  }

  /// Adds a `HAVING` filter built by [build].
  TableQuery having(Condition Function(Where w) build) {
    _select.having(build);
    return this;
  }

  /// Adds `ORDER BY [column]` (ascending, or descending with [desc]).
  TableQuery orderBy(String column, {bool desc = false, bool? nullsFirst}) {
    _select.orderBy(column, desc: desc, nullsFirst: nullsFirst);
    return this;
  }

  /// Adds `ORDER BY [column] DESC`.
  TableQuery orderByDesc(String column) => orderBy(column, desc: true);

  /// Adds `LIMIT [n]`.
  TableQuery limit(int n) {
    _select.limit(n);
    return this;
  }

  /// Adds `OFFSET [n]`.
  TableQuery offset(int n) {
    _select.offset(n);
    return this;
  }

  /// Selects page [page] with [perPage] rows.
  TableQuery page(int page, int perPage) {
    _select.page(page, perPage);
    return this;
  }

  // -- relations ---------------------------------------------------------------
  /// Eager-loads [names] onto every returned row.
  TableQuery withRelations(List<String> names) {
    _eager.addAll(names.map((n) => EagerLoad(n)));
    return this;
  }

  /// Eager-loads a `hasMany` / many-to-many [relation], optionally tweaked.
  TableQuery withMany(String relation,
      [void Function(SelectQuery q)? constrain]) {
    _eager.add(EagerLoad(relation, constrain));
    return this;
  }

  /// Eager-loads a `hasOne` / `belongsTo` [relation], optionally tweaked.
  TableQuery withOne(String relation,
      [void Function(SelectQuery q)? constrain]) {
    _eager.add(EagerLoad(relation, constrain));
    return this;
  }

  // -- terminals -----------------------------------------------------------------
  /// Runs the query, returning all matching rows (with eager loads applied).
  Future<List<Map<String, Object?>>> get() async {
    final rows = await _table._runSelect(_select);
    if (_eager.isEmpty) return rows;
    return _table._withEager(rows, _eager);
  }

  /// Runs the query, returning the first row or null.
  Future<Map<String, Object?>?> first() async {
    _select.limit(1);
    final rows = await get();
    return rows.isEmpty ? null : rows.first;
  }

  /// Runs the query, returning the first row or throwing [DbException].
  Future<Map<String, Object?>> firstOrFail() async {
    final r = await first();
    if (r == null) throw DbException('${_table.table}: no row found');
    return r;
  }

  /// Counts matching rows (single `COUNT(*)` when no joins/grouping/eager).
  Future<int> count() async {
    // Fast path: a single COUNT(*) query. Only joins / grouping / eager
    // loads need the full fetch fallback to stay semantically identical.
    if (_eager.isEmpty &&
        _select.joins.isEmpty &&
        _select.groupByColumns.isEmpty &&
        _select.havingCondition == null) {
      return _table._adapter.count(_table.table, _select.whereCondition);
    }
    final rows = await get();
    return rows.length;
  }

  /// Whether any row matches.
  Future<bool> exists() async => await count() > 0;

  /// Returns a single [column] across matching rows.
  Future<List<T>> pluck<T>(String column) async {
    final rows = await select([column]).get();
    return rows.map((r) => r[column] as T).toList();
  }

  /// Paginates the query, returning a [Page] with total included.
  Future<Page> paginate({required int page, required int perPage}) async {
    final total =
        await _table._adapter.count(_table.table, _select.whereCondition);
    final items =
        await TableQuery._(_table, _select.clone()).page(page, perPage).get();
    return Page(items: items, page: page, perPage: perPage, total: total);
  }

  /// Compiled SQL for debugging (without running it).
  CompiledSql toSql() => _select.compile();
}

/// Paginated result.
class Page {
  /// Rows on this page.
  final List<Map<String, Object?>> items;

  /// 1-based page number.
  final int page;

  /// Rows per page.
  final int perPage;

  /// Total matching rows across pages.
  final int total;

  /// Creates a page of [items] ([page] of [perPage], [total] overall).
  const Page(
      {required this.items,
      required this.page,
      required this.perPage,
      required this.total});

  /// Total page count.
  int get totalPages => (total / perPage).ceil();

  /// Whether a next page exists.
  bool get hasNext => page < totalPages;

  /// Whether a previous page exists.
  bool get hasPrev => page > 1;
}
