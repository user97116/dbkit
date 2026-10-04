# dbkit

Super-abstraction SQLite toolkit for **Dart & Flutter**. No hand-written `SELECT * FROM ...` for everyday work.

```dart
final users = db.table('users');

await users.insert({'name': 'Ada', 'age': 36});
await users.selectAll();
await users.findById(1);
await users.where((w) => w.gte('age', 18)).orderBy('name').limit(10).get();
await users.withMany('posts').get(); // eager-loaded relationship
```

## Contents

1. [Setup](#1-setup)
2. [Open a database](#2-open-a-database)
3. [Define the schema](#3-define-the-schema)
4. [CRUD without SQL](#4-crud-without-sql)
5. [Query builder](#5-query-builder)
6. [Filters reference](#6-filters-reference)
7. [Relationships](#7-relationships)
8. [Typed code with dbkit_gen](#8-typed-code-with-dbkit_gen)
9. [Transactions](#9-transactions)
10. [Migrations](#10-migrations)
11. [Testing with Db.fake()](#11-testing-with-dbfake)
12. [Debugging and raw SQL](#12-debugging-and-raw-sql)
13. [API reference (one way to do it)](#13-api-reference-one-way-to-do-it)
14. [Project structure & commands](#14-project-structure--commands)

## 1. Setup

```yaml
dependencies:
  dbkit:
    path: ../dbkit # or hosted version once published

dev_dependencies: # only if you use typed codegen
  build_runner: ^2.4.0
  dbkit_gen:
    path: ../dbkit_gen
```

```dart
import 'package:dbkit/dbkit.dart';
```

Requires Dart `^3.0.0`. The `sqlite3` backend needs `package:sqlite3` (already a dependency).

## 2. Open a database

Pick one backend. The fluent API is identical on all of them.

```dart
Db.memory();              // ephemeral, real SQLite via package:sqlite3
Db.open('app.db');        // file-backed SQLite
Db.fake();                // pure-Dart in-memory fake, no native libs (tests)
Db.custom(myAdapter);     // custom DbAdapter (e.g. sqflite bridge)

final db = Db.memory(logSql: true); // print compiled SQL via logger
```

Production defaults (`Db.memory()` / `Db.open()`): enforced foreign keys,
5s busy timeout; file-backed databases additionally use WAL mode with
`NORMAL` synchronous writes. Transactions use `BEGIN IMMEDIATE` with
savepoint support, so nested transactions roll back the inner scope only.
`List`/`Map` values are stored as JSON text. Empty rows, empty update maps,
negative `limit`/`offset`, invalid `page`, and empty table names throw
`ArgumentError` immediately. Custom `DbAdapter` implementations must also
implement `updateIncrement` (used by `increment`/`decrement`).

## 3. Define the schema

```dart
await db.createTable('users', (t) {
  t.id();                                   // INTEGER PRIMARY KEY AUTOINCREMENT
  t.text('name').notNull();
  t.integer('age').nullable();
  t.boolean('active').defaultsTo(true);
  t.timestamps();                           // created_at / updated_at, CURRENT_TIMESTAMP
  t.index(['age']);
});

await db.createTable('posts', (t) {
  t.id();
  t.foreignId('user_id', 'users');          // INTEGER NOT NULL REFERENCES "users"("id")
  t.text('title').notNull();
  t.boolean('published').defaultsTo(false);
  t.timestamps();
});

await db.createIndex('idx_users_age', 'users', ['age']);
await db.dropIndex('idx_users_age');
await db.dropTable('posts');
```

Column builders: `id`, `integer`, `text`, `real`, `blob`, `boolean`,
`datetime`, plus `notNull()`, `nullable()`, `defaultsTo(v)`,
`defaultsToNow()`, `defaultsToRaw(expr)`, `isUnique()`, `primary()`,
`autoInc()`, `referencesTable()`. Table constraints: `unique([...])`,
`primary([...])`, `foreign([...], ...)`, `check(...)`, `index([...])`.

## 4. CRUD without SQL

```dart
final users = db.table('users');

// Create
await users.insert({'name': 'Ada', 'age': 36});
await users.insertMany([
  {'name': 'Bob', 'age': 15},
  {'name': 'Cid', 'age': 29},
]);
await users.upsert({'id': 1, 'name': 'Ada', 'age': 37}); // ON CONFLICT DO UPDATE
await users.create({'name': 'Dee'}); // insert + return row with id

// Read
await users.selectAll(orderBy: 'age');
await users.findById(1);
await users.findByIdOrFail(1); // throws DbException when missing
await users.findOneWhere((w) => w.eq('name', 'Ada'));
await users.findWhere((w) => w.gte('age', 18));

await users.count();
await users.count((w) => w.gte('age', 18));
await users.existsWhere((w) => w.eq('name', 'Ada'));
await users.existsById(1);
await users.pluck<String>('name');

// Update
await users.updateById(1, {'age': 38});
await users.updateWhere((w) => w.lt('age', 18), {'active': false});
await users.increment('age', where: (w) => w.eq('id', 1));
await users.decrement('age', by: 2, where: (w) => w.eq('id', 1));

// Delete
await users.deleteById(1);
await users.deleteWhere((w) => w.eq('active', false));
await users.truncate();

// Pagination
final page = await users.query().orderBy('age').paginate(page: 2, perPage: 20);
// page.items, page.total, page.totalPages, page.hasNext / hasPrev
```

Values are normalized with `toSqlValue`: `bool` -> `0/1`, `DateTime` ->
ISO-8601, `Enum` -> `name`, `List`/`Map` -> JSON text.

## 5. Query builder

Start from `users.query()` (or the `users.where(...)` shortcut) and chain.
Nothing hits the database until a terminal (`get`, `first`, `count`,
`pluck`, `paginate`).

```dart
await users
    .query()
    .select(['id', 'name'])
    .where((w) => w.gte('age', 18))
    .orWhere((w) => w.isNull('age'))
    .orderBy('name')
    .limit(10)
    .offset(5)
    .get();

// Composable conditions
users.where((w) => w.gt('age', 18) & w.contains('name', 'da')).get();
users.where((w) => col('age').between(18, 30) | col('name').startsWith('A')).get();

// Shortcuts — plain text, no `%` wildcards needed
users.whereContains('name', 'da').get();
users.whereStartsWith('name', 'A').get();
users.whereEndsWith('name', 'a').get();
users.whereEq('active', true).get();
users.whereIn('id', [1, 2, 3]).get();

// Raw LIKE only when you really want your own %/_ pattern:
users.where((w) => w.like('name', 'A%')).get();

// Joins + aggregates
await users
    .query()
    .select(['users.name', 'COUNT(posts.id) AS post_count'])
    .leftJoin('posts', 'posts.user_id = users.id')
    .groupBy(['users.id'])
    .having((w) => w.gt('post_count', 2))
    .orderBy('name')
    .get();

// Inspect generated SQL without running it
final sql = users.where((w) => w.gte('age', 18)).toSql();
print(sql.sql); // SELECT * FROM "users" WHERE "age" >= ?
print(sql.args); // [18]
```

## 6. Filters reference

Build predicates with `where((w) => ...)` and combine them with `&` (AND),
`|` (OR), `~` (NOT). Or use the typed `col('age').gt(18)` form — same
filters, column bound first.

| Filter | Meaning |
|---|---|
| `eq` / `ne` | `=` / `!=` (`null` becomes `IS NULL` / `IS NOT NULL`) |
| `gt` / `gte` / `lt` / `lte` | `>` / `>=` / `<` / `<=` |
| `contains` / `notContains` | `LIKE %part%` — `%`, `_`, `\` in `part` match literally |
| `startsWith` / `notStartsWith` | `LIKE prefix%` (literal) |
| `endsWith` / `notEndsWith` | `LIKE %suffix` (literal) |
| `like` / `notLike` | Raw `LIKE` with your own `%`/`_` wildcards |
| `inList` / `notInList` | `IN (...)` (empty list folds to false/true) |
| `between` / `notBetween` | `BETWEEN lo AND hi` |
| `isNull` / `isNotNull` | `IS NULL` / `IS NOT NULL` |
| `raw` | Raw SQL fragment with args (sqlite backend only) |

## 7. Relationships (manual path)

> Using codegen ([§8](#8-typed-code-with-dbkit_gen))? Skip this section —
> `registerAllRelations(db)` generates exactly the declarations below, plus
> typed loaders like `ada.posts(db)`. What follows is the underlying
> map-based API the generated code is built on (also used directly by
> `example/main.dart` when you don't want codegen).

Declare once, eager-load anywhere. Each parent row gains a key named after
the relation (`List` for `hasMany` / many-to-many, `Map?` for `hasOne` /
`belongsTo`).

```dart
db.defineRelations([
  Relation.hasMany(
    name: 'posts', fromTable: 'users', fromKey: 'id',
    toTable: 'posts', toKey: 'user_id',
  ),
  Relation.belongsTo(
    name: 'author', fromTable: 'posts', fromKey: 'user_id',
    toTable: 'users', toKey: 'id',
  ),
  Relation.hasOne(
    name: 'profile', fromTable: 'users', fromKey: 'id',
    toTable: 'profiles', toKey: 'user_id',
  ),
  Relation.belongsToMany(
    name: 'tags', fromTable: 'posts', fromKey: 'id',
    toTable: 'tags', toKey: 'id',
    pivotTable: 'post_tags', pivotFromKey: 'post_id', pivotToKey: 'tag_id',
  ),
]);

await db.table('users').withMany('posts').get();
// -> [{'id': 1, 'name': 'Ada', 'posts': [{...}, {...}]}, ...]

// One user -> their posts (one-to-many, List)
final user = await db.table('users').findByIdOrFail(1);
final posts = await db.table('users').load(user, 'posts') as List;

// One user -> their profile (one-to-one, Map? — null when missing)
final profile = await db.table('users').load(user, 'profile') as Map?;

// One post -> its author (belongs-to, Map?)
final post = await db.table('posts').findByIdOrFail(10);
final author = await db.table('posts').load(post, 'author') as Map?;

// Eager-load on lists too
await db.table('posts').withOne('author').get();
await db.table('users').withRelations(['posts', 'profile']).get();

// Constrain the eager load
await db.table('users').withMany(
  'posts',
  (q) => q.where((w) => w.eq('published', true)),
).get();
```

Unknown relation names throw `DbException` with a hint to call
`defineRelation()`. For typed relations without maps, see
[section 8](#8-typed-code-with-dbkit_gen).

## 8. Typed code with dbkit_gen

Hand-written maps get old. Annotate plain Dart classes and generate typed
models, repositories, query helpers, and relationship loaders with the
sibling [`dbkit_gen`](../dbkit_gen) package (dev-only, via `build_runner`):

```sh
dart run build_runner build
```

```dart
// models.dart
import 'package:dbkit/dbkit.dart';

part 'models.g.dart';

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId')
@HasOne(Profile, name: 'profile', foreignKey: 'userId')
class User {
  @DbId()
  final int? id;
  final String name;
  final int? age;

  const User({this.id, required this.name, this.age});

  factory User.fromMap(Map<String, Object?> map) => _$UserFromMap(map);
  Map<String, Object?> toMap() => _$UserToMap(this);
}

@DbTable('posts')
@BelongsTo(User, name: 'author', foreignKey: 'userId')
@BelongsToMany(Tag,
    name: 'tags', pivot: 'post_tags', fromKey: 'post_id', toKey: 'tag_id')
class Post {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id', references: 'users')
  final int userId;
  final String title;

  const Post({this.id, required this.userId, required this.title});

  factory Post.fromMap(Map<String, Object?> map) => _$PostFromMap(map);
  Map<String, Object?> toMap() => _$PostToMap(this);
}
```

```dart
await createAllTables(db);
registerAllRelations(db);

var ada = await db.users.save(const User(name: 'Ada', age: 36));

// hasMany → List<Post>
final posts = await ada.posts(db);
// hasOne → single Profile? (null when missing)
final profile = await ada.profile(db);
// belongsTo → single User?
final author = await post.author(db);
// belongsToMany → List<Tag> + link helpers
await post.addTag(db, tag);
await post.removeTag(db, tag);
final tags = await post.tags(db);

final adults = await db.users.list(
  where: (w) => w.gte(UserColumns.age, 18),
  orderBy: UserColumns.name,
);
```

Generated per table: `_$XFromMap` / `_$XToMap` helpers, `XxxColumns`
constants, `XxxTable` repository (`all`, `list`, `findById`,
`findByIdOrFail`, `findOne`, `count`, `exists`, `insert`, `insertMany`,
`save` (returns the saved row with its id), `update`, `updateById`,
`deleteById`, `deleteWhere`, …), lazy loaders (`user.posts(db)` → `List`,
`user.profile(db)` / `post.author(db)` → nullable single), many-to-many
link helpers (`addTag`/`removeTag`), and eager wrappers
(`db.users.withPosts()` → `UserWithPosts(user, posts)`). Per-file
aggregates `createAllTables` / `dropAllTables` / `registerAllRelations`
cover every table in one call — `registerAllRelations(db)` replaces the
hand-written `defineRelations([...])` block in
[§7](#7-relationships-manual-path). See `test/gen/models.dart` +
`generated_test.dart` for a runnable example, `example/blog/` for the full
demo, and the [dbkit_gen README](../dbkit_gen/README.md) for the
annotation reference.

| Annotation | FK lives on | Loader returns |
|---|---|---|
| `@HasMany(T, name: 'posts', foreignKey: 'userId')` | target (`posts.user_id`) | `Future<List<T>> posts(db)` |
| `@HasOne(T, name: 'profile', foreignKey: 'userId')` | target (`profiles.user_id`) | `Future<T?> profile(db)` |
| `@BelongsTo(T, name: 'author', foreignKey: 'userId')` | this table (`posts.user_id`) | `Future<T?> author(db)` |
| `@BelongsToMany(T, name: 'tags', pivot: 'post_tags', fromKey: 'post_id', toKey: 'tag_id')` | pivot table | `Future<List<T>> tags(db)` + `addTag`/`removeTag` |

Every named `this.` constructor parameter becomes a column
(`copyWith`/`==`/`hashCode`/`toString` are safe — `hashCode`/`runtimeType`
overrides are always ignored). Mark any other computed member with
`@DbIgnore()` or codegen rejects it.

## 9. Transactions

```dart
await db.transaction((tx) async {
  final id = await tx.table('users').insert({'name': 'Ada'});
  await tx.table('posts').insert({'user_id': id, 'title': 'Hi'});
}); // rollback on error; relations are shared inside tx
```

## 10. Migrations

```dart
await db.migrate([
  Migration(
    version: 1,
    description: 'add bio column',
    run: (m) async {
      await m.sql('ALTER TABLE "users" ADD COLUMN "bio" TEXT');
    },
  ),
]);
```

Migrations run in version order inside transactions; applied versions are recorded in `_migrations`.

## 11. Testing with Db.fake()

`Db.fake()` runs the same fluent API purely in Dart, with no native libraries. Use structured `where()` filters there:

- `rawSelect` / `execute` with arbitrary SQL throw `DbException` (DDL and `DELETE FROM "x"` clears are accepted so schema code runs unchanged).
- `RawCondition` cannot be evaluated in memory and throws `UnsupportedError`; `whereRaw` therefore requires the real `sqlite3` backend.

## 12. Debugging and raw SQL

```dart
final db = Db.memory(logSql: true);

await db.raw('SELECT COUNT(*) AS n FROM "users"');
await db.exec('PRAGMA foreign_keys = ON');
users.query().whereRaw('age > ?', [18]).get();
```

## 13. API reference (one way to do it)

One canonical method per job. Aliases were removed in 0.4.0, so if two
methods look alike, check here first.

| Job | Use this |
|---|---|
| Read rows | `selectAll()` / `findById()` / `findOneWhere()` / `findWhere()` / `query()...get()` |
| Missing row must fail | `findByIdOrFail()` / `firstOrFail()` |
| Count / exists / column | `count()` / `existsWhere()` / `pluck<T>()` |
| Pages | `paginate(page:, perPage:)` (or `query().page().get()` for rows only) |
| Write | `insert()` / `insertMany()` / `upsert()` / `create()` |
| Change rows | `updateById()` / `updateWhere()` / `increment()` |
| Remove rows | `deleteById()` / `deleteWhere()` / `truncate()` |
| Sort | `orderBy(col)` / `orderBy(col, desc: true)` / `orderByDesc(col)` |
| Filter text | `contains` / `startsWith` / `endsWith` (never write `%` yourself) |
| Nullability in blueprints | `notNull()` / `nullable()` |
| Relations (maps) | `withMany` / `withOne` / `withRelations` / `load()` |
| Relations (typed) | `user.posts(db)` / `user.profile(db)` / `post.author(db)` / `post.tags(db)` |
| Schema setup (typed) | `createAllTables()` / `registerAllRelations()` |

## 14. Project structure & commands

```text
lib/dbkit.dart
lib/src/database.dart   # Db facade
lib/src/table.dart      # TableRef, TableQuery, Page
lib/src/query.dart      # SelectQuery + insert/update/delete compilers
lib/src/filter.dart     # Condition, Where, ColumnRef
lib/src/relation.dart   # Relation, RelationRegistry
lib/src/column.dart     # TableBlueprint, ColumnDef
lib/src/annotations.dart # @DbTable, @DbColumn, @DbId, @DbIgnore, @HasMany, ...
lib/src/adapter.dart    # DbAdapter interface
lib/src/adapters/sqlite3_adapter.dart
lib/src/adapters/memory_adapter.dart
example/main.dart          # runnable tour: schema, CRUD, joins, relations
example/blog/              # typed blog demo (dbkit_gen output + usage)
  models.dart              #   annotated source (@DbTable + relations)
  models.g.dart            #   generated client (do not edit)
  main.dart                #   typed CRUD + relations demo
test/query_builder_test.dart
test/memory_db_test.dart
test/relations_test.dart
test/sqlite3_test.dart
test/production_test.dart
test/generated_test.dart   # runtime tests for generated code (both backends)
test/gen/                  #   generator fixture: models.dart + models.g.dart
```

```sh
dart run build_runner build   # regenerate test/gen/models.g.dart + example/blog/models.g.dart
dart test
dart run example/main.dart
dart run example/blog/main.dart
dart analyze lib test example
```

## License

MIT — see `LICENSE`.
