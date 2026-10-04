/// A versioned schema change.
class Migration {
  final int version;
  final String description;
  final Future<void> Function(Migrator m) run;

  const Migration(
      {required this.version,
      required this.description,
      required this.run});
}

/// Passed to [Migration.run]. Thin helper over raw DDL execution.
class Migrator {
  final Future<void> Function(String sql, [List<Object?> args]) execute;
  const Migrator(this.execute);

  Future<void> sql(String ddl, [List<Object?> args = const []]) =>
      execute(ddl, args);
}
