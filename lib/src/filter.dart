import 'sql.dart';

/// A SQL predicate that compiles to `sql` + `args`.
///
/// Build with [Where] (recommended), [col()] + [ColumnRef] helpers,
/// or raw: `RawCondition('age > ?', [18])`.
///
/// Conditions compose with `&` (AND), `|` (OR) and `~` (NOT):
/// ```dart
/// users.where((w) => w.gt('age', 18) & w.contains('name', 'a')).get();
/// ```
sealed class Condition {
  const Condition();

  CompiledSql compile();

  /// Evaluates this predicate against an in-memory [row].
  /// Used by the memory adapter (and tests). Raw SQL fragments
  /// cannot be evaluated and throw [UnsupportedError].
  bool test(Map<String, Object?> row);

  Condition operator &(Condition other) => AndCondition([this, other]);
  Condition operator |(Condition other) => OrCondition([this, other]);
  Condition operator ~() => NotCondition(this);

  static Condition and(List<Condition> parts) => AndCondition(parts);
  static Condition or(List<Condition> parts) => OrCondition(parts);
}

class _True extends Condition {
  const _True();
  @override
  CompiledSql compile() => const CompiledSql('(1 = 1)');
  @override
  bool test(Map<String, Object?> row) => true;
}

class _False extends Condition {
  const _False();
  @override
  CompiledSql compile() => const CompiledSql('(1 = 0)');
  @override
  bool test(Map<String, Object?> row) => false;
}

/// Matches everything / nothing. Useful for dynamic filters.
const Condition alwaysTrue = _True();
const Condition alwaysFalse = _False();

Object? _resolve(String column, Map<String, Object?> row) {
  if (row.containsKey(column)) return row[column];
  // support `table.column` — strip table prefix
  if (column.contains('.')) {
    final short = column.split('.').last.replaceAll('"', '');
    if (row.containsKey(short)) return row[short];
  }
  final unquoted = column.replaceAll('"', '');
  if (row.containsKey(unquoted)) return row[unquoted];
  return null;
}

int _compare(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  // bool stored as 0/1 — normalize
  final an = toSqlValue(a);
  final bn = toSqlValue(b);
  if (an is num && bn is num) return an.compareTo(bn);
  return an.toString().compareTo(bn.toString());
}

bool _likeMatch(String? value, String pattern, {bool escaped = false}) {
  if (value == null) return false;
  // Convert SQL LIKE to RegExp: % -> .*, _ -> ., escape rest.
  // When [escaped] is true, a `\` quotes the next char literally.
  final buf = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    if (escaped && ch == r'\') {
      if (i + 1 < pattern.length) {
        buf.write(RegExp.escape(pattern[++i]));
      } else {
        buf.write(RegExp.escape(ch));
      }
    } else if (ch == '%') {
      buf.write('.*');
    } else if (ch == '_') {
      buf.write('.');
    } else {
      buf.write(RegExp.escape(ch));
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString(), caseSensitive: false).hasMatch(value);
}

/// Escapes `%`, `_` and `\` in user text so it matches literally inside a
/// SQL `LIKE` pattern. Used by [Where.contains]/`startsWith`/`endsWith`,
/// so you never write `%` wildcards yourself:
///
/// ```dart
/// users.where((w) => w.contains('name', 'a')).get(); // no `%a%` needed
/// ```
String escapeLike(String input) => input
    .replaceAll(r'\', r'\\')
    .replaceAll('%', r'\%')
    .replaceAll('_', r'\_');

class _Simple extends Condition {
  final String column;
  final String op;
  final Object? value;
  const _Simple(this.column, this.op, this.value);

  @override
  CompiledSql compile() {
    if (value == null) {
      if (op == '=') return CompiledSql('${quoteIdent(column)} IS NULL');
      if (op == '!=' || op == '<>') {
        return CompiledSql('${quoteIdent(column)} IS NOT NULL');
      }
    }
    return CompiledSql(
        '${quoteIdent(column)} $op ?', [toSqlValue(value)]);
  }

  @override
  bool test(Map<String, Object?> row) {
    final actual = _resolve(column, row);
    if (value == null) {
      if (op == '=') return actual == null;
      return actual != null;
    }
    if (actual == null) return false;
    final c = _compare(actual, value);
    switch (op) {
      case '=':
      case '==':
        return c == 0;
      case '!=':
      case '<>':
        return c != 0;
      case '>':
        return c > 0;
      case '>=':
        return c >= 0;
      case '<':
        return c < 0;
      case '<=':
        return c <= 0;
      default:
        return false;
    }
  }
}

class _Like extends Condition {
  final String column;
  final String pattern;
  final bool negated;

  /// When true, `\` quotes the next char literally and the compiled SQL
  /// carries `ESCAPE '\'`. Always true for patterns built by
  /// [Where.contains]/`startsWith`/`endsWith`.
  final bool escaped;

  const _Like(this.column, this.pattern,
      {this.negated = false, this.escaped = false});

  @override
  CompiledSql compile() {
    final op = negated ? 'NOT LIKE' : 'LIKE';
    var sql = '${quoteIdent(column)} $op ?';
    if (escaped) sql += r" ESCAPE '\'";
    return CompiledSql(sql, [pattern]);
  }

  @override
  bool test(Map<String, Object?> row) {
    final v = _resolve(column, row)?.toString();
    final m = _likeMatch(v, pattern, escaped: escaped);
    return negated ? !m : m;
  }
}

class _In extends Condition {
  final String column;
  final List<Object?> values;
  final bool negated;
  const _In(this.column, this.values, {this.negated = false});

  @override
  CompiledSql compile() {
    if (values.isEmpty) {
      return negated
          ? const CompiledSql('(1 = 1)')
          : const CompiledSql('(1 = 0)');
    }
    final ph = List.filled(values.length, '?').join(', ');
    final op = negated ? 'NOT IN' : 'IN';
    return CompiledSql('${quoteIdent(column)} $op ($ph)',
        values.map(toSqlValue).toList());
  }

  @override
  bool test(Map<String, Object?> row) {
    final actual = _resolve(column, row);
    final hit = values.any((v) => _compare(actual, v) == 0);
    return negated ? !hit : hit;
  }
}

class _Between extends Condition {
  final String column;
  final Object? low;
  final Object? high;
  final bool negated;
  const _Between(this.column, this.low, this.high, {this.negated = false});

  @override
  CompiledSql compile() {
    final op = negated ? 'NOT BETWEEN' : 'BETWEEN';
    return CompiledSql('${quoteIdent(column)} $op ? AND ?',
        [toSqlValue(low), toSqlValue(high)]);
  }

  @override
  bool test(Map<String, Object?> row) {
    final actual = _resolve(column, row);
    if (actual == null) return false;
    final inRange =
        _compare(actual, low) >= 0 && _compare(actual, high) <= 0;
    return negated ? !inRange : inRange;
  }
}

class _Null extends Condition {
  final String column;
  final bool negated;
  const _Null(this.column, {this.negated = false});

  @override
  CompiledSql compile() => CompiledSql(
      '${quoteIdent(column)} ${negated ? 'IS NOT NULL' : 'IS NULL'}');

  @override
  bool test(Map<String, Object?> row) {
    final v = _resolve(column, row);
    return negated ? v != null : v == null;
  }
}

/// Raw SQL fragment, e.g. `RawCondition('price * qty > ?', [100])`.
class RawCondition extends Condition {
  final String fragment;
  final List<Object?> args;
  const RawCondition(this.fragment, [this.args = const []]);

  @override
  CompiledSql compile() => CompiledSql('($fragment)', args);

  @override
  bool test(Map<String, Object?> row) => throw UnsupportedError(
      'RawCondition cannot be evaluated in-memory: $fragment');
}

class AndCondition extends Condition {
  final List<Condition> parts;
  const AndCondition(this.parts);

  @override
  CompiledSql compile() {
    final live = parts.where((p) => p is! _True).toList();
    if (live.isEmpty) return const CompiledSql('(1 = 1)');
    if (live.any((p) => p is _False)) return const CompiledSql('(1 = 0)');
    if (live.length == 1) return live.first.compile();
    final sql = StringBuffer('(');
    final args = <Object?>[];
    for (var i = 0; i < live.length; i++) {
      if (i > 0) sql.write(' AND ');
      final c = live[i].compile();
      sql.write(c.sql);
      args.addAll(c.args);
    }
    sql.write(')');
    return CompiledSql(sql.toString(), args);
  }

  @override
  bool test(Map<String, Object?> row) => parts.every((p) => p.test(row));
}

class OrCondition extends Condition {
  final List<Condition> parts;
  const OrCondition(this.parts);

  @override
  CompiledSql compile() {
    final live = parts.where((p) => p is! _False).toList();
    if (live.isEmpty) return const CompiledSql('(1 = 0)');
    if (live.any((p) => p is _True)) return const CompiledSql('(1 = 1)');
    if (live.length == 1) return live.first.compile();
    final sql = StringBuffer('(');
    final args = <Object?>[];
    for (var i = 0; i < live.length; i++) {
      if (i > 0) sql.write(' OR ');
      final c = live[i].compile();
      sql.write(c.sql);
      args.addAll(c.args);
    }
    sql.write(')');
    return CompiledSql(sql.toString(), args);
  }

  @override
  bool test(Map<String, Object?> row) => parts.any((p) => p.test(row));
}

class NotCondition extends Condition {
  final Condition inner;
  const NotCondition(this.inner);

  @override
  CompiledSql compile() {
    final c = inner.compile();
    return CompiledSql('(NOT ${c.sql})', c.args);
  }

  @override
  bool test(Map<String, Object?> row) => !inner.test(row);
}

/// Fluent predicate builder passed to `where((w) => ...)`.
///
/// ```dart
/// w.eq('active', true) & (w.lt('age', 13) | w.gt('age', 19))
/// ```
class Where {
  const Where();

  Condition eq(String column, Object? value) => _Simple(column, '=', value);
  Condition ne(String column, Object? value) =>
      _Simple(column, '!=', value);
  Condition gt(String column, Object? value) => _Simple(column, '>', value);
  Condition gte(String column, Object? value) =>
      _Simple(column, '>=', value);
  Condition lt(String column, Object? value) => _Simple(column, '<', value);
  Condition lte(String column, Object? value) =>
      _Simple(column, '<=', value);

  /// Raw `LIKE` with your own `%`/`_` wildcards. Prefer [contains],
  /// [startsWith] or [endsWith] for plain text — they escape wildcards.
  Condition like(String column, String pattern) =>
      _Like(column, pattern);
  Condition notLike(String column, String pattern) =>
      _Like(column, pattern, negated: true);

  /// `name` contains `part` — no `%` wildcards needed.
  /// Special chars (`%`, `_`, `\`) in [part] match literally.
  Condition contains(String column, String part) =>
      _Like(column, '%${escapeLike(part)}%', escaped: true);
  Condition notContains(String column, String part) =>
      _Like(column, '%${escapeLike(part)}%', negated: true, escaped: true);

  /// `name` starts with `prefix` — no `prefix%` needed.
  Condition startsWith(String column, String prefix) =>
      _Like(column, '${escapeLike(prefix)}%', escaped: true);
  Condition notStartsWith(String column, String prefix) =>
      _Like(column, '${escapeLike(prefix)}%', negated: true, escaped: true);

  /// `name` ends with `suffix` — no `%suffix` needed.
  Condition endsWith(String column, String suffix) =>
      _Like(column, '%${escapeLike(suffix)}', escaped: true);
  Condition notEndsWith(String column, String suffix) =>
      _Like(column, '%${escapeLike(suffix)}', negated: true, escaped: true);

  Condition inList(String column, List<Object?> values) =>
      _In(column, values);
  Condition notInList(String column, List<Object?> values) =>
      _In(column, values, negated: true);

  Condition between(String column, Object? low, Object? high) =>
      _Between(column, low, high);
  Condition notBetween(String column, Object? low, Object? high) =>
      _Between(column, low, high, negated: true);

  Condition isNull(String column) => _Null(column);
  Condition isNotNull(String column) => _Null(column, negated: true);

  Condition raw(String fragment, [List<Object?> args = const []]) =>
      RawCondition(fragment, args);
}

/// Typed column reference for expressive filters:
///
/// ```dart
/// col('age').gt(18) & col('name').contains('a')
/// ```
ColumnRef col(String name) => ColumnRef(name);

class ColumnRef {
  final String name;
  const ColumnRef(this.name);

  Condition eq(Object? v) => _Simple(name, '=', v);
  Condition ne(Object? v) => _Simple(name, '!=', v);
  Condition gt(Object? v) => _Simple(name, '>', v);
  Condition gte(Object? v) => _Simple(name, '>=', v);
  Condition lt(Object? v) => _Simple(name, '<', v);
  Condition lte(Object? v) => _Simple(name, '<=', v);

  /// Raw `LIKE` with your own `%`/`_` wildcards. Prefer [contains],
  /// [startsWith] or [endsWith] for plain text.
  Condition like(String p) => _Like(name, p);
  Condition notLike(String p) => _Like(name, p, negated: true);

  /// Contains `part` — no `%` wildcards needed. `%`, `_`, `\` match literally.
  Condition contains(String p) =>
      _Like(name, '%${escapeLike(p)}%', escaped: true);
  Condition notContains(String p) =>
      _Like(name, '%${escapeLike(p)}%', negated: true, escaped: true);
  Condition startsWith(String p) =>
      _Like(name, '${escapeLike(p)}%', escaped: true);
  Condition notStartsWith(String p) =>
      _Like(name, '${escapeLike(p)}%', negated: true, escaped: true);
  Condition endsWith(String p) =>
      _Like(name, '%${escapeLike(p)}', escaped: true);
  Condition notEndsWith(String p) =>
      _Like(name, '%${escapeLike(p)}', negated: true, escaped: true);
  Condition inList(List<Object?> v) => _In(name, v);
  Condition notInList(List<Object?> v) => _In(name, v, negated: true);
  Condition between(Object? lo, Object? hi) => _Between(name, lo, hi);
  Condition isNull() => _Null(name);
  Condition isNotNull() => _Null(name, negated: true);
}
