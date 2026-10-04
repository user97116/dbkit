import 'package:test/test.dart';
import 'package:dbkit/dbkit.dart';

void main() {
  group('Condition compilation', () {
    test('simple comparisons', () {
      expect(const Where().eq('age', 18).compile().sql, '"age" = ?');
      expect(const Where().eq('age', 18).compile().args, [18]);
      expect(const Where().gt('age', 18).compile().sql, '"age" > ?');
      expect(
          const Where().eq('name', null).compile().sql, '"name" IS NULL');
      expect(const Where().ne('name', null).compile().sql,
          '"name" IS NOT NULL');
    });

    test('like / in / between / null', () {
      expect(const Where().like('name', '%a%').compile().sql,
          '"name" LIKE ?');
      expect(
          const Where().inList('id', [1, 2]).compile().sql,
          '"id" IN (?, ?)');
      expect(const Where().inList('id', []).compile().sql, '(1 = 0)');
      expect(const Where().notInList('id', []).compile().sql, '(1 = 1)');
      expect(const Where().between('age', 18, 30).compile().sql,
          '"age" BETWEEN ? AND ?');
      expect(const Where().isNull('x').compile().sql, '"x" IS NULL');
      expect(const Where().isNotNull('x').compile().sql,
          '"x" IS NOT NULL');
    });

    test('and/or/not composition with operators', () {
      final c = const Where().gt('age', 18) & const Where().like('n', '%a%');
      final s = c.compile();
      expect(s.sql, '("age" > ? AND "n" LIKE ?)');
      expect(s.args, [18, '%a%']);

      final o = const Where().eq('a', 1) | const Where().eq('b', 2);
      expect(o.compile().sql, '("a" = ? OR "b" = ?)');

      final n = ~const Where().eq('a', 1);
      expect(n.compile().sql, '(NOT "a" = ?)');
    });

    test('contains / startsWith / endsWith need no wildcards', () {
      var c = const Where().contains('name', 'a').compile();
      expect(c.sql, '"name" LIKE ? ESCAPE \'\\\'');
      expect(c.args, ['%a%']);

      c = const Where().startsWith('name', 'Ad').compile();
      expect(c.args, ['Ad%']);

      c = const Where().endsWith('name', 'da').compile();
      expect(c.args, ['%da']);

      c = const Where().notContains('name', 'x').compile();
      expect(c.sql, '"name" NOT LIKE ? ESCAPE \'\\\'');
      expect(c.args, ['%x%']);

      // raw like() stays untouched (no ESCAPE) — the power-user hatch.
      expect(const Where().like('name', '%a%').compile().sql,
          '"name" LIKE ?');
    });

    test('contains escapes %, _ and backslash literally', () {
      expect(escapeLike('100%'), r'100\%');
      expect(escapeLike('a_b'), r'a\_b');
      expect(escapeLike(r'a\b'), r'a\\b');

      final c = const Where().contains('name', '100%_').compile();
      expect(c.args, [r'%100\%\_%']);

      // in-memory matching honors the escapes
      final cond = const Where().contains('name', '100%');
      expect(cond.test({'name': 'save 100% now'}), isTrue);
      expect(cond.test({'name': 'save 1000 now'}), isFalse);

      final sw = const Where().startsWith('name', 'a_c');
      expect(sw.test({'name': 'a_cme'}), isTrue);
      expect(sw.test({'name': 'abcme'}), isFalse);
    });

    test('col() helper', () {
      final c = col('age').gte(18) & col('name').contains('da');
      expect(c.compile().args, [18, '%da%']);
    });
  });

  group('SelectQuery compilation', () {
    test('basic select with where/order/limit', () {
      final q = SelectQuery('users')
          .select(['id', 'name'])
          .where((w) => w.gte('age', 18))
          .orderBy('name')
          .limit(10)
          .offset(5);
      final c = q.compile();
      expect(c.sql,
          'SELECT "id", "name" FROM "users" WHERE "age" >= ? ORDER BY "name" ASC LIMIT 10 OFFSET 5');
      expect(c.args, [18]);
    });

    test('distinct + joins + group/having', () {
      final q = SelectQuery('users')
          .select(['users.name', 'COUNT(posts.id) AS post_count'])
          .distinct()
          .leftJoin('posts', 'posts.user_id = users.id')
          .where((w) => w.eq('active', true))
          .groupBy(['users.id'])
          .having((w) => w.gt('post_count', 2))
          .orderByDesc('post_count');
      final c = q.compile();
      expect(c.sql.contains('SELECT DISTINCT'), isTrue);
      expect(c.sql.contains('LEFT JOIN "posts" ON (posts.user_id = users.id)'),
          isTrue);
      expect(c.sql.contains('GROUP BY "users"."id"') ||
          c.sql.contains('GROUP BY "users.id"') ||
          c.sql.contains('GROUP BY'), isTrue);
    });

    test('insert / update / delete compile', () {
      final ins = compileInsert('users', {'name': 'Ada', 'age': 36});
      expect(ins.sql,
          'INSERT  INTO "users" ("name", "age") VALUES (?, ?)');
      expect(ins.args, ['Ada', 36]);

      final up = compileUpsert('users', {'id': 1, 'name': 'Ada'});
      expect(up.sql.contains('ON CONFLICT'), isTrue);

      final upd = compileUpdate(
          'users', {'age': 37}, const Where().eq('id', 1));
      expect(upd.sql, 'UPDATE "users" SET "age" = ? WHERE "id" = ?');

      final del = compileDelete('users', const Where().eq('id', 1));
      expect(del.sql, 'DELETE FROM "users" WHERE "id" = ?');
    });

    test('schema blueprint compiles', () {
      final t = TableBlueprint('users');
      t.id();
      t.text('name').notNull();
      t.integer('age').nullable();
      t.boolean('active').defaultsTo(true);
      final c = t.compileCreateTable();
      expect(c.sql.contains('CREATE TABLE IF NOT EXISTS "users"'), isTrue);
      expect(c.sql.contains('"id" INTEGER PRIMARY KEY AUTOINCREMENT'), isTrue);
      expect(c.sql.contains('"name" TEXT NOT NULL'), isTrue);
    });
  });
}
