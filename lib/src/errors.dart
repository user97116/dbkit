/// Thrown for all dbkit failures (constraint violations, missing tables, ...).
class DbException implements Exception {
  final String message;
  final Object? cause;
  final String? sql;

  const DbException(this.message, {this.cause, this.sql});

  @override
  String toString() =>
      'DbException: $message${sql != null ? '\nSQL: $sql' : ''}${cause != null ? '\nCaused by: $cause' : ''}';
}
