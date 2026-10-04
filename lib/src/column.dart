import 'sql.dart';

/// SQLite column types.
enum SqlType {
  /// 32/64-bit integers (`INTEGER`).
  integer,

  /// UTF-8 text (`TEXT`).
  text,

  /// Floating-point numbers (`REAL`).
  real,

  /// Raw bytes (`BLOB`).
  blob,

  /// Booleans, stored as `0`/`1` (`INTEGER`).
  boolean,

  /// Timestamps, stored as ISO-8601 text (`TEXT`).
  datetime,
}

/// Definition of a single column used by the schema builder.
class ColumnDef {
  /// Database column name.
  final String name;

  /// Declared column type.
  final SqlType type;

  /// Whether `NULL` is allowed (default true).
  bool isNullable = true;

  /// Whether this column is (part of) the primary key.
  bool primaryKey = false;

  /// Whether this is an autoincrementing integer primary key.
  bool autoIncrement = false;

  /// Whether values must be unique.
  bool unique = false;

  /// Dart-level default written into `DEFAULT`, if any.
  Object? defaultValue;

  /// Raw SQL default expression (e.g. `CURRENT_TIMESTAMP`), if any.
  String? defaultRaw; // e.g. CURRENT_TIMESTAMP

  /// `REFERENCES` clause (e.g. `'"users"("id") ON DELETE CASCADE'`), if any.
  String? references; // e.g. '"users"("id") ON DELETE CASCADE'

  /// `CHECK` expression, if any.
  String? check;

  /// Creates a column definition for [name] of [type].
  ColumnDef(this.name, this.type);

  /// Marks the column `NOT NULL`.
  ColumnDef notNull() {
    isNullable = false;
    return this;
  }

  /// Marks the column nullable (the default). Reads better in blueprints:
  /// `t.integer('age').nullable()`.
  ColumnDef nullable() {
    isNullable = true;
    return this;
  }

  /// Marks the column as (part of) the primary key.
  ColumnDef primary() {
    primaryKey = true;
    isNullable = false;
    return this;
  }

  /// Marks an integer primary key as autoincrementing.
  ColumnDef autoInc() {
    autoIncrement = true;
    primaryKey = true;
    isNullable = false;
    return this;
  }

  /// Adds a `UNIQUE` constraint.
  ColumnDef isUnique() {
    unique = true;
    return this;
  }

  /// Sets a Dart-level `DEFAULT` value [v].
  ColumnDef defaultsTo(Object? v) {
    defaultValue = v;
    return this;
  }

  /// Sets `DEFAULT CURRENT_TIMESTAMP` (datetime columns).
  ColumnDef defaultsToNow() {
    defaultRaw = 'CURRENT_TIMESTAMP';
    return this;
  }

  /// Sets a raw SQL `DEFAULT` expression [expr].
  ColumnDef defaultsToRaw(String expr) {
    defaultRaw = expr;
    return this;
  }

  /// Adds `REFERENCES "table"("column")` with optional actions.
  ColumnDef referencesTable(String table, String column,
      {String? onDelete, String? onUpdate}) {
    var ref = '${quoteIdent(table)}(${quoteIdent(column)})';
    if (onDelete != null) ref += ' ON DELETE $onDelete';
    if (onUpdate != null) ref += ' ON UPDATE $onUpdate';
    references = ref;
    return this;
  }

  /// The SQLite storage type for [type].
  String get sqlType {
    switch (type) {
      case SqlType.integer:
      case SqlType.boolean:
        // AUTOINCREMENT requires exactly "INTEGER PRIMARY KEY AUTOINCREMENT"
        return 'INTEGER';
      case SqlType.text:
      case SqlType.datetime:
        return 'TEXT';
      case SqlType.real:
        return 'REAL';
      case SqlType.blob:
        return 'BLOB';
    }
  }

  /// Compiles the column definition fragment for `CREATE TABLE`.
  String compile() {
    final sb = StringBuffer('${quoteIdent(name)} $sqlType');
    if (primaryKey && autoIncrement) {
      sb.write(' PRIMARY KEY AUTOINCREMENT');
    } else {
      if (primaryKey) sb.write(' PRIMARY KEY');
      if (!isNullable && !primaryKey) sb.write(' NOT NULL');
      if (unique) sb.write(' UNIQUE');
      if (defaultRaw != null) {
        sb.write(' DEFAULT $defaultRaw');
      } else if (defaultValue != null) {
        sb.write(' DEFAULT ${_literal(defaultValue)}');
      }
      if (references != null) sb.write(' REFERENCES $references');
      if (check != null) sb.write(' CHECK ($check)');
    }
    return sb.toString();
  }

  static String _literal(Object? v) {
    if (v == null) return 'NULL';
    if (v is num) return '$v';
    if (v is bool) return v ? '1' : '0';
    return "'${v.toString().replaceAll("'", "''")}'";
  }
}

/// Fluent table blueprint used in `db.createTable(name, (t) {...})`.
class TableBlueprint {
  /// Table being defined.
  final String table;

  /// Columns added so far, in declaration order.
  final List<ColumnDef> columns = [];
  final List<String> _tableConstraints = [];

  /// Creates a blueprint for [table].
  TableBlueprint(this.table);

  ColumnDef _add(String name, SqlType type) {
    final c = ColumnDef(name, type);
    columns.add(c);
    return c;
  }

  /// `id INTEGER PRIMARY KEY AUTOINCREMENT`.
  ColumnDef id([String name = 'id']) => _add(name, SqlType.integer)..autoInc();

  /// An `INTEGER` column [name].
  ColumnDef integer(String name) => _add(name, SqlType.integer);

  /// A `TEXT` column [name].
  ColumnDef text(String name) => _add(name, SqlType.text);

  /// A `REAL` column [name].
  ColumnDef real(String name) => _add(name, SqlType.real);

  /// A `BLOB` column [name].
  ColumnDef blob(String name) => _add(name, SqlType.blob);

  /// A boolean column [name] (stored as `0`/`1`).
  ColumnDef boolean(String name) => _add(name, SqlType.boolean);

  /// A datetime column [name] (stored as ISO-8601 text).
  ColumnDef datetime(String name) => _add(name, SqlType.datetime);

  /// Timestamps `created_at` / `updated_at` defaulting to now.
  void timestamps(
      {String createdAt = 'created_at', String updatedAt = 'updated_at'}) {
    datetime(createdAt).defaultsToNow().notNull();
    datetime(updatedAt).defaultsToNow().notNull();
  }

  /// Shorthand foreign key: `users_id INTEGER REFERENCES "users"("id") ...`
  ColumnDef foreignId(String column, String refTable,
      {String refColumn = 'id',
      String onDelete = 'CASCADE',
      String onUpdate = 'CASCADE',
      bool nullable = false}) {
    final c = integer(column).referencesTable(refTable, refColumn,
        onDelete: onDelete, onUpdate: onUpdate);
    if (!nullable) c.notNull();
    return c;
  }

  /// Adds a table-level `UNIQUE (cols)` constraint.
  void unique(List<String> cols) {
    _tableConstraints.add('UNIQUE (${cols.map(quoteIdent).join(', ')})');
  }

  /// Queues a `CREATE INDEX` over [cols] (emitted by [Db.createTable]).
  void index(List<String> cols, {String? name, bool unique = false}) {
    // Stored separately — compiled by [Db] into CREATE INDEX statements.
    _pendingIndexes.add(PendingIndex(
        name: name ?? 'idx_${table}_${cols.join('_')}',
        columns: cols,
        unique: unique));
  }

  /// Adds a table-level `PRIMARY KEY (cols)` constraint.
  void primary(List<String> cols) {
    _tableConstraints.add('PRIMARY KEY (${cols.map(quoteIdent).join(', ')})');
  }

  /// Adds a table-level `FOREIGN KEY` constraint towards [refTable].
  void foreign(List<String> cols, String refTable, List<String> refCols,
      {String? onDelete, String? onUpdate}) {
    var s =
        'FOREIGN KEY (${cols.map(quoteIdent).join(', ')}) REFERENCES ${quoteIdent(refTable)} (${refCols.map(quoteIdent).join(', ')})';
    if (onDelete != null) s += ' ON DELETE $onDelete';
    if (onUpdate != null) s += ' ON UPDATE $onUpdate';
    _tableConstraints.add(s);
  }

  /// Adds a table-level `CHECK (expr)` constraint.
  void check(String expr) => _tableConstraints.add('CHECK ($expr)');

  final List<PendingIndex> _pendingIndexes = [];

  /// Indexes queued via [index], compiled after `CREATE TABLE`.
  List<PendingIndex> get pendingIndexes => _pendingIndexes;

  /// Table-level constraint fragments.
  List<String> get tableConstraints => _tableConstraints;

  /// Compiles the full `CREATE TABLE` statement.
  CompiledSql compileCreateTable({bool ifNotExists = true}) {
    final defs = [
      ...columns.map((c) => c.compile()),
      ..._tableConstraints,
    ];
    final sql =
        'CREATE TABLE ${ifNotExists ? 'IF NOT EXISTS ' : ''}${quoteIdent(table)} (\n  ${defs.join(',\n  ')}\n)';
    return CompiledSql(sql);
  }
}

/// An index queued by [TableBlueprint.index].
class PendingIndex {
  /// Index name.
  final String name;

  /// Indexed columns.
  final List<String> columns;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// Creates a pending index over [columns] named [name].
  const PendingIndex(
      {required this.name, required this.columns, required this.unique});

  /// Compiles the `CREATE INDEX` statement against [table].
  CompiledSql compile(String table) {
    final u = unique ? 'UNIQUE ' : '';
    return CompiledSql(
        'CREATE ${u}INDEX IF NOT EXISTS ${quoteIdent(name)} ON ${quoteIdent(table)} (${columns.map(quoteIdent).join(', ')})');
  }
}
