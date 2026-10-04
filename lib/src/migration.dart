/// A versioned schema change, run by [Db.migrate] in version order.
class Migration {
  /// Unique schema version, applied once and recorded in `_migrations`.
  final int version;

  /// Short human-readable description of the change.
  final String description;

  /// Applies the change using [Migrator].
  final Future<void> Function(Migrator m) run;

  /// Creates a migration for [version] with [description], applied by [run].
  const Migration(
      {required this.version, required this.description, required this.run});
}

/// Passed to [Migration.run]. Thin helper over raw DDL execution.
class Migrator {
  /// Executes raw DDL [sql] with [args].
  final Future<void> Function(String sql, [List<Object?> args]) execute;

  /// Creates a migrator over [execute].
  const Migrator(this.execute);

  /// Runs one DDL statement [ddl] with [args].
  Future<void> sql(String ddl, [List<Object?> args = const []]) =>
      execute(ddl, args);
}
