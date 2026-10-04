import 'package:dbkit/dbkit.dart';

import 'models.dart';

/// Typed blog demo using `dbkit_gen` output. Run with:
/// `dart run example/blog/main.dart`
///
/// Models live in `models.dart` (annotated with `@DbTable`, `@HasMany`,
/// `@HasOne`, `@BelongsTo`, `@BelongsToMany`). Regenerate the client after
/// editing them:
/// `dart run build_runner build`  →  `models.g.dart` (do not edit)
Future<void> main() async {
  final db = Db.memory();
  await createAllTables(db);
  registerAllRelations(db);

  // 1. Typed writes — no maps, no column-name strings.
  // `save` returns the saved row (with its new id on autoincrement tables).
  var ada = await db.users.save(const User(name: 'Ada', age: 36));
  final bob = await db.users.save(const User(name: 'Bob', age: 15));
  await db.profiles.save(Profile(userId: ada.id!, bio: 'pioneer'));
  var post = await db.posts
      .save(Post(userId: ada.id!, title: 'Hello dbkit', published: true));
  await db.posts.save(Post(userId: ada.id!, title: 'Draft notes'));

  // 2. Typed reads with refactor-safe columns.
  print(await db.users.all(orderBy: UserColumns.age, desc: true));
  print(await db.users.list(where: (w) => w.gte(UserColumns.age, 18)));
  print(await db.users.findByIdOrFail(ada.id!));
  print('adults: ${await db.users.count((w) => w.gte(UserColumns.age, 18))}');

  // 3. Update + save round-trip.
  await db.users.update(ada.copyWith(age: 37));
  ada = (await db.users.findById(ada.id!))!;
  print('ada is now ${ada.age}');

  // 4. Relationships, all four kinds.
  // hasMany → List<Post>
  print('ada posts: ${await ada.posts(db)}');
  // hasOne → single Profile? (null when missing)
  print('ada profile: ${await ada.profile(db)}');
  print('bob profile: ${await bob.profile(db)}');
  // belongsTo → single User?
  print('author: ${await post.author(db)}');

  // 5. Many-to-many link helpers.
  final dart = await db.tags.save(const Tag(label: 'dart'));
  final sqlite = await db.tags.save(const Tag(label: 'sqlite'));
  await post.addTag(db, dart);
  await post.addTag(db, sqlite);
  print('tags: ${await post.tags(db)}');
  await post.removeTag(db, dart);
  print('tags left: ${await post.tags(db)}');

  // 6. Eager loading into typed wrappers.
  for (final u in await db.users.withPosts()) {
    print('${u.user.name} wrote ${u.posts.length} post(s)');
  }
  for (final p in await db.posts.withTags()) {
    print('"${p.post.title}" tagged ${p.tags.map((t) => t.label).toList()}');
  }

  await db.close();
}
