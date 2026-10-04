import 'filter.dart';
import 'query.dart';
import 'sql.dart';

/// Minimal capability interface every backend must implement.
///
/// Implementations: [MemoryAdapter][1], `Sqlite3Adapter`.
///
/// [1]: `adapters/memory_adapter.dart`
abstract class DbAdapter {
  /// Runs [query] and returns matching rows.
  Future<List<Map<String, Object?>>> select(SelectQuery query);

  /// Runs raw SELECT [sql] with [args] and returns matching rows.
  Future<List<Map<String, Object?>>> rawSelect(String sql,
      [List<Object?> args = const []]);

  /// Inserts [row], returning the new row id.
  Future<int> insert(String table, Map<String, Object?> row);

  /// Inserts every row in [rows].
  Future<void> insertMany(String table, List<Map<String, Object?>> rows);

  /// Inserts [row], updating on conflict over [onConflict] columns.
  Future<void> upsert(String table, Map<String, Object?> row,
      {List<String> onConflict});

  /// Updates matching rows, returning the affected count.
  Future<int> update(String table, Map<String, Object?> values,
      [Condition? where]);

  /// Deletes matching rows, returning the affected count.
  Future<int> delete(String table, [Condition? where]);

  /// Atomically adds [by] to [column] on every matching row.
  ///
  /// SQL backends implement this as a single `UPDATE` statement
  /// (no read-modify-write race); the memory backend loops portably.
  Future<int> updateIncrement(String table, String column, num by,
      [Condition? where]);

  /// Runs a raw statement (DDL / pragma / raw write).
  Future<void> execute(String sql, [List<Object?> args = const []]);

  /// Counts rows, optionally filtered by [where].
  Future<int> count(String table, [Condition? where]);

  /// Whether any row matches [where].
  Future<bool> exists(String table, [Condition? where]);

  /// Runs [action] inside a transaction (rollback on error).
  Future<T> transaction<T>(Future<T> Function(DbAdapter tx) action);

  /// Releases backend resources. Idempotent.
  Future<void> close();
}

/// Compiled SQL pretty printer for debugging (`db.logSql = true`).
String debugSql(CompiledSql c) {
  var i = 0;
  return c.sql.replaceAllMapped(RegExp(r'\?'), (_) {
    if (i >= c.args.length) return '?';
    final v = c.args[i++];
    if (v == null) return 'NULL';
    if (v is num) return '$v';
    return "'$v'";
  });
}
