import 'package:dbkit/dbkit.dart';
import 'package:test/test.dart';

import 'gen/models.dart';

/// End-to-end proof that `dbkit_gen` output compiles and runs:
/// typed CRUD, query helpers, and every relationship kind.
void main() {
  group('generated code (fake backend)', () => _suite(() => Db.fake()));
  group('generated code (sqlite backend)', () => _suite(Db.memory));
}

void _suite(Db Function() make) {
  late Db db;

  setUp(() async {
    db = make();
    await createAllTables(db);
    registerAllRelations(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('typed CRUD: insert, find, update, delete', () async {
    final ada = await db.users.save(const User(name: 'Ada', age: 36));
    expect(ada.id, isNotNull);

    expect(await db.users.findById(ada.id!), ada);
    expect(await db.users.findByIdOrFail(ada.id!), ada);
    expect(await db.users.findById(999), isNull);

    await db.users.update(ada.copyWith(age: 37));
    expect((await db.users.findById(ada.id!))!.age, 37);

    expect(await db.users.count(), 1);
    expect(await db.users.exists((w) => w.eq(UserColumns.name, 'Ada')), isTrue);

    await db.users.deleteById(ada.id!);
    expect(await db.users.count(), 0);
  });

  test('list with filters, column constants and ordering', () async {
    await db.users.insertMany(const [
      User(name: 'Ada', age: 36),
      User(name: 'Bob', age: 15),
      User(name: 'Cid', age: 29),
    ]);

    final adults = await db.users.list(
      where: (w) => w.gte(UserColumns.age, 18),
      orderBy: UserColumns.age,
    );
    expect(adults.map((u) => u.name), ['Cid', 'Ada']);

    final found = await db.users.findOne((w) => w.contains(UserColumns.name, 'o'));
    expect(found!.name, 'Bob');
  });

  test('save inserts or replaces by id', () async {
    var ada = await db.users.save(const User(name: 'Ada', age: 36));
    ada = await db.users.save(ada.copyWith(age: 37));
    expect(ada.age, 37);
    expect(await db.users.count(), 1);
    expect((await db.users.findById(ada.id!))!.age, 37);
  });

  test('hasMany: user -> posts, lazy and eager', () async {
    final ada = await db.users.save(const User(name: 'Ada'));
    await db.posts.insertMany([
      Post(userId: ada.id!, title: 'Hello'),
      Post(userId: ada.id!, title: 'Draft', published: true),
    ]);

    // lazy: access post data from the user row
    final posts = await ada.posts(db);
    expect(posts.map((p) => p.title), ['Hello', 'Draft']);

    // eager: typed wrappers
    final withPosts = await db.users.withPosts();
    expect(withPosts.single.posts.length, 2);
    expect(withPosts.single.user, ada);
  });

  test('hasOne: user -> profile (present and missing)', () async {
    final ada = await db.users.save(const User(name: 'Ada'));
    final bob = await db.users.save(const User(name: 'Bob'));
    await db.profiles.insert(Profile(userId: ada.id!, bio: 'pioneer'));

    expect((await ada.profile(db))!.bio, 'pioneer');
    expect(await bob.profile(db), isNull);

    final rows = await db.users.withProfile(orderBy: UserColumns.name);
    expect(rows.map((r) => r.profile?.bio), ['pioneer', null]);
  });

  test('belongsTo: post -> author', () async {
    final ada = await db.users.save(const User(name: 'Ada'));
    final post = await db.posts.save(Post(userId: ada.id!, title: 'Hi'));

    expect((await post.author(db))!, ada);

    final rows = await db.posts.withAuthor();
    expect(rows.single.author, ada);
  });

  test('many-to-many: link, list, unlink tags', () async {
    final ada = await db.users.save(const User(name: 'Ada'));
    var post = await db.posts.save(Post(userId: ada.id!, title: 'Hi'));
    final dart = await db.tags.save(const Tag(label: 'dart'));
    final sqlite = await db.tags.save(const Tag(label: 'sqlite'));

    expect(await post.tags(db), isEmpty);

    await post.addTag(db, dart);
    await post.addTag(db, sqlite);
    expect((await post.tags(db)).map((t) => t.label), ['dart', 'sqlite']);

    await post.removeTag(db, dart);
    expect((await post.tags(db)).map((t) => t.label), ['sqlite']);

    // eager variant
    post = (await db.posts.findById(post.id!))!;
    final rows = await db.posts.withTags();
    expect(rows.single.tags.map((t) => t.label), ['sqlite']);
  });

  test('dropAllTables removes everything', () async {
    await db.users.save(const User(name: 'Ada'));
    await dropAllTables(db);
    await createAllTables(db);
    expect(await db.users.count(), 0);
  });
}
