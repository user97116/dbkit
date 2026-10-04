import 'package:dbkit/dbkit.dart';

/// Run with: `dart run example/main.dart`
Future<void> main() async {
  // Swap Db.memory() (real sqlite) with Db.fake() (pure Dart, no natives).
  final db = Db.memory(logSql: true);

  // 1. Schema — no SQL.
  await db.createTable('users', (t) {
    t.id();
    t.text('name').notNull();
    t.integer('age').nullable();
    t.boolean('active').defaultsTo(true);
    t.timestamps();
    t.index(['age']);
  });
  await db.createTable('posts', (t) {
    t.id();
    t.foreignId('user_id', 'users');
    t.text('title').notNull();
    t.boolean('published').defaultsTo(false);
    t.timestamps();
  });

  // 2. Relationships — declared once, eager-loaded anywhere.
  db.defineRelations([
    Relation.hasMany(
      name: 'posts',
      fromTable: 'users',
      fromKey: 'id',
      toTable: 'posts',
      toKey: 'user_id',
    ),
    Relation.belongsTo(
      name: 'author',
      fromTable: 'posts',
      fromKey: 'user_id',
      toTable: 'users',
      toKey: 'id',
    ),
  ]);

  final users = db.table('users');
  final posts = db.table('posts');

  // 3. Writes.
  final adaId = await users.insert({'name': 'Ada', 'age': 36});
  await users.insertMany([
    {'name': 'Bob', 'age': 15},
    {'name': 'Cid', 'age': 29},
  ]);
  await users.upsert({'id': adaId, 'name': 'Ada', 'age': 37});
  await posts.insertMany([
    {'user_id': adaId, 'title': 'Hello sqlite', 'published': true},
    {'user_id': adaId, 'title': 'Draft', 'published': false},
  ]);

  // 4. Reads — zero SQL strings, no % wildcards.
  print(await users.selectAll(orderBy: 'age'));
  print(await users.findById(adaId));
  print(await users.whereContains('name', 'a').orderByDesc('age').get());
  print('adults: ${await users.where((w) => w.gte('age', 18)).count()}');
  print('names: ${await users.pluck<String>('name')}');

  // 5. Joins + aggregates.
  print(await users
      .query()
      .select(['users.name', 'COUNT(posts.id) AS post_count'])
      .leftJoin('posts', 'posts.user_id = users.id')
      .groupBy(['users.id'])
      .orderBy('name')
      .get());

  // 6. Relationships: user -> posts, post -> author.
  print(await users.withMany('posts').orderBy('id').get());
  print(await posts.withOne('author').get());
  final ada = await users.findByIdOrFail(adaId);
  print(await users.load(ada, 'posts')); // hasMany: List
  final draft = await posts.findOneWhere((w) => w.eq('title', 'Draft'));
  print(await posts.load(draft!, 'author')); // belongsTo: Map?

  // 7. Pagination.
  final page =
      await users.query().orderBy('age').paginate(page: 1, perPage: 2);
  print('page 1/${page.totalPages}: ${page.items} (total ${page.total})');

  // 8. Transactions.
  await db.transaction((tx) async {
    final id = await tx.table('users').insert({'name': 'Tx', 'age': 20});
    await tx.table('posts').insert({'user_id': id, 'title': 'tx post'});
  });

  // 9. Typed codegen alternative: see example/blog/ (dbkit_gen output).
  await db.close();
}
