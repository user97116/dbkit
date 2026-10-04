import 'package:dbkit/dbkit.dart';

part 'models.g.dart';

/// Blog models for the code generator demo + runtime tests.
///
/// Regenerate after editing:
/// `dart run build_runner build`
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

  User copyWith({int? id, String? name, int? age}) => User(
        id: id ?? this.id,
        name: name ?? this.name,
        age: age ?? this.age,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User && other.id == id && other.name == name && other.age == age;

  @override
  int get hashCode => Object.hash(id, name, age);

  @override
  String toString() => 'User(id: $id, name: $name, age: $age)';
}

@DbTable('profiles')
class Profile {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id', references: 'users')
  final int userId;
  final String? bio;

  const Profile({this.id, required this.userId, this.bio});

  factory Profile.fromMap(Map<String, Object?> map) => _$ProfileFromMap(map);
  Map<String, Object?> toMap() => _$ProfileToMap(this);
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
  @DbColumn(defaultValue: false)
  final bool published;

  const Post(
      {this.id,
      required this.userId,
      required this.title,
      this.published = false});

  factory Post.fromMap(Map<String, Object?> map) => _$PostFromMap(map);
  Map<String, Object?> toMap() => _$PostToMap(this);
}

@DbTable('tags')
class Tag {
  @DbId()
  final int? id;
  @DbColumn(unique: true)
  final String label;

  const Tag({this.id, required this.label});

  factory Tag.fromMap(Map<String, Object?> map) => _$TagFromMap(map);
  Map<String, Object?> toMap() => _$TagToMap(this);
}

@DbTable('post_tags')
class PostTag {
  @DbId()
  final int? id;
  @DbColumn(name: 'post_id', references: 'posts')
  final int postId;
  @DbColumn(name: 'tag_id', references: 'tags')
  final int tagId;

  const PostTag({this.id, required this.postId, required this.tagId});

  factory PostTag.fromMap(Map<String, Object?> map) => _$PostTagFromMap(map);
  Map<String, Object?> toMap() => _$PostTagToMap(this);
}
