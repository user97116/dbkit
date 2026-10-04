import 'adapter.dart';
import 'adapters/memory_adapter.dart';
import 'adapters/sqlite3_adapter.dart';
import 'column.dart';
import 'migration.dart';
import 'relation.dart';
import 'sql.dart';
import 'table.dart';

/// The database facade. Entry point for everything.
///
/// ```dart
/// final db = Db.memory(); // or Db.open('app.db')
/// db.createTable('users', (t) {
///   t.id();
///   t.text('name').notNull();
///   t.integer('age').nullable();
/// });
///
/// final users = db.table('users');
/// await users.insert({'name': 'Ada', 'age': 36});
/// final adults = await users.where((w) => w.gte('age', 18)).get();
/// ```
class Db {
  final DbAdapter _adapter;
  final RelationRegistry _relations = RelationRegistry();
  bool logSql = false;
  void Function(String message)? logger = print;

  Db._(this._adapter);

  /// Ephemeral DB backed by `sqlite3` in-memory (real SQL engine).
  factory Db.memory({bool logSql = false}) {
    final db = Db._(Sqlite3Adapter.memory());
    db.logSql = logSql;
    return db;
  }

  /// File-backed DB via `sqlite3`.
  ///
  /// Production defaults are applied: enforced foreign keys,
  /// a 5s busy timeout, and WAL mode with `NORMAL` synchronous writes.
  factory Db.open(String path, {bool logSql = false}) {
    final db = Db._(Sqlite3Adapter.open(path));
    db.logSql = logSql;
    return db;
  }

  /// Pure-Dart fake with no native dependencies (tests / prototyping).
  factory Db.fake({bool logSql = false}) {
    final db = Db._(MemoryAdapter());
    db.logSql = logSql;
    return db;
  }

  /// Wraps a custom adapter (e.g. sqflite bridge).
  factory Db.custom(DbAdapter adapter, {bool logSql = false}) {
    final db = Db._(adapter);
    db.logSql = logSql;
    return db;
  }

  DbAdapter get adapter => _adapter;

  bool _isLog() => logSql;

  void _log(CompiledSql c) {
    if (logSql) logger?.call(debugSql(c));
  }

  // -- schema -------------------------------------------------------------------

  /// Creates a table with a fluent blueprint. No SQL needed.
  ///
  /// ```dart
  /// await db.createTable('posts', (t) {
  ///   t.id();
  ///   t.foreignId('user_id', 'users');
  ///   t.text('title').notNull();
  ///   t.boolean('published').defaultsTo(false);
  ///   t.timestamps();
  /// });
  /// ```
  Future<void> createTable(String name,
      void Function(TableBlueprint t) build) async {
    _requireTableName(name);
    final t = TableBlueprint(name);
    build(t);
    final c = t.compileCreateTable();
    _log(c);
    await _adapter.execute(c.sql, c.args);
    for (final idx in t.pendingIndexes) {
      final ic = idx.compile(name);
      _log(ic);
      await _adapter.execute(ic.sql, ic.args);
    }
  }

  Future<void> dropTable(String name, {bool ifExists = true}) async {
    await _adapter.execute(
        'DROP TABLE ${ifExists ? 'IF EXISTS ' : ''}${quoteIdent(name)}');
  }

  Future<void> createIndex(String name, String table, List<String> columns,
      {bool unique = false}) async {
    final u = unique ? 'UNIQUE ' : '';
    await _adapter.execute(
        'CREATE ${u}INDEX IF NOT EXISTS ${quoteIdent(name)} ON ${quoteIdent(table)} (${columns.map(quoteIdent).join(', ')})');
  }

  Future<void> dropIndex(String name) async {
    await _adapter.execute('DROP INDEX IF EXISTS ${quoteIdent(name)}');
  }

  /// Runs versioned [migrations] in order, tracking state in `_migrations`.
  Future<void> migrate(List<Migration> migrations) async {
    await _adapter.execute(
        'CREATE TABLE IF NOT EXISTS "_migrations" ("version" INTEGER PRIMARY KEY, "applied_at" TEXT DEFAULT CURRENT_TIMESTAMP)');
    final applied =
        await _adapter.rawSelect('SELECT "version" FROM "_migrations"');
    final done = applied.map((r) => (r['version'] as num).toInt()).toSet();
    final sorted = List.of(migrations)
      ..sort((a, b) => a.version.compareTo(b.version));
    for (final m in sorted) {
      if (done.contains(m.version)) continue;
      await _adapter.transaction((tx) async {
        final migrator = Migrator((sql, [args = const []]) async {
          await tx.execute(sql, args);
        });
        await m.run(migrator);
        // record version (works on both adapters)
        try {
          await tx.execute(
              'INSERT INTO "_migrations" ("version") VALUES (?)', [m.version]);
        } catch (_) {
          await tx.insert('_migrations', {'version': m.version});
        }
      });
    }
  }

  // -- tables & relations ---------------------------------------------------------

  /// Handle to [name] with the full fluent API (`selectAll`, `findById`, ...).
  TableRef table(String name) {
    _requireTableName(name);
    return TableRef(_adapter, name, _relations,
        logSql: _isLog, logger: logger);
  }

  static void _requireTableName(String name) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'table name must not be empty');
    }
  }

  /// Declares a named relationship used by `withMany` / `withOne` / `withRelations`.
  void defineRelation(Relation r) => _relations.add(r);

  void defineRelations(Iterable<Relation> rs) {
    for (final r in rs) {
      _relations.add(r);
    }
  }

  /// Direct chainable select without going through [table()] first.
  TableQuery from(String table) => this.table(table).query();

  // -- transactions / batch ----------------------------------------------------------

  /// Runs [action] inside a transaction (rollback on error).
  ///
  /// ```dart
  /// await db.transaction((tx) async {
  ///   await tx.table('users').insert({'name': 'Ada'});
  ///   await tx.table('posts').insert({'title': 'Hi', 'user_id': 1});
  /// });
  /// ```
  Future<T> transaction<T>(Future<T> Function(Db tx) action) async {
    return _adapter.transaction((a) async {
      final tx = Db._(a)
        ..logSql = logSql
        ..logger = logger;
      for (final r in _relations.all) {
        tx._relations.add(r);
      }
      return action(tx);
    });
  }

  /// Runs raw SQL (escape hatch). Prefer fluent APIs where possible.
  Future<List<Map<String, Object?>>> raw(String sql,
          [List<Object?> args = const []]) =>
      _adapter.rawSelect(sql, args);

  /// Executes a raw statement (DDL / pragma / raw write).
  Future<void> exec(String sql, [List<Object?> args = const []]) =>
      _adapter.execute(sql, args);

  Future<void> close() => _adapter.close();
}
