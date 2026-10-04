import 'filter.dart';
import 'sql.dart';

/// A JOIN clause.
class Join {
  /// Join kind (`INNER`, `LEFT`, ...).
  final String kind; // INNER, LEFT, RIGHT, CROSS, FULL

  /// Joined table name.
  final String table;

  /// Optional table alias.
  final String? alias;

  /// Typed `ON` condition, if any.
  final Condition? onCond;

  /// Raw SQL `ON` fragment, if any.
  final String? onRaw;

  const Join._(this.kind, this.table, {this.alias, this.onCond, this.onRaw});

  /// Joins [table] with a typed [on] condition.
  factory Join.on(String kind, String table, Condition on, {String? alias}) =>
      Join._(kind, table, onCond: on, alias: alias);

  /// Joins [table] with a raw SQL [onSql] condition.
  factory Join.raw(String kind, String table, String onSql, {String? alias}) =>
      Join._(kind, table, onRaw: onSql, alias: alias);

  /// The `FROM`-style fragment (`"table"` or `"table" AS "alias"`).
  String get fromFragment => alias == null
      ? quoteIdent(table)
      : '${quoteIdent(table)} AS ${quoteIdent(alias!)}';

  /// Compiles the `... JOIN ... ON ...` fragment.
  CompiledSql compile() {
    final b = StringBuffer('$kind JOIN $fromFragment');
    final args = <Object?>[];
    if (onCond != null) {
      final c = onCond!.compile();
      b.write(' ON ${c.sql}');
      args.addAll(c.args);
    } else if (onRaw != null && onRaw!.trim().isNotEmpty) {
      b.write(' ON (${onRaw!})');
    }
    return CompiledSql(b.toString(), args);
  }
}

/// An `ORDER BY` term.
class Order {
  /// Column to sort by.
  final String column;

  /// Whether sorting is descending.
  final bool desc;

  /// Null placement override, if any.
  final bool? nullsFirst;

  /// Creates an ordering over [column].
  const Order(this.column, {this.desc = false, this.nullsFirst});

  /// Compiles the `"col" ASC/DESC` fragment.
  String compile() {
    var s = '${quoteIdent(column)} ${desc ? 'DESC' : 'ASC'}';
    if (nullsFirst != null) s += nullsFirst! ? ' NULLS FIRST' : ' NULLS LAST';
    return s;
  }
}

/// Chainable SELECT builder. Obtain via `db.table('users').query()` or
/// `db.table('users').where(...)` shortcuts.
///
/// ```dart
/// await db.table('users')
///   .query()
///   .select(['id', 'name'])
///   .where((w) => w.gt('age', 18))
///   .orderBy('name')
///   .limit(10)
///   .get();
/// ```
class SelectQuery {
  /// Queried table name.
  final String table;

  /// Optional table alias.
  final String? alias;

  List<String> _columns = ['*'];
  bool _distinct = false;
  final List<Join> _joins = [];
  Condition? _where;
  final List<String> _groupBys = [];
  Condition? _having;
  final List<Order> _orders = [];
  int? _limit;
  int? _offset;

  /// Creates a select over [table], optionally aliased as [alias].
  SelectQuery(this.table, {this.alias});

  // -- projection -----------------------------------------------------------
  /// Selects [columns] instead of `*`.
  SelectQuery select(List<String> columns) {
    _columns = List.of(columns);
    return this;
  }

  /// Adds [columns] to the projection (replaces a bare `*`).
  SelectQuery selectAppend(List<String> columns) {
    if (_columns.length == 1 && _columns.first == '*') {
      _columns = List.of(columns);
    } else {
      _columns.addAll(columns);
    }
    return this;
  }

  /// Selects `COUNT(*) AS [as]`.
  SelectQuery countAll({String as = 'count'}) => select(['COUNT(*) AS $as']);

  /// Toggles `SELECT DISTINCT`.
  SelectQuery distinct([bool v = true]) {
    _distinct = v;
    return this;
  }

  // -- joins ----------------------------------------------------------------
  /// Joins [table] with a typed [on] condition.
  SelectQuery join(String table, Condition on,
      {String kind = 'INNER', String? alias}) {
    _joins.add(Join.on(kind, table, on, alias: alias));
    return this;
  }

  /// Joins [table] with a raw SQL [onSql] condition.
  SelectQuery joinRaw(String table, String onSql,
      {String kind = 'INNER', String? alias}) {
    _joins.add(Join.raw(kind, table, onSql, alias: alias));
    return this;
  }

  /// `INNER JOIN [table] ON ([onSql])`.
  SelectQuery innerJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'INNER', alias: alias);

  /// `LEFT JOIN [table] ON ([onSql])`.
  SelectQuery leftJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'LEFT', alias: alias);

  /// `RIGHT JOIN [table] ON ([onSql])`.
  SelectQuery rightJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'RIGHT', alias: alias);

  /// `CROSS JOIN [table]`.
  SelectQuery crossJoin(String table) {
    _joins.add(Join.raw('CROSS', table, '', alias: null));
    return this;
  }

  // -- filtering --------------------------------------------------------------
  /// Adds an `AND` filter [c].
  SelectQuery whereCond(Condition c) {
    _where = _where == null ? c : _where! & c;
    return this;
  }

  /// Adds an `AND` filter built by [build].
  SelectQuery where(Condition Function(Where w) build) =>
      whereCond(build(const Where()));

  /// Adds an `OR` filter built by [build].
  SelectQuery orWhere(Condition Function(Where w) build) {
    final c = build(const Where());
    _where = _where == null ? c : _where! | c;
    return this;
  }

  /// `where` shortcut for `[column] = [value]`.
  SelectQuery whereEq(String column, Object? value) =>
      whereCond(const Where().eq(column, value));

  /// Adds a raw SQL [fragment] filter with [args].
  SelectQuery whereRaw(String fragment, [List<Object?> args = const []]) =>
      whereCond(RawCondition(fragment, args));

  // -- grouping / ordering / paging -------------------------------------------
  /// Adds `GROUP BY [columns]`.
  SelectQuery groupBy(List<String> columns) {
    _groupBys.addAll(columns);
    return this;
  }

  /// Adds a `HAVING` filter [c].
  SelectQuery havingCond(Condition c) {
    _having = _having == null ? c : _having! & c;
    return this;
  }

  /// Adds a `HAVING` filter built by [build].
  SelectQuery having(Condition Function(Where w) build) =>
      havingCond(build(const Where()));

  /// Adds `ORDER BY [column]` (ascending, or descending with [desc]).
  SelectQuery orderBy(String column, {bool desc = false, bool? nullsFirst}) {
    _orders.add(Order(column, desc: desc, nullsFirst: nullsFirst));
    return this;
  }

  /// Adds `ORDER BY [column] DESC`.
  SelectQuery orderByDesc(String column) => orderBy(column, desc: true);

  /// Adds `LIMIT [n]` (must be `>= 0`).
  SelectQuery limit(int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be >= 0');
    }
    _limit = n;
    return this;
  }

  /// Adds `OFFSET [n]` (must be `>= 0`).
  SelectQuery offset(int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be >= 0');
    }
    _offset = n;
    return this;
  }

  /// Selects page [page] (`>= 1`) with [perPage] (`>= 1`) rows.
  SelectQuery page(int page, int perPage) {
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'must be >= 1');
    }
    if (perPage < 1) {
      throw ArgumentError.value(perPage, 'perPage', 'must be >= 1');
    }
    _limit = perPage;
    _offset = (page - 1) * perPage;
    return this;
  }

  // -- compile ------------------------------------------------------------------
  /// Compiles the full `SELECT ...` statement.
  CompiledSql compile() {
    final sb = StringBuffer('SELECT ');
    if (_distinct) sb.write('DISTINCT ');
    sb.write(_columns.map(_compileProjection).join(', '));
    sb.write(' FROM ');
    sb.write(quoteIdent(table));
    if (alias != null) sb.write(' AS ${quoteIdent(alias!)}');

    final args = <Object?>[];
    for (final j in _joins) {
      final c = j.compile();
      sb.write(' ${c.sql}');
      args.addAll(c.args);
    }
    if (_where != null) {
      final c = _where!.compile();
      sb.write(' WHERE ${c.sql}');
      args.addAll(c.args);
    }
    if (_groupBys.isNotEmpty) {
      sb.write(' GROUP BY ${_groupBys.map(quoteIdent).join(', ')}');
    }
    if (_having != null) {
      final c = _having!.compile();
      sb.write(' HAVING ${c.sql}');
      args.addAll(c.args);
    }
    if (_orders.isNotEmpty) {
      sb.write(' ORDER BY ${_orders.map((o) => o.compile()).join(', ')}');
    }
    if (_limit != null) sb.write(' LIMIT ${_limit!}');
    if (_offset != null) {
      if (_limit == null) sb.write(' LIMIT -1');
      sb.write(' OFFSET ${_offset!}');
    }
    return CompiledSql(sb.toString(), args);
  }

  static String _compileProjection(String expr) {
    final t = expr.trim();
    if (t == '*') return '*';
    if (t.endsWith('.*')) {
      return '${quoteIdent(t.substring(0, t.length - 2))}.*';
    }
    // function call, `AS` alias, spaced expression, or already quoted -> raw
    if (t.contains('(') || RegExp(r'\s').hasMatch(t)) return t;
    return quoteIdent(t);
  }

  // Exposed for adapters/tests.
  /// The current `WHERE` predicate, if any.
  Condition? get whereCondition => _where;

  /// The current `HAVING` predicate, if any.
  Condition? get havingCondition => _having;

  /// Joins added so far.
  List<Join> get joins => List.unmodifiable(_joins);

  /// Orderings added so far.
  List<Order> get orders => List.unmodifiable(_orders);

  /// The `LIMIT`, if set.
  int? get limitValue => _limit;

  /// The `OFFSET`, if set.
  int? get offsetValue => _offset;

  /// The current projection.
  List<String> get columns => List.unmodifiable(_columns);

  /// Whether `DISTINCT` is enabled.
  bool get isDistinct => _distinct;

  /// The `GROUP BY` columns.
  List<String> get groupByColumns => List.unmodifiable(_groupBys);

  /// Deep-ish copy (conditions/joins are immutable, so shared refs are safe).
  /// Copies this query (conditions/joins are immutable, so shared refs are safe).
  SelectQuery clone() {
    final q = SelectQuery(table, alias: alias)
      .._columns = List.of(_columns)
      .._distinct = _distinct
      .._where = _where
      .._having = _having
      .._limit = _limit
      .._offset = _offset;
    q._joins.addAll(_joins);
    q._groupBys.addAll(_groupBys);
    q._orders.addAll(_orders);
    return q;
  }
}

/// Compiles `INSERT INTO ...` (single or multi-row).
/// Compiles a single-row `INSERT INTO [table]` for [row].
CompiledSql compileInsert(String table, Map<String, Object?> row,
    {bool orReplace = false, bool orIgnore = false}) {
  return compileInsertMany(table, [row],
      orReplace: orReplace, orIgnore: orIgnore);
}

/// Compiles a multi-row `INSERT INTO [table]` for [rows].
CompiledSql compileInsertMany(String table, List<Map<String, Object?>> rows,
    {bool orReplace = false, bool orIgnore = false}) {
  if (rows.isEmpty) {
    throw ArgumentError.value(rows, 'rows', 'must not be empty');
  }
  if (rows.first.isEmpty) {
    throw ArgumentError.value(rows.first, 'rows', 'row maps must not be empty');
  }
  final cols = rows.first.keys.toList();
  final or = orReplace ? 'OR REPLACE ' : (orIgnore ? 'OR IGNORE ' : '');
  final sb = StringBuffer(
      'INSERT $or INTO ${quoteIdent(table)} (${cols.map(quoteIdent).join(', ')}) VALUES ');
  final args = <Object?>[];
  for (var i = 0; i < rows.length; i++) {
    if (i > 0) sb.write(', ');
    sb.write('(${List.filled(cols.length, '?').join(', ')})');
    for (final c in cols) {
      args.add(toSqlValue(rows[i][c]));
    }
  }
  return CompiledSql(sb.toString(), args);
}

/// Compiles `INSERT ... ON CONFLICT ... DO UPDATE/ NOTHING` (upsert).
/// Compiles an upsert of [row] into [table], conflicting over [onConflict].
CompiledSql compileUpsert(
  String table,
  Map<String, Object?> row, {
  List<String> onConflict = const ['id'],
  bool updateAll = true,
  List<String>? updateColumns,
}) {
  final base = compileInsert(table, row);
  final sb = StringBuffer(base.sql);
  final args = List<Object?>.of(base.args);
  if (onConflict.isEmpty) return base;
  sb.write(' ON CONFLICT (${onConflict.map(quoteIdent).join(', ')})');
  final cols = row.keys.where((k) => !onConflict.contains(k)).toList();
  final toUpdate = updateColumns ?? (updateAll ? cols : cols);
  if (toUpdate.isEmpty) {
    sb.write(' DO NOTHING');
  } else {
    sb.write(
        ' DO UPDATE SET ${toUpdate.map((c) => '${quoteIdent(c)} = excluded.${quoteIdent(c)}').join(', ')}');
  }
  return CompiledSql(sb.toString(), args);
}

/// Compiles `UPDATE ... SET ... WHERE ...`.
/// Compiles `UPDATE [table] SET ...` of [values], filtered by [where].
CompiledSql compileUpdate(
    String table, Map<String, Object?> values, Condition? where) {
  if (values.isEmpty) {
    throw ArgumentError.value(values, 'values', 'must not be empty');
  }
  final cols = values.keys.toList();
  final sb = StringBuffer('UPDATE ${quoteIdent(table)} SET ');
  sb.write(cols.map((c) => '${quoteIdent(c)} = ?').join(', '));
  final args = cols.map((c) => toSqlValue(values[c])).toList();
  if (where != null) {
    final c = where.compile();
    sb.write(' WHERE ${c.sql}');
    args.addAll(c.args);
  }
  return CompiledSql(sb.toString(), args);
}

/// Compiles an atomic `UPDATE ... SET col = col + ? WHERE ...`.
/// Compiles `UPDATE [table] SET [column] = [column] + [by]`, filtered by [where].
CompiledSql compileIncrement(
    String table, String column, num by, Condition? where) {
  final sb = StringBuffer(
      'UPDATE ${quoteIdent(table)} SET ${quoteIdent(column)} = ${quoteIdent(column)} + ?');
  final args = <Object?>[by];
  if (where != null) {
    final c = where.compile();
    sb.write(' WHERE ${c.sql}');
    args.addAll(c.args);
  }
  return CompiledSql(sb.toString(), args);
}

/// Compiles `DELETE FROM ... WHERE ...`.
/// Compiles `DELETE FROM [table]`, filtered by [where].
CompiledSql compileDelete(String table, Condition? where) {
  final sb = StringBuffer('DELETE FROM ${quoteIdent(table)}');
  final args = <Object?>[];
  if (where != null) {
    final c = where.compile();
    sb.write(' WHERE ${c.sql}');
    args.addAll(c.args);
  }
  return CompiledSql(sb.toString(), args);
}
