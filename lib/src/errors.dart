/// Thrown for all dbkit failures (constraint violations, missing tables, ...).
class DbException implements Exception {
  /// Human-readable failure description.
  final String message;

  /// The underlying error, if any.
  final Object? cause;

  /// The SQL that failed, if any.
  final String? sql;

  /// Creates an exception with [message], optional [cause] and [sql].
  const DbException(this.message, {this.cause, this.sql});

  @override
  String toString() =>
      'DbException: $message${sql != null ? '\nSQL: $sql' : ''}${cause != null ? '\nCaused by: $cause' : ''}';
}
