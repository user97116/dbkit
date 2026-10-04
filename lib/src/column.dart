import 'sql.dart';

/// SQLite column types.
enum SqlType {
  integer,
  text,
  real,
  blob,
  boolean,
  datetime,
}

/// Definition of a single column used by the schema builder.
class ColumnDef {
  final String name;
  final SqlType type;
  bool isNullable = true;
  bool primaryKey = false;
  bool autoIncrement = false;
  bool unique = false;
  Object? defaultValue;
  String? defaultRaw; // e.g. CURRENT_TIMESTAMP
  String? references; // e.g. '"users"("id") ON DELETE CASCADE'
  String? check;

  ColumnDef(this.name, this.type);

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

  ColumnDef primary() {
    primaryKey = true;
    isNullable = false;
    return this;
  }

  ColumnDef autoInc() {
    autoIncrement = true;
    primaryKey = true;
    isNullable = false;
    return this;
  }

  ColumnDef isUnique() {
    unique = true;
    return this;
  }

  ColumnDef defaultsTo(Object? v) {
    defaultValue = v;
    return this;
  }

  ColumnDef defaultsToNow() {
    defaultRaw = 'CURRENT_TIMESTAMP';
    return this;
  }

  ColumnDef defaultsToRaw(String expr) {
    defaultRaw = expr;
    return this;
  }

  ColumnDef referencesTable(String table, String column,
      {String? onDelete, String? onUpdate}) {
    var ref = '${quoteIdent(table)}(${quoteIdent(column)})';
    if (onDelete != null) ref += ' ON DELETE $onDelete';
    if (onUpdate != null) ref += ' ON UPDATE $onUpdate';
    references = ref;
    return this;
  }

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
  final String table;
  final List<ColumnDef> columns = [];
  final List<String> _tableConstraints = [];

  TableBlueprint(this.table);

  ColumnDef _add(String name, SqlType type) {
    final c = ColumnDef(name, type);
    columns.add(c);
    return c;
  }

  /// `id INTEGER PRIMARY KEY AUTOINCREMENT`
  ColumnDef id([String name = 'id']) => _add(name, SqlType.integer)..autoInc();

  ColumnDef integer(String name) => _add(name, SqlType.integer);
  ColumnDef text(String name) => _add(name, SqlType.text);
  ColumnDef real(String name) => _add(name, SqlType.real);
  ColumnDef blob(String name) => _add(name, SqlType.blob);
  ColumnDef boolean(String name) => _add(name, SqlType.boolean);
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
    final c = integer(column)
        .referencesTable(refTable, refColumn,
            onDelete: onDelete, onUpdate: onUpdate);
    if (!nullable) c.notNull();
    return c;
  }

  void unique(List<String> cols) {
    _tableConstraints.add(
        'UNIQUE (${cols.map(quoteIdent).join(', ')})');
  }

  void index(List<String> cols, {String? name, bool unique = false}) {
    // Stored separately — compiled by [Db] into CREATE INDEX statements.
    _pendingIndexes.add(PendingIndex(
        name: name ?? 'idx_${table}_${cols.join('_')}',
        columns: cols,
        unique: unique));
  }

  void primary(List<String> cols) {
    _tableConstraints.add('PRIMARY KEY (${cols.map(quoteIdent).join(', ')})');
  }

  void foreign(List<String> cols, String refTable, List<String> refCols,
      {String? onDelete, String? onUpdate}) {
    var s =
        'FOREIGN KEY (${cols.map(quoteIdent).join(', ')}) REFERENCES ${quoteIdent(refTable)} (${refCols.map(quoteIdent).join(', ')})';
    if (onDelete != null) s += ' ON DELETE $onDelete';
    if (onUpdate != null) s += ' ON UPDATE $onUpdate';
    _tableConstraints.add(s);
  }

  void check(String expr) => _tableConstraints.add('CHECK ($expr)');

  final List<PendingIndex> _pendingIndexes = [];
  List<PendingIndex> get pendingIndexes => _pendingIndexes;
  List<String> get tableConstraints => _tableConstraints;

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

class PendingIndex {
  final String name;
  final List<String> columns;
  final bool unique;
  const PendingIndex(
      {required this.name, required this.columns, required this.unique});

  CompiledSql compile(String table) {
    final u = unique ? 'UNIQUE ' : '';
    return CompiledSql(
        'CREATE ${u}INDEX IF NOT EXISTS ${quoteIdent(name)} ON ${quoteIdent(table)} (${columns.map(quoteIdent).join(', ')})');
  }
}
