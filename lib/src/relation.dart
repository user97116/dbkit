import 'filter.dart';
import 'query.dart';

/// Relationship kinds.
enum RelationKind { hasOne, hasMany, belongsTo, manyToMany }

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
  final String name;
  final RelationKind kind;
  final String fromTable;
  final String fromKey;
  final String toTable;
  final String toKey;

  /// Pivot table for many-to-many (e.g. `post_tags`).
  final String? pivotTable;
  final String? pivotFromKey;
  final String? pivotToKey;

  /// Optional default ordering / extra filter for eager loads.
  final Condition Function(Where w)? filter;
  final String? orderByColumn;
  final bool orderDesc;
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
  final String relation;
  final void Function(SelectQuery q)? constrain;
  const EagerLoad(this.relation, [this.constrain]);
}

/// Stores relations keyed by `fromTable` -> `name`.
class RelationRegistry {
  final Map<String, Map<String, Relation>> _byTable = {};

  void add(Relation r) {
    _byTable.putIfAbsent(r.fromTable, () => {})[r.name] = r;
  }

  Relation? lookup(String fromTable, String name) =>
      _byTable[fromTable]?[name];

  Map<String, Relation> of(String fromTable) =>
      Map.unmodifiable(_byTable[fromTable] ?? {});

  Iterable<Relation> get all =>
      _byTable.values.expand((m) => m.values);
}
