import 'dart:convert';

/// A compiled SQL statement + positional arguments (`?` placeholders).
class CompiledSql {
  /// The SQL text with `?` placeholders.
  final String sql;

  /// Values bound to the placeholders, in order.
  final List<Object?> args;

  /// Creates a compiled statement of [sql] with [args].
  const CompiledSql(this.sql, [this.args = const []]);

  @override
  String toString() => 'CompiledSql($sql, args: $args)';
}

/// SQLite identifier quoting: `"table"."column"`, escaping embedded quotes.
String quoteIdent(String ident) {
  if (ident.isEmpty) {
    throw ArgumentError.value(ident, 'ident', 'must not be empty');
  }
  if (ident == '*') return '*';
  // Support `table.column` and `table.*`
  if (ident.contains('.')) {
    return ident.split('.').map(quoteIdent).join('.');
  }
  // Already-quoted or function call / alias expression -> leave alone.
  final t = ident.trim();
  if (t.contains('(') || t.contains(' ') || t.startsWith('"')) return ident;
  return '"${ident.replaceAll('"', '""')}"';
}

/// Normalizes Dart values to SQLite-storable values.
///
/// `bool` becomes `0`/`1`, `DateTime` becomes ISO-8601 text, `Enum` becomes
/// its `name`, and `List`/`Map` become JSON text.
Object? toSqlValue(Object? v) {
  if (v == null) return null;
  if (v is bool) return v ? 1 : 0;
  if (v is DateTime) return v.toIso8601String();
  if (v is Enum) return v.name;
  if (v is Map || v is List) return jsonEncode(v);
  return v;
}

/// Converts a SQLite scalar back to a friendly Dart value (0/1 stays int;
/// callers can cast). Booleans round-trip via [toSqlValue].
Object? fromSqlValue(Object? v) => v;
