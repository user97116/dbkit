/// dbkit — super-abstraction SQLite toolkit for Dart & Flutter.
///
/// No raw SQL needed for 95% of work:
///
/// ```dart
/// import 'package:dbkit/dbkit.dart';
///
/// final db = Db.memory();
/// await db.createTable('users', (t) {
///   t.id();
///   t.text('name').notNull();
///   t.integer('age').nullable();
/// });
///
/// final users = db.table('users');
/// await users.insert({'name': 'Ada', 'age': 36});
/// final adults = await users.where((w) => w.gte('age', 18))
///   .orderBy('name')
///   .limit(10)
///   .get();
/// ```
library;

export 'src/adapter.dart';
export 'src/annotations.dart';
export 'src/column.dart';
export 'src/database.dart';
export 'src/errors.dart';
export 'src/filter.dart';
export 'src/migration.dart';
export 'src/query.dart';
export 'src/relation.dart';
export 'src/sql.dart';
export 'src/table.dart';
export 'src/adapters/memory_adapter.dart';
export 'src/adapters/sqlite3_adapter.dart';
