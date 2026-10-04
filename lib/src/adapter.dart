import 'filter.dart';
import 'query.dart';
import 'sql.dart';

/// Minimal capability interface every backend must implement.
///
/// Implementations: [MemoryAdapter][1], `Sqlite3Adapter`.
///
/// [1]: `adapters/memory_adapter.dart`
abstract class DbAdapter {
  Future<List<Map<String, Object?>>> select(SelectQuery query);
  Future<List<Map<String, Object?>>> rawSelect(String sql, [List<Object?> args = const []]);

  Future<int> insert(String table, Map<String, Object?> row);
  Future<void> insertMany(String table, List<Map<String, Object?>> rows);
  Future<void> upsert(String table, Map<String, Object?> row,
      {List<String> onConflict});

  Future<int> update(String table, Map<String, Object?> values,
      [Condition? where]);
  Future<int> delete(String table, [Condition? where]);

  /// Atomically adds [by] to [column] on every matching row.
  ///
  /// SQL backends implement this as a single `UPDATE` statement
  /// (no read-modify-write race); the memory backend loops portably.
  Future<int> updateIncrement(String table, String column, num by,
      [Condition? where]);

  Future<void> execute(String sql, [List<Object?> args = const []]);
  Future<int> count(String table, [Condition? where]);
  Future<bool> exists(String table, [Condition? where]);

  Future<T> transaction<T>(Future<T> Function(DbAdapter tx) action);

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
