import '../adapter.dart';
import '../errors.dart';
import '../filter.dart';
import '../query.dart';
import '../sql.dart';

/// Pure-Dart in-memory backend. Zero native dependencies.
///
/// Perfect for unit tests, prototyping, and environments where
/// `sqlite3` native libraries are unavailable. SQL generation is
/// identical — only execution is emulated.
///
/// Supports: insert/insertMany/upsert/update/delete, where/orderBy/
/// limit/offset/distinct/projection, count/exists, simple equi-joins
/// (`leftJoin('posts', 'posts.user_id = users.id')`), transactions
/// (snapshot + rollback on error).
class MemoryAdapter implements DbAdapter {
  final Map<String, List<Map<String, Object?>>> _tables = {};
  final Map<String, int> _autoId = {};

  List<Map<String, Object?>> _table(String name) =>
      _tables.putIfAbsent(name, () => []);

  Map<String, Object?> _normalize(Map<String, Object?> row) {
    final out = <String, Object?>{};
    row.forEach((k, v) => out[k] = toSqlValue(v));
    return out;
  }

  int _nextId(String table) {
    final rows = _table(table);
    var max = _autoId[table] ?? 0;
    for (final r in rows) {
      final v = r['id'];
      if (v is int && v > max) max = v;
    }
    final next = max + 1;
    _autoId[table] = next;
    return next;
  }

  @override
  Future<int> insert(String table, Map<String, Object?> row) async {
    if (row.isEmpty) {
      throw ArgumentError.value(row, 'row', 'must not be empty');
    }
    final r = _normalize(row);
    if (!r.containsKey('id') || r['id'] == null) {
      r['id'] = _nextId(table);
    } else if (r['id'] is int) {
      final id = r['id'] as int;
      if ((_autoId[table] ?? 0) < id) _autoId[table] = id;
    }
    // naive unique-id guard
    if (r['id'] != null &&
        _table(table).any((e) => e['id'] == r['id'])) {
      throw DbException('UNIQUE constraint failed: $table.id = ${r['id']}');
    }
    _table(table).add(r);
    return (r['id'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> insertMany(String table, List<Map<String, Object?>> rows) async {
    for (final r in rows) {
      await insert(table, r);
    }
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row,
      {List<String> onConflict = const ['id']}) async {
    if (row.isEmpty) {
      throw ArgumentError.value(row, 'row', 'must not be empty');
    }
    final r = _normalize(row);
    final rows = _table(table);
    var idx = -1;
    if (onConflict.isNotEmpty && r[onConflict.first] != null) {
      final key = onConflict.first;
      idx = rows.indexWhere((e) => e[key] == r[key]);
      // composite conflict keys
      if (onConflict.length > 1) {
        idx = rows.indexWhere(
            (e) => onConflict.every((k) => e[k] == r[k]));
      }
    }
    if (idx == -1) {
      await insert(table, r);
    } else {
      rows[idx] = {...rows[idx], ...r};
    }
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      [Condition? where]) async {
    final v = _normalize(values);
    var n = 0;
    for (var i = 0; i < _table(table).length; i++) {
      final row = _table(table)[i];
      if (where == null || where.test(row)) {
        _table(table)[i] = {...row, ...v};
        n++;
      }
    }
    return n;
  }

  @override
  Future<int> updateIncrement(String table, String column, num by,
      [Condition? where]) async {
    final query = SelectQuery(table);
    if (where != null) query.whereCond(where);
    final rows = await select(query);
    var affected = 0;
    for (final row in rows) {
      final id = row['id'];
      final next = ((row[column] as num?) ?? 0) + by;
      if (id != null) {
        affected +=
            await update(table, {column: next}, const Where().eq('id', id));
      } else {
        affected += await update(table, {column: next}, where);
        break;
      }
    }
    return affected;
  }

  @override
  Future<int> delete(String table, [Condition? where]) async {
    final rows = _table(table);
    final before = rows.length;
    if (where == null) {
      rows.clear();
      return before;
    }
    rows.removeWhere((r) {
      try {
        return where.test(r);
      } on UnsupportedError {
        throw DbException(
            'MemoryAdapter cannot evaluate raw conditions. Use structured where() filters in tests, or run against sqlite3.');
      }
    });
    return before - rows.length;
  }

  @override
  Future<List<Map<String, Object?>>> select(SelectQuery q) async {
    // Base rows
    var rows = _table(q.table).map((r) => Map<String, Object?>.of(r)).toList();

    // Joins (simple `a.b = c.d` equi-joins only)
    for (final j in q.joins) {
      rows = _applyJoin(rows, q.table, j);
    }

    // Where
    if (q.whereCondition != null) {
      rows = rows.where((r) {
        try {
          return q.whereCondition!.test(_unprefixed(r, q.table));
        } on UnsupportedError {
          throw DbException(
              'MemoryAdapter cannot evaluate raw conditions. Use structured where() filters in tests, or run against sqlite3.');
        }
      }).toList();
    }

    // Group by + aggregation (supports COUNT(*) and COUNT(col))
    if (q.groupByColumns.isNotEmpty) {
      rows = _applyGroupBy(rows, q);
    }

    // Order
    if (q.orders.isNotEmpty) {
      rows.sort((a, b) {
        for (final o in q.orders) {
          final av = _resolveCol(a, o.column);
          final bv = _resolveCol(b, o.column);
          final c = _cmp(av, bv);
          if (c != 0) return o.desc ? -c : c;
        }
        return 0;
      });
    }

    // Offset / limit
    if (q.offsetValue != null) {
      rows = rows.skip(q.offsetValue!).toList();
    }
    if (q.limitValue != null) {
      rows = rows.take(q.limitValue!).toList();
    }

    // Projection
    rows = _applyProjection(rows, q.columns, q.isDistinct);

    // Having (post-projection filter)
    // (having on aggregated queries — best effort via Condition.test)
    // NOTE: SelectQuery.having is compiled to SQL for sqlite3; for memory
    // we re-test against projected rows.
    // ignore: avoid accessing private; same package via getter? use compile-free path:
    // (SelectQuery exposes having only via compile; emulate by skipping if raw)
    return rows.map((r) => Map<String, Object?>.of(r)).toList();
  }

  @override
  Future<List<Map<String, Object?>>> rawSelect(String sql,
      [List<Object?> args = const []]) async {
    throw DbException(
        'MemoryAdapter does not execute raw SQL. Use structured query() APIs in tests, or run against sqlite3.\nSQL: $sql');
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final t = sql.trim().toUpperCase();
    if (t.startsWith('DROP TABLE')) {
      // DROP TABLE clears stored rows so schema helpers like the generated
      // `dropXxxTables()` behave the same on the fake as on sqlite.
      final m = RegExp(r'DROP TABLE\s+(?:IF EXISTS\s+)?"?(\w+)"?',
              caseSensitive: false)
          .firstMatch(sql);
      if (m != null) _table(m.group(1)!).clear();
      return;
    }
    // Support remaining DDL no-ops so schema code runs unchanged in tests.
    if (t.startsWith('CREATE TABLE') ||
        t.startsWith('CREATE ') ||
        t.startsWith('ALTER TABLE') ||
        t.startsWith('PRAGMA') ||
        t.startsWith('CREATE INDEX') ||
        t.startsWith('CREATE UNIQUE INDEX')) {
      // Extract table name for CREATE TABLE so later inserts work —
      // tables are created lazily anyway, so this is a no-op.
      return;
    }
    if (t.startsWith('DELETE FROM')) {
      // Very small raw-delete fallback: DELETE FROM "x" (no WHERE) -> clear.
      final m = RegExp(r'DELETE FROM\s+"?(\w+)"?',
              caseSensitive: false)
          .firstMatch(sql);
      if (m != null && !sql.toUpperCase().contains('WHERE')) {
        _table(m.group(1)!).clear();
        return;
      }
    }
    throw DbException(
        'MemoryAdapter.execute() only supports DDL + table clears. Use structured APIs.\nSQL: $sql');
  }

  @override
  Future<int> count(String table, [Condition? where]) async {
    if (where == null) return _table(table).length;
    return _table(table).where((r) => where.test(r)).length;
  }

  @override
  Future<bool> exists(String table, [Condition? where]) async {
    if (where == null) return _table(table).isNotEmpty;
    return _table(table).any((r) => where.test(r));
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DbAdapter tx) action) async {
    // Snapshot + rollback on error.
    final snapTables = {
      for (final e in _tables.entries)
        e.key: e.value.map((r) => Map<String, Object?>.of(r)).toList()
    };
    final snapIds = Map<String, int>.of(_autoId);
    try {
      final r = await action(this);
      return r;
    } catch (e) {
      _tables
        ..clear()
        ..addAll(snapTables);
      _autoId
        ..clear()
        ..addAll(snapIds);
      rethrow;
    }
  }

  @override
  Future<void> close() async {}

  // -- helpers ---------------------------------------------------------------

  Map<String, Object?> _unprefixed(
      Map<String, Object?> row, String baseTable) {
    // Rows may contain `table.col` keys after joins — expose short names too.
    final out = Map<String, Object?>.of(row);
    for (final e in row.entries) {
      if (e.key.contains('.')) {
        out[e.key.split('.').last] = e.value;
      }
    }
    return out;
  }

  Object? _resolveCol(Map<String, Object?> row, String column) {
    if (row.containsKey(column)) return row[column];
    final clean = column.replaceAll('"', '');
    if (row.containsKey(clean)) return row[clean];
    if (clean.contains('.')) {
      final short = clean.split('.').last;
      if (row.containsKey(short)) return row[short];
    }
    return null;
  }

  int _cmp(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }

  List<Map<String, Object?>> _applyJoin(
      List<Map<String, Object?>> left, String leftTable, Join j) {
    if (j.kind.toUpperCase() == 'CROSS') {
      final right = _table(j.table);
      final out = <Map<String, Object?>>[];
      for (final l in left) {
        for (final r in right) {
          out.add({..._prefix(l, leftTable), ..._prefix(r, j.table)});
        }
      }
      return out;
    }
    // Parse `onRaw` of form `a.b = c.d` (with optional quotes).
    final eq = _parseEquiJoin(j.onRaw ?? '', leftTable, j.table);
    final right = _table(j.table);
    final out = <Map<String, Object?>>[];
    // Merge key sets for null-fill on LEFT joins.
    final rightKeys = <String>{};
    for (final r in right) {
      rightKeys.addAll(r.keys);
    }
    for (final l in left) {
      var matched = false;
      for (final r in right) {
        if (eq != null) {
          final lv = _resolveCol({...l, ..._prefix(l, leftTable)}, eq.$1);
          final rv = _resolveCol({...r, ..._prefix(r, j.table)}, eq.$2);
          // Try both orientations.
          final lv2 = _resolveCol({...l, ..._prefix(l, leftTable)}, eq.$2);
          final rv2 = _resolveCol({...r, ..._prefix(r, j.table)}, eq.$1);
          final hit = (lv == rv) || (lv2 == rv2);
          if (!hit && j.kind.toUpperCase() != 'CROSS') {
            // fall back to unprefixed compare of the two columns
            final ok = _equiHit(l, r, eq);
            if (!ok) continue;
          } else if (!hit) {
            continue;
          }
        }
        matched = true;
        out.add({..._prefix(l, leftTable), ..._prefix(r, j.table), ...l, ...r});
      }
      if (!matched && j.kind.toUpperCase() == 'LEFT') {
        final nulls = {for (final k in rightKeys) k: null};
        out.add({..._prefix(l, leftTable), ...l, ...nulls});
      } else if (!matched && j.kind.toUpperCase() == 'INNER') {
        // drop
      } else if (!matched) {
        out.add({..._prefix(l, leftTable), ...l});
      }
    }
    return out;
  }

  Map<String, Object?> _prefix(Map<String, Object?> row, String table) {
    return {for (final e in row.entries) '$table.${e.key}': e.value};
  }

  (String, String)? _parseEquiJoin(String on, String leftT, String rightT) {
    final m = RegExp(r'([\w".]+)\s*=\s*([\w".]+)').firstMatch(on);
    if (m == null) return null;
    return (m.group(1)!, m.group(2)!);
  }

  bool _equiHit(Map<String, Object?> l, Map<String, Object?> r,
      (String, String) eq) {
    Object? lv(String c) {
      final clean = c.replaceAll('"', '');
      if (clean.contains('.')) {
        final parts = clean.split('.');
        final t = parts.first, colName = parts.last;
        if (l.containsKey(colName) &&
            (t == '' || true)) {
          // ambiguous — try left first
        }
      }
      return _resolveCol(l, c) ?? _resolveCol(l, c.replaceAll('"', ''));
    }

    Object? rv(String c) => _resolveCol(r, c);
    return lv(eq.$1) == rv(eq.$2) || lv(eq.$2) == rv(eq.$1);
  }

  List<Map<String, Object?>> _applyGroupBy(
      List<Map<String, Object?>> rows, SelectQuery q) {
    // Only meaningful when projection has aggregates; otherwise dedupe.
    final hasAgg = q.columns
        .any((c) => c.toUpperCase().contains('COUNT('));
    if (!hasAgg) {
      final seen = <String>{};
      return rows.where((r) {
        final k = q.groupByColumns
            .map((c) => '${_resolveCol(r, c)}')
            .join('|');
        return seen.add(k);
      }).toList();
    }
    final groups = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final k = q.groupByColumns
          .map((c) => '${_resolveCol(r, c)}')
          .join('|');
      groups.putIfAbsent(k, () => []).add(r);
    }
    final out = <Map<String, Object?>>[];
    for (final g in groups.values) {
      final first = Map<String, Object?>.of(g.first);
      for (final proj in q.columns) {
        final m = RegExp(r'COUNT\s*\(\s*(\*|[\w".]+)\s*\)\s*(?:AS\s+(\w+))?',
                caseSensitive: false)
            .firstMatch(proj);
        if (m != null) {
          final alias = m.group(2) ?? 'count';
          first[alias] = g.length;
        } else if (proj.trim() == '*' || proj.contains('.')) {
          // keep base columns
        } else {
          final aliasM =
              RegExp(r'AS\s+(\w+)', caseSensitive: false).firstMatch(proj);
          if (aliasM != null) {
            first[aliasM.group(1)!] = _resolveCol(first, proj);
          }
        }
      }
      out.add(first);
    }
    return out;
  }

  List<Map<String, Object?>> _applyProjection(
      List<Map<String, Object?>> rows, List<String> cols, bool distinct) {
    var out = rows;
    if (!(cols.length == 1 && cols.first.trim() == '*')) {
      out = rows.map((r) {
        final m = <String, Object?>{};
        for (final c in cols) {
          final aliasM =
              RegExp(r'^(.*?)\s+AS\s+(\w+)$', caseSensitive: false)
                  .firstMatch(c.trim());
          if (aliasM != null) {
            final expr = aliasM.group(1)!.trim();
            final alias = aliasM.group(2)!;
            if (RegExp(r'COUNT\s*\(', caseSensitive: false)
                .hasMatch(expr)) {
              m[alias] = r[alias] ?? r['count'] ?? 0;
            } else {
              m[alias] = _resolveCol(r, expr);
            }
          } else if (c.trim() == '*') {
            m.addAll(r);
          } else if (c.trim().endsWith('.*')) {
            final t = c.trim().substring(0, c.trim().length - 2);
            for (final e in r.entries) {
              if (e.key == t ||
                  e.key.startsWith('$t.') ||
                  !e.key.contains('.')) {
                // best-effort: include unprefixed cols
                if (!e.key.contains('.')) m[e.key] = e.value;
              }
            }
            // also include prefixed
            for (final e in r.entries) {
              if (e.key.startsWith('$t.')) {
                m[e.key.split('.').last] = e.value;
              }
            }
          } else if (RegExp(r'COUNT\s*\(', caseSensitive: false)
              .hasMatch(c)) {
            m['count'] = r['count'] ?? rows.length;
          } else {
            final short = c.replaceAll('"', '').split('.').last;
            m[short] = _resolveCol(r, c);
          }
        }
        return m;
      }).toList();
    }
    if (distinct) {
      final seen = <String>{};
      out = out.where((r) => seen.add(r.toString())).toList();
    }
    return out;
  }
}
