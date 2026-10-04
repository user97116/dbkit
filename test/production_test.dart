import 'package:test/test.dart';
import 'package:dbkit/dbkit.dart';

/// Production guarantees: pragmas, nested transactions, atomic increments,
/// fail-fast validation, efficient counts, JSON values.
void main() {
  group('sqlite production defaults', () {
    late Db db;

    setUp(() async {
      db = Db.memory();
      await db.createTable('users', (t) {
        t.id();
        t.text('name').notNull();
        t.integer('age').nullable();
      });
      await db.createTable('posts', (t) {
        t.id();
        t.foreignId('user_id', 'users');
        t.text('title').notNull();
      });
    });

    tearDown(() async {
      await db.close();
    });

    test('foreign keys are enforced', () async {
      final pragma = await db.raw('PRAGMA foreign_keys');
      expect(pragma.single['foreign_keys'], 1);
      // Orphan FK must fail instead of silently succeeding.
      await expectLater(
        db.table('posts').insert({'user_id': 999, 'title': 'orphan'}),
        throwsA(isA<DbException>()),
      );
    });

    test('nested transaction rolls back inner only', () async {
      await db.transaction((outer) async {
        await outer.table('users').insert({'name': 'Outer'});
        try {
          await outer.transaction((inner) async {
            await inner.table('users').insert({'name': 'Inner'});
            throw Exception('inner boom');
          });
        } catch (_) {
          // inner rollback swallowed; outer continues
        }
      });
      final names = await db.table('users').pluck<String>('name');
      expect(names, ['Outer']);
    });

    test('close is idempotent', () async {
      await db.close();
      await db.close();
    });

    test('increment is atomic and returns affected rows', () async {
      final users = db.table('users');
      final id = await users.insert({'name': 'Ada', 'age': 36});
      await users.insert({'name': 'Bob', 'age': 10});
      final n =
          await users.increment('age', by: 2, where: (w) => w.eq('id', id));
      expect(n, 1);
      expect((await users.findById(id))!['age'], 38);
      expect(
          (await users.findOneWhere((w) => w.eq('name', 'Bob')))!['age'], 10);
    });

    test('filtered count is correct without fetching rows', () async {
      final users = db.table('users');
      await users.insertMany([
        {'name': 'a', 'age': 20},
        {'name': 'b', 'age': 15},
        {'name': 'c', 'age': 30},
      ]);
      expect(await users.where((w) => w.gte('age', 18)).count(), 2);
    });

    test('maps and lists are stored as JSON', () async {
      expect(toSqlValue({'a': 1}), '{"a":1}');
      expect(toSqlValue([1, 2]), '[1,2]');
      await db.createTable('prefs', (t) {
        t.id();
        t.text('value').nullable();
      });
      final id = await db.table('prefs').insert({
        'value': toSqlValue({'theme': 'dark'})
      });
      expect(
          (await db.table('prefs').findById(id))!['value'], '{"theme":"dark"}');
    });

    test('compileIncrement generates a single UPDATE', () {
      final c = compileIncrement('users', 'age', 2, const Where().eq('id', 1));
      expect(c.sql, 'UPDATE "users" SET "age" = "age" + ? WHERE "id" = ?');
      expect(c.args, [2, 1]);
    });
  });

  group('fail-fast validation', () {
    test('empty rows and values throw ArgumentError', () async {
      final db = Db.fake();
      expect(() => db.table('users').insert({}), throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').upsert({}), throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').updateById(1, {}),
          throwsA(isA<ArgumentError>()));
      expect(() => compileInsert('users', {}), throwsA(isA<ArgumentError>()));
      expect(() => compileUpdate('users', {}, null),
          throwsA(isA<ArgumentError>()));
    });

    test('bad paging and names throw ArgumentError', () {
      final db = Db.fake();
      expect(() => db.table(''), throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').query().limit(-1),
          throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').query().offset(-1),
          throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').query().page(0, 10),
          throwsA(isA<ArgumentError>()));
      expect(() => db.table('users').query().page(1, 0),
          throwsA(isA<ArgumentError>()));
      expect(() => quoteIdent(''), throwsA(isA<ArgumentError>()));
    });
  });
}
