import 'package:test/test.dart';
import 'package:dbkit/dbkit.dart';

/// Same smoke suite as the fake, but against real SQLite (sqlite3).
/// Skipped automatically if native sqlite is unavailable.
void main() {
  Db make() => Db.memory();

  test('schema builder + CRUD + joins + transactions (sqlite3)', () async {
    final db = make();

    await db.createTable('users', (t) {
      t.id();
      t.text('name').notNull();
      t.integer('age').nullable();
      t.boolean('active').defaultsTo(true);
      t.index(['age']);
    });
    await db.createTable('posts', (t) {
      t.id();
      t.foreignId('user_id', 'users');
      t.text('title').notNull();
      t.boolean('published').defaultsTo(false);
    });

    final users = db.table('users');
    final posts = db.table('posts');

    final adaId = await users.insert({'name': 'Ada', 'age': 36});
    expect(adaId, isNonZero);
    await users.insertMany([
      {'name': 'Bob', 'age': 15},
      {'name': 'Cid', 'age': 22},
    ]);
    expect(await users.count(), 3);

    await posts.insertMany([
      {'user_id': adaId, 'title': 'Hello', 'published': true},
      {'user_id': adaId, 'title': 'Draft', 'published': false},
    ]);

    // where + order + limit (no SQL written by caller)
    final adults = await users
        .where((w) => w.gte('age', 18))
        .orderBy('age')
        .limit(10)
        .get();
    expect(adults.length, 2);

    // join + groupBy + count
    final rows = await users
        .query()
        .select(['users.name', 'COUNT(posts.id) AS post_count'])
        .leftJoin('posts', 'posts.user_id = users.id')
        .groupBy(['users.id'])
        .orderBy('name')
        .get();
    expect(rows.length, 3);
    final adaRow = rows.firstWhere((r) => r['name'] == 'Ada');
    expect(adaRow['post_count'], 2);

    // upsert
    await users.upsert({'id': adaId, 'name': 'Ada', 'age': 37});
    expect((await users.findById(adaId))!['age'], 37);

    // transaction commit
    await db.transaction((tx) async {
      await tx.table('users').insert({'name': 'Tx', 'age': 20});
    });
    expect(await users.count(), 4);

    // transaction rollback
    await expectLater(db.transaction((tx) async {
      await tx.table('users').insert({'name': 'Nope', 'age': 1});
      throw Exception('boom');
    }), throwsException);
    expect(await users.count(), 4);

    // migrations
    await db.migrate([
      Migration(
          version: 1,
          description: 'add bio',
          run: (m) async {
            await m.sql('ALTER TABLE "users" ADD COLUMN "bio" TEXT');
          }),
    ]);
    await users.updateById(adaId, {'bio': 'pioneer'});
    expect((await users.findById(adaId))!['bio'], 'pioneer');

    await db.close();
  });

  test('relations eager load on sqlite3', () async {
    final db = make();
    await db.createTable('users', (t) {
      t.id();
      t.text('name').notNull();
    });
    await db.createTable('posts', (t) {
      t.id();
      t.foreignId('user_id', 'users');
      t.text('title').notNull();
    });
    db.defineRelation(Relation.hasMany(
      name: 'posts',
      fromTable: 'users',
      fromKey: 'id',
      toTable: 'posts',
      toKey: 'user_id',
    ));
    db.defineRelation(Relation.belongsTo(
      name: 'author',
      fromTable: 'posts',
      fromKey: 'user_id',
      toTable: 'users',
      toKey: 'id',
    ));

    final uid = await db.table('users').insert({'name': 'Ada'});
    await db.table('posts').insertMany([
      {'user_id': uid, 'title': 'a'},
      {'user_id': uid, 'title': 'b'},
    ]);

    final users = await db.table('users').withMany('posts').get();
    expect((users.first['posts'] as List).length, 2);

    final ps = await db.table('posts').withOne('author').get();
    expect((ps.first['author'] as Map)['name'], 'Ada');

    await db.close();
  });

  test('contains runs on real sqlite, % matches literally', () async {
    final db = make();
    await db.createTable('items', (t) {
      t.id();
      t.text('name').notNull();
    });
    final items = db.table('items');
    await items.insertMany([
      {'name': 'apple'},
      {'name': 'apricot'},
      {'name': '100% juice'},
    ]);

    expect((await items.whereContains('name', 'ap').get()).length, 2);
    expect((await items.whereStartsWith('name', 'app').get()).length, 1);

    final pct = await items.where((w) => w.contains('name', '100%')).get();
    expect(pct.length, 1);
    expect(pct.first['name'], '100% juice');

    await db.close();
  });
}
