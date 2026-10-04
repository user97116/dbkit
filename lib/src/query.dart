import 'filter.dart';
import 'sql.dart';

/// A JOIN clause.
class Join {
  final String kind; // INNER, LEFT, RIGHT, CROSS, FULL
  final String table;
  final String? alias;
  final Condition? onCond;
  final String? onRaw;

  const Join._(this.kind, this.table, {this.alias, this.onCond, this.onRaw});

  factory Join.on(String kind, String table, Condition on,
          {String? alias}) =>
      Join._(kind, table, onCond: on, alias: alias);

  factory Join.raw(String kind, String table, String onSql,
          {String? alias}) =>
      Join._(kind, table, onRaw: onSql, alias: alias);

  String get fromFragment =>
      alias == null ? quoteIdent(table) : '${quoteIdent(table)} AS ${quoteIdent(alias!)}';

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

class Order {
  final String column;
  final bool desc;
  final bool? nullsFirst;
  const Order(this.column, {this.desc = false, this.nullsFirst});

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
  final String table;
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

  SelectQuery(this.table, {this.alias});

  // -- projection -----------------------------------------------------------
  SelectQuery select(List<String> columns) {
    _columns = List.of(columns);
    return this;
  }

  SelectQuery selectAppend(List<String> columns) {
    if (_columns.length == 1 && _columns.first == '*') {
      _columns = List.of(columns);
    } else {
      _columns.addAll(columns);
    }
    return this;
  }

  SelectQuery countAll({String as = 'count'}) =>
      select(['COUNT(*) AS $as']);

  SelectQuery distinct([bool v = true]) {
    _distinct = v;
    return this;
  }

  // -- joins ----------------------------------------------------------------
  SelectQuery join(String table, Condition on,
      {String kind = 'INNER', String? alias}) {
    _joins.add(Join.on(kind, table, on, alias: alias));
    return this;
  }

  SelectQuery joinRaw(String table, String onSql,
      {String kind = 'INNER', String? alias}) {
    _joins.add(Join.raw(kind, table, onSql, alias: alias));
    return this;
  }

  SelectQuery innerJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'INNER', alias: alias);
  SelectQuery leftJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'LEFT', alias: alias);
  SelectQuery rightJoin(String table, String onSql, {String? alias}) =>
      joinRaw(table, onSql, kind: 'RIGHT', alias: alias);
  SelectQuery crossJoin(String table) {
    _joins.add(Join.raw('CROSS', table, '', alias: null));
    return this;
  }

  // -- filtering --------------------------------------------------------------
  SelectQuery whereCond(Condition c) {
    _where = _where == null ? c : _where! & c;
    return this;
  }

  SelectQuery where(Condition Function(Where w) build) =>
      whereCond(build(const Where()));

  SelectQuery orWhere(Condition Function(Where w) build) {
    final c = build(const Where());
    _where = _where == null ? c : _where! | c;
    return this;
  }

  SelectQuery whereEq(String column, Object? value) =>
      whereCond(const Where().eq(column, value));

  SelectQuery whereRaw(String fragment, [List<Object?> args = const []]) =>
      whereCond(RawCondition(fragment, args));

  // -- grouping / ordering / paging -------------------------------------------
  SelectQuery groupBy(List<String> columns) {
    _groupBys.addAll(columns);
    return this;
  }

  SelectQuery havingCond(Condition c) {
    _having = _having == null ? c : _having! & c;
    return this;
  }

  SelectQuery having(Condition Function(Where w) build) =>
      havingCond(build(const Where()));

  SelectQuery orderBy(String column,
      {bool desc = false, bool? nullsFirst}) {
    _orders.add(Order(column, desc: desc, nullsFirst: nullsFirst));
    return this;
  }

  SelectQuery orderByDesc(String column) => orderBy(column, desc: true);

  SelectQuery limit(int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be >= 0');
    }
    _limit = n;
    return this;
  }

  SelectQuery offset(int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be >= 0');
    }
    _offset = n;
    return this;
  }

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
  Condition? get whereCondition => _where;
  Condition? get havingCondition => _having;
  List<Join> get joins => List.unmodifiable(_joins);
  List<Order> get orders => List.unmodifiable(_orders);
  int? get limitValue => _limit;
  int? get offsetValue => _offset;
  List<String> get columns => List.unmodifiable(_columns);
  bool get isDistinct => _distinct;
  List<String> get groupByColumns => List.unmodifiable(_groupBys);

  /// Deep-ish copy (conditions/joins are immutable, so shared refs are safe).
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
CompiledSql compileInsert(String table, Map<String, Object?> row,
    {bool orReplace = false, bool orIgnore = false}) {
  return compileInsertMany(table, [row],
      orReplace: orReplace, orIgnore: orIgnore);
}

CompiledSql compileInsertMany(String table, List<Map<String, Object?>> rows,
    {bool orReplace = false, bool orIgnore = false}) {
  if (rows.isEmpty) {
    throw ArgumentError.value(rows, 'rows', 'must not be empty');
  }
  if (rows.first.isEmpty) {
    throw ArgumentError.value(
        rows.first, 'rows', 'row maps must not be empty');
  }
  final cols = rows.first.keys.toList();
  final or = orReplace
      ? 'OR REPLACE '
      : (orIgnore ? 'OR IGNORE ' : '');
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
  sb.write(
      ' ON CONFLICT (${onConflict.map(quoteIdent).join(', ')})');
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
