/// Compile-time annotations for `dbkit_gen` code generation.
///
/// Annotate plain Dart classes — no runtime cost, the annotations only guide
/// the generator (`dart run build_runner build`):
///
/// ```dart
/// import 'package:dbkit/dbkit.dart';
///
/// part 'user.g.dart';
///
/// @DbTable('users')
/// @HasMany(Post, name: 'posts', foreignKey: 'userId')
/// class User {
///   @DbId()
///   final int? id;
///
///   final String name;
///   final int? age;
///
///   const User({this.id, required this.name, this.age});
///
///   factory User.fromMap(Map<String, Object?> map) => _$UserFromMap(map);
///   Map<String, Object?> toMap() => _$UserToMap(this);
/// }
/// ```
library;

/// Marks a class as a database table.
///
/// The generator emits `_$XFromMap` / `_$XToMap` helpers (called from the
/// `fromMap` / `toMap` glue above), an `XColumns` constants class, an
/// `XTable` repository, relationship loaders, eager-load wrappers, a `Db`
/// extension getter, and `createXTable` / `registerXRelations` setup
/// functions into the part file `<name>.g.dart`.
///
/// Every named `this.` constructor parameter becomes a column; anything
/// else (computed getters, helpers) must be marked [@DbIgnore] (`get
/// hashCode` / `get runtimeType` overrides are always ignored). Field
/// nullability decides nullability: `int? age` is nullable, `String name`
/// is `NOT NULL`. Supported field types: `int`, `String`, `double`,
/// `bool`, `DateTime`, `Uint8List`.
class DbTable {
  /// The table name, e.g. `'users'`.
  final String name;

  /// When true, `created_at` / `updated_at` (`CURRENT_TIMESTAMP`) columns
  /// are created. The model must declare matching `DateTime?` fields.
  final bool timestamps;

  const DbTable(this.name, {this.timestamps = false});
}

/// Configures a single column (field).
///
/// ```dart
/// @DbColumn(name: 'user_id', references: 'users')
/// final int userId;
///
/// @DbColumn(unique: true)
/// final String email;
///
/// @DbColumn(defaultValue: false)
/// final bool published;
/// ```
class DbColumn {
  /// DB column name override. Defaults to the field name, so
  /// `final int userId;` maps to column `userId` unless
  /// `name: 'user_id'` is given.
  final String? name;

  /// Adds a `UNIQUE` constraint.
  final bool unique;

  /// Dart-level default written into `DEFAULT` (`bool`, `num` or `String`).
  final Object? defaultValue;

  /// `DEFAULT CURRENT_TIMESTAMP` (datetime fields only).
  final bool defaultNow;

  /// Referenced table for a foreign key (references its `id` column with
  /// `CASCADE`/`CASCADE` unless [referencesColumn]/[onDelete]/[onUpdate]
  /// say otherwise).
  final String? references;

  /// Referenced column. Defaults to `'id'`.
  final String? referencesColumn;

  /// `ON DELETE` action, e.g. `'CASCADE'`, `'SET NULL'`.
  final String? onDelete;

  /// `ON UPDATE` action, e.g. `'CASCADE'`.
  final String? onUpdate;

  /// Raw `CHECK` expression, e.g. `'length(bio) < 500'`.
  final String? check;

  /// Marks a non-autoincrement primary key (e.g. a `String` id).
  /// Exactly one primary key per table; composite keys are not supported
  /// by codegen.
  final bool primaryKey;

  const DbColumn({
    this.name,
    this.unique = false,
    this.defaultValue,
    this.defaultNow = false,
    this.references,
    this.referencesColumn,
    this.onDelete,
    this.onUpdate,
    this.check,
    this.primaryKey = false,
  });
}

/// Marks the integer primary key (`INTEGER PRIMARY KEY AUTOINCREMENT`).
///
/// ```dart
/// @DbId()
/// final int? id;
/// ```
class DbId {
  /// Always true for now: `AUTOINCREMENT` requires an integer key.
  final bool autoIncrement;

  /// DB column name override. Defaults to the field name.
  final String? name;

  const DbId({this.autoIncrement = true, this.name});
}

/// Marks a field or getter to be ignored by codegen.
///
/// Persisted fields must be named `this.` constructor parameters; anything
/// else (e.g. a computed getter) is rejected unless marked ignored:
///
/// ```dart
/// @DbTable('users')
/// class User {
///   @DbId()
///   final int? id;
///   final String name;
///   const User({this.id, required this.name});
///
///   @DbIgnore()
///   String get displayName => name.toUpperCase();
/// }
/// ```
///
/// (`get hashCode` / `get runtimeType` overrides are always ignored.)
class DbIgnore {
  const DbIgnore();
}

/// Secondary index on a table. Repeatable.
///
/// ```dart
/// @DbTable('users')
/// @DbIndex(['age'])
/// @DbIndex(name: 'idx_users_name', columns: ['name'], unique: true)
/// class User { ... }
/// ```
class DbIndex {
  /// Indexed fields (model field names).
  final List<String> columns;

  /// Index name. Defaults to `idx_<table>_<columns>`.
  final String? name;

  /// Creates a `UNIQUE` index.
  final bool unique;

  const DbIndex(this.columns, {this.name, this.unique = false});
}

/// One parent row -> many child rows. FK lives on the target table.
///
/// ```dart
/// @HasMany(Post, name: 'posts', foreignKey: 'userId')
/// ```
///
/// Generates a `posts(Db)` loader returning `List<Post>`, an eager
/// `withPosts()` query returning `UserWithPosts` wrappers, and registers
/// the relation for `withMany('posts')`.
class HasMany {
  /// The child model type.
  final Type target;

  /// Relation name: generated method/loader name and eager-load key.
  final String name;

  /// FK field on the target model (e.g. `Post.userId`).
  final String foreignKey;

  /// Key field on this model. Defaults to this table's primary-key field.
  final String? localKey;

  /// Default ordering field on the target model.
  final String? orderBy;

  /// Sort descending when [orderBy] is set.
  final bool desc;

  /// Default limit for eager loads.
  final int? limit;

  const HasMany(
    this.target, {
    required this.name,
    required this.foreignKey,
    this.localKey,
    this.orderBy,
    this.desc = false,
    this.limit,
  });
}

/// One parent row -> one child row. FK lives on the target table.
///
/// Generates a `profile(Db)` loader returning `Profile?` plus eager
/// `withProfile()` support.
class HasOne {
  /// The child model type.
  final Type target;

  /// Relation name.
  final String name;

  /// FK field on the target model.
  final String foreignKey;

  /// Key field on this model. Defaults to this table's primary-key field.
  final String? localKey;

  const HasOne(
    this.target, {
    required this.name,
    required this.foreignKey,
    this.localKey,
  });
}

/// Many child rows -> one parent row. FK lives on this table.
///
/// ```dart
/// @BelongsTo(User, name: 'author', foreignKey: 'userId')
/// ```
///
/// Generates an `author(Db)` loader returning `User?` plus eager
/// `withAuthor()` support.
class BelongsTo {
  /// The parent model type.
  final Type target;

  /// Relation name.
  final String name;

  /// FK field on this model.
  final String foreignKey;

  /// Key field on the target model. Defaults to its primary-key field.
  final String? targetKey;

  const BelongsTo(
    this.target, {
    required this.name,
    required this.foreignKey,
    this.targetKey,
  });
}

/// Many-to-many through a pivot table (created manually with
/// `db.createTable`, or via its own `@DbTable` model).
///
/// ```dart
/// @BelongsToMany(Tag, name: 'tags', pivot: 'post_tags',
///     fromKey: 'post_id', toKey: 'tag_id')
/// ```
///
/// Generates a `tags(Db)` loader, `addTag`/`removeTag` link helpers, and
/// eager `withTags()` support. [fromKey]/[toKey] are raw pivot *column*
/// names (the pivot table has no model requirements).
class BelongsToMany {
  /// The far model type.
  final Type target;

  /// Relation name.
  final String name;

  /// Pivot table name.
  final String pivot;

  /// Pivot column pointing at this table.
  final String fromKey;

  /// Pivot column pointing at the target table.
  final String toKey;

  /// Key field on this model. Defaults to this table's primary-key field.
  final String? localKey;

  /// Key field on the target model. Defaults to its primary-key field.
  final String? targetKey;

  const BelongsToMany(
    this.target, {
    required this.name,
    required this.pivot,
    required this.fromKey,
    required this.toKey,
    this.localKey,
    this.targetKey,
  });
}
