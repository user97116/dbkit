import 'filter.dart';
import 'query.dart';

/// Relationship kinds.
enum RelationKind {
  /// One parent row -> one child row.
  hasOne,

  /// One parent row -> many child rows.
  hasMany,

  /// Many child rows -> one parent row.
  belongsTo,

  /// Many rows <-> many rows via a pivot table.
  manyToMany
}

/// Declarative relationship between two tables.
///
/// ```dart
/// db.defineRelation(Relation.hasMany(
///   name: 'posts',
///   fromTable: 'users', fromKey: 'id',
///   toTable: 'posts', toKey: 'user_id',
/// ));
/// final rows = await db.table('users').withMany('posts').get();
/// // each user row gains `posts: [...]`
/// ```
class Relation {
  /// Relation name — the key each row gains when eager-loaded.
  final String name;

  /// The relationship kind.
  final RelationKind kind;

  /// Parent table holding [fromKey].
  final String fromTable;

  /// Key column on [fromTable].
  final String fromKey;

  /// Child/target table holding [toKey].
  final String toTable;

  /// Key column on [toTable].
  final String toKey;

  /// Pivot table for many-to-many (e.g. `post_tags`).
  final String? pivotTable;

  /// Pivot column pointing at [fromTable].
  final String? pivotFromKey;

  /// Pivot column pointing at [toTable].
  final String? pivotToKey;

  /// Optional default ordering / extra filter for eager loads.
  final Condition Function(Where w)? filter;

  /// Default ordering column for eager loads.
  final String? orderByColumn;

  /// Whether the default ordering is descending.
  final bool orderDesc;

  /// Default row limit for eager loads.
  final int? limit;

  const Relation._({
    required this.name,
    required this.kind,
    required this.fromTable,
    required this.fromKey,
    required this.toTable,
    required this.toKey,
    this.pivotTable,
    this.pivotFromKey,
    this.pivotToKey,
    this.filter,
    this.orderByColumn,
    this.orderDesc = false,
    this.limit,
  });

  /// One parent -> many children. FK lives on [toTable].
  /// e.g. users(1) -> posts(N) via `posts.user_id`.
  factory Relation.hasMany({
    required String name,
    required String fromTable,
    required String fromKey,
    required String toTable,
    required String toKey,
    Condition Function(Where w)? filter,
    String? orderBy,
    bool desc = false,
    int? limit,
  }) =>
      Relation._(
        name: name,
        kind: RelationKind.hasMany,
        fromTable: fromTable,
        fromKey: fromKey,
        toTable: toTable,
        toKey: toKey,
        filter: filter,
        orderByColumn: orderBy,
        orderDesc: desc,
        limit: limit,
      );

  /// One child -> one parent. FK lives on [fromTable].
  /// e.g. posts(N) -> users(1) via `posts.user_id`.
  factory Relation.belongsTo({
    required String name,
    required String fromTable,
    required String fromKey,
    required String toTable,
    required String toKey,
  }) =>
      Relation._(
        name: name,
        kind: RelationKind.belongsTo,
        fromTable: fromTable,
        fromKey: fromKey,
        toTable: toTable,
        toKey: toKey,
      );

  /// One parent -> one child. FK lives on [toTable] (unique).
  factory Relation.hasOne({
    required String name,
    required String fromTable,
    required String fromKey,
    required String toTable,
    required String toKey,
  }) =>
      Relation._(
        name: name,
        kind: RelationKind.hasOne,
        fromTable: fromTable,
        fromKey: fromKey,
        toTable: toTable,
        toKey: toKey,
      );

  /// Many-to-many via a pivot table.
  /// e.g. posts <-> tags via `post_tags(post_id, tag_id)`.
  factory Relation.belongsToMany({
    required String name,
    required String fromTable,
    required String fromKey,
    required String toTable,
    required String toKey,
    required String pivotTable,
    required String pivotFromKey,
    required String pivotToKey,
    Condition Function(Where w)? filter,
  }) =>
      Relation._(
        name: name,
        kind: RelationKind.manyToMany,
        fromTable: fromTable,
        fromKey: fromKey,
        toTable: toTable,
        toKey: toKey,
        pivotTable: pivotTable,
        pivotFromKey: pivotFromKey,
        pivotToKey: pivotToKey,
        filter: filter,
      );
}

/// A pending eager-load: relation name + optional per-relation query tweak.
class EagerLoad {
  /// Relation name to load.
  final String relation;

  /// Optional tweak applied to the relation's select (filter/order/limit).
  final void Function(SelectQuery q)? constrain;

  /// Creates a pending load of [relation], optionally tweaked by [constrain].
  const EagerLoad(this.relation, [this.constrain]);
}

/// Stores relations keyed by `fromTable` -> `name`.
class RelationRegistry {
  final Map<String, Map<String, Relation>> _byTable = {};

  /// Registers [r], replacing any same-named relation on its table.
  void add(Relation r) {
    _byTable.putIfAbsent(r.fromTable, () => {})[r.name] = r;
  }

  /// Finds the relation [name] declared on [fromTable], if any.
  Relation? lookup(String fromTable, String name) => _byTable[fromTable]?[name];

  /// All relations declared on [fromTable].
  Map<String, Relation> of(String fromTable) =>
      Map.unmodifiable(_byTable[fromTable] ?? {});

  /// Every registered relation, across tables.
  Iterable<Relation> get all => _byTable.values.expand((m) => m.values);
}
