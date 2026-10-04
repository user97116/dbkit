import 'package:test/test.dart';
import 'package:dbkit/dbkit.dart';

void main() {
  late Db db;

  setUp(() async {
    db = Db.fake();
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
      Relation.hasOne(
        name: 'profile',
        fromTable: 'users',
        fromKey: 'id',
        toTable: 'profiles',
        toKey: 'user_id',
      ),
      Relation.belongsToMany(
        name: 'tags',
        fromTable: 'posts',
        fromKey: 'id',
        toTable: 'tags',
        toKey: 'id',
        pivotTable: 'post_tags',
        pivotFromKey: 'post_id',
        pivotToKey: 'tag_id',
      ),
    ]);

    final users = db.table('users');
    final posts = db.table('posts');
    final profiles = db.table('profiles');
    final tags = db.table('tags');
    final pt = db.table('post_tags');

    await users.insertMany([
      {'id': 1, 'name': 'Ada'},
      {'id': 2, 'name': 'Bob'},
    ]);
    await posts.insertMany([
      {'id': 10, 'user_id': 1, 'title': 'Hello', 'published': true},
      {'id': 11, 'user_id': 1, 'title': 'Draft', 'published': false},
      {'id': 12, 'user_id': 2, 'title': 'Bob post', 'published': true},
    ]);
    await profiles.insertMany([
      {'id': 100, 'user_id': 1, 'bio': 'pioneer'},
    ]);
    await tags.insertMany([
      {'id': 1000, 'label': 'dart'},
      {'id': 1001, 'label': 'sqlite'},
    ]);
    await pt.insertMany([
      {'post_id': 10, 'tag_id': 1000},
      {'post_id': 10, 'tag_id': 1001},
      {'post_id': 12, 'tag_id': 1000},
    ]);
  });

  test('hasMany eager load', () async {
    final rows =
        await db.table('users').query().orderBy('id').withMany('posts').get();
    expect(rows.length, 2);
    expect((rows[0]['posts'] as List).length, 2);
    expect((rows[1]['posts'] as List).length, 1);
  });

  test('hasMany with constrain (published only)', () async {
    final rows = await db
        .table('users')
        .query()
        .withMany('posts', (q) => q.where((w) => w.eq('published', true)))
        .get();
    final ada = rows.firstWhere((r) => r['name'] == 'Ada');
    expect((ada['posts'] as List).length, 1);
  });

  test('belongsTo eager load', () async {
    final rows =
        await db.table('posts').query().orderBy('id').withOne('author').get();
    expect(rows.length, 3);
    expect((rows[0]['author'] as Map)['name'], 'Ada');
    expect((rows[2]['author'] as Map)['name'], 'Bob');
  });

  test('hasOne eager load (null when missing)', () async {
    final rows =
        await db.table('users').query().orderBy('id').withOne('profile').get();
    expect((rows[0]['profile'] as Map)['bio'], 'pioneer');
    expect(rows[1]['profile'], isNull);
  });

  test('manyToMany eager load', () async {
    final rows =
        await db.table('posts').query().orderBy('id').withMany('tags').get();
    final hello = rows.firstWhere((r) => r['id'] == 10);
    expect((hello['tags'] as List).length, 2);
    final draft = rows.firstWhere((r) => r['id'] == 11);
    expect((draft['tags'] as List), isEmpty);
  });

  test('withRelations plural shortcut', () async {
    final rows = await db
        .table('users')
        .withRelations(['posts', 'profile'])
        .orderBy('id')
        .get();
    expect(rows[0].containsKey('posts'), isTrue);
    expect(rows[0].containsKey('profile'), isTrue);
  });

  test('load() lazy-loads one row\'s relation', () async {
    final users = db.table('users');
    final posts = db.table('posts');

    // one-to-many: user -> posts
    final ada = await users.findOneWhere((w) => w.eq('name', 'Ada'));
    final adaPosts = await users.load(ada!, 'posts') as List;
    expect(adaPosts.length, 2);

    // one-to-one: user -> profile (present + missing)
    final profile = await users.load(ada, 'profile') as Map?;
    expect(profile!['bio'], 'pioneer');
    final bob = await users.findOneWhere((w) => w.eq('name', 'Bob'));
    expect(await users.load(bob!, 'profile'), isNull);

    // many-to-one: post -> author
    final hello = await posts.findOneWhere((w) => w.eq('title', 'Hello'));
    final author = await posts.load(hello!, 'author') as Map?;
    expect(author!['name'], 'Ada');

    // many-to-many: post -> tags
    final tags = await posts.load(hello, 'tags') as List;
    expect(tags.length, 2);
    final draft = await posts.findOneWhere((w) => w.eq('title', 'Draft'));
    expect(await posts.load(draft!, 'tags'), isEmpty);
  });

  test('belongsTo honors constrain', () async {
    final rows = await db.table('posts').query().orderBy('id').withOne(
        'author', (q) => q.where((w) => w.eq('name', 'Nobody'))).get();
    expect(rows.every((r) => r['author'] == null), isTrue);
  });

  test('unknown relation throws helpful error', () async {
    await expectLater(
        db.table('users').withMany('nope').get(), throwsA(isA<Exception>()));
    await expectLater(
        db.table('users').load({'id': 1}, 'nope'),
        throwsA(isA<Exception>()));
  });
}
