import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../adapter.dart';
import '../errors.dart';
import '../filter.dart';
import '../query.dart';
import '../sql.dart';

/// `sqlite3` (native SQLite) backend. Works on all desktop/mobile targets
/// via `package:sqlite3`.
///
/// Use [Sqlite3Adapter.memory()] for an ephemeral DB or
/// [Sqlite3Adapter.open()] for a file.
class Sqlite3Adapter implements DbAdapter {
  final sqlite.Database _db;
  int _txDepth = 0;
  bool _closed = false;

  Sqlite3Adapter._(this._db);

  /// In-memory backend (real SQL engine, ephemeral).
  factory Sqlite3Adapter.memory() {
    final adapter = Sqlite3Adapter._(sqlite.sqlite3.openInMemory());
    adapter._applyPragmas(journalWal: false);
    return adapter;
  }

  /// File-backed backend at [path] (WAL mode applied).
  factory Sqlite3Adapter.open(String path) {
    final adapter = Sqlite3Adapter._(sqlite.sqlite3.open(path));
    adapter._applyPragmas(journalWal: true);
    return adapter;
  }

  /// Wraps an existing `sqlite3` database (e.g. shared connection).
  ///
  /// Pragmas are NOT applied here — the owner of the connection decides.
  factory Sqlite3Adapter.wrap(Object db) =>
      Sqlite3Adapter._(db as sqlite.Database);

  /// Production defaults: enforced foreign keys and a bounded lock wait.
  /// File-backed databases additionally get WAL + NORMAL synchronous mode
  /// for concurrent readers without blocking writers.
  void _applyPragmas({required bool journalWal}) {
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('PRAGMA busy_timeout = 5000;');
    if (journalWal) {
      try {
        _db.execute('PRAGMA journal_mode = WAL;');
        _db.execute('PRAGMA synchronous = NORMAL;');
      } catch (_) {
        // Best effort: keep the database usable without WAL.
      }
    }
  }

  List<Map<String, Object?>> _rows(sqlite.ResultSet rs) =>
      [for (final r in rs) Map<String, Object?>.from(r)];

  @override
  Future<List<Map<String, Object?>>> select(SelectQuery query) async {
    final c = query.compile();
    return rawSelect(c.sql, c.args);
  }

  @override
  Future<List<Map<String, Object?>>> rawSelect(String sql,
      [List<Object?> args = const []]) async {
    try {
      final stmt = _db.prepare(sql);
      try {
        final rs = stmt.select(args.map(toSqlValue).toList());
        return _rows(rs);
      } finally {
        stmt.close();
      }
    } catch (e) {
      throw DbException('select failed: $e', cause: e, sql: sql);
    }
  }

  @override
  Future<int> insert(String table, Map<String, Object?> row) async {
    final c = compileInsert(table, row);
    try {
      final stmt = _db.prepare(c.sql);
      try {
        stmt.execute(c.args.map(toSqlValue).toList());
      } finally {
        stmt.close();
      }
      return _db.lastInsertRowId;
    } catch (e) {
      throw DbException('insert into $table failed: $e', cause: e, sql: c.sql);
    }
  }

  @override
  Future<void> insertMany(String table, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    // Validate uniform keys, then batch inside a transaction.
    await transaction((tx) async {
      for (final r in rows) {
        await tx.insert(table, r);
      }
    });
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row,
      {List<String> onConflict = const ['id']}) async {
    final c = compileUpsert(table, row, onConflict: onConflict);
    try {
      _db.execute(c.sql, c.args.map(toSqlValue).toList());
    } catch (e) {
      throw DbException('upsert into $table failed: $e', cause: e, sql: c.sql);
    }
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      [Condition? where]) async {
    final c = compileUpdate(table, values, where);
    try {
      _db.execute(c.sql, c.args.map(toSqlValue).toList());
      return _db.updatedRows;
    } catch (e) {
      throw DbException('update $table failed: $e', cause: e, sql: c.sql);
    }
  }

  @override
  Future<int> updateIncrement(String table, String column, num by,
      [Condition? where]) async {
    final c = compileIncrement(table, column, by, where);
    try {
      _db.execute(c.sql, c.args.map(toSqlValue).toList());
      return _db.updatedRows;
    } catch (e) {
      throw DbException('increment $column in $table failed: $e',
          cause: e, sql: c.sql);
    }
  }

  @override
  Future<int> delete(String table, [Condition? where]) async {
    final c = compileDelete(table, where);
    try {
      _db.execute(c.sql, c.args.map(toSqlValue).toList());
      return _db.updatedRows;
    } catch (e) {
      throw DbException('delete from $table failed: $e', cause: e, sql: c.sql);
    }
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    try {
      if (args.isEmpty) {
        _db.execute(sql);
      } else {
        _db.execute(sql, args.map(toSqlValue).toList());
      }
    } catch (e) {
      throw DbException('execute failed: $e', cause: e, sql: sql);
    }
  }

  @override
  Future<int> count(String table, [Condition? where]) async {
    final q = SelectQuery(table).select(['COUNT(*) AS n']);
    if (where != null) q.whereCond(where);
    final rows = await select(q);
    final v = rows.first['n'];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  @override
  Future<bool> exists(String table, [Condition? where]) async =>
      await count(table, where) > 0;

  @override
  Future<T> transaction<T>(Future<T> Function(DbAdapter tx) action) async {
    // Nested transactions use savepoints so an inner rollback
    // never aborts the outer transaction.
    final savepoint = 'dbkit_$_txDepth';
    if (_txDepth == 0) {
      _db.execute('BEGIN IMMEDIATE');
    } else {
      _db.execute('SAVEPOINT "$savepoint"');
    }
    _txDepth++;
    try {
      final r = await action(this);
      _txDepth--;
      if (_txDepth == 0) {
        _db.execute('COMMIT');
      } else {
        _db.execute('RELEASE SAVEPOINT "$savepoint"');
      }
      return r;
    } catch (e) {
      _txDepth--;
      try {
        if (_txDepth == 0) {
          _db.execute('ROLLBACK');
        } else {
          _db.execute('ROLLBACK TO SAVEPOINT "$savepoint"');
          _db.execute('RELEASE SAVEPOINT "$savepoint"');
        }
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }
}
