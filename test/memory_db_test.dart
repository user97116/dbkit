import 'package:test/test.dart';
import 'package:dbkit/dbkit.dart';

/// Full Table API exercised against the pure-Dart fake (no native libs).
void main() {
  late Db db;

  setUp(() {
    db = Db.fake();
  });

  test('insert / selectAll / findById / count / exists / pluck', () async {
    final users = db.table('users');
    await users.insert({'name': 'Ada', 'age': 36});
    await users.insert({'name': 'Bob', 'age': 15});
    await users.insertMany([
      {'name': 'Cid', 'age': 22},
      {'name': 'Dee', 'age': 41},
    ]);

    expect(await users.count(), 4);
    expect(await users.existsWhere((w) => w.eq('name', 'Ada')), isTrue);
    expect(await users.existsWhere((w) => w.eq('name', 'Zed')), isFalse);

    final all = await users.selectAll(orderBy: 'age');
    expect(all.map((r) => r['name']), ['Bob', 'Cid', 'Ada', 'Dee']);

    final ada = await users.findOneWhere((w) => w.eq('name', 'Ada'));
    expect(ada!['age'], 36);

    final byId = await users.findById(ada['id']!);
    expect(byId!['name'], 'Ada');

    final names = await users.pluck<String>('name');
    expect(names.toSet(), {'Ada', 'Bob', 'Cid', 'Dee'});
  });

  test('where chaining, orWhere, order, limit, page', () async {
    final users = db.table('users');
    for (var i = 0; i < 10; i++) {
      await users.insert({'name': 'u$i', 'age': 10 + i});
    }

    final adults =
        await users.where((w) => w.gte('age', 15)).orderBy('age').get();
    expect(adults.length, 5);
    expect(adults.first['age'], 15);

    final either = await users
        .query()
        .where((w) => w.lt('age', 12))
        .orWhere((w) => w.gt('age', 17))
        .orderBy('age')
        .get();
    expect(either.map((r) => r['age']), [10, 11, 18, 19]);

    final page1 = await users.query().orderBy('age').page(1, 3).get();
    // page helper returns rows directly via TableQuery.page().get()
    expect(page1.length, 3);

    final p = await users.query().orderBy('age').paginate(page: 2, perPage: 4);
    expect(p.items.length, 4);
    expect(p.total, 10);
    expect(p.totalPages, 3);
    expect(p.hasNext, isTrue);
  });

  test('update / delete / increment', () async {
    final users = db.table('users');
    final id = await users.insert({'name': 'Ada', 'age': 36});
    await users.updateById(id, {'age': 37});
    expect((await users.findById(id))!['age'], 37);

    await users.insert({'name': 'Kid', 'age': 10});
    final n =
        await users.updateWhere((w) => w.lt('age', 18), {'active': false});
    expect(n, 1);

    await users.increment('age', where: (w) => w.eq('name', 'Ada'));
    expect((await users.findById(id))!['age'], 38);

    await users.deleteWhere((w) => w.eq('name', 'Kid'));
    expect(await users.count(), 1);

    await users.deleteById(id);
    expect(await users.count(), 0);
  });

  test('upsert inserts then updates', () async {
    final users = db.table('users');
    await users.upsert({'id': 1, 'name': 'Ada', 'age': 36});
    await users.upsert({'id': 1, 'name': 'Ada Updated', 'age': 37});
    final row = await users.findById(1);
    expect(row!['name'], 'Ada Updated');
    expect(row['age'], 37);
    expect(await users.count(), 1);
  });

  test('transaction rolls back on error', () async {
    final users = db.table('users');
    await expectLater(db.transaction((tx) async {
      await tx.table('users').insert({'name': 'Ada'});
      throw Exception('boom');
    }), throwsException);
    expect(await users.count(), 0);
  });

  test('distinct + whereIn + between + like', () async {
    final t = db.table('items');
    await t.insertMany([
      {'cat': 'a', 'price': 10, 'name': 'apple'},
      {'cat': 'a', 'price': 20, 'name': 'apricot'},
      {'cat': 'b', 'price': 30, 'name': 'banana'},
    ]);
    final cats =
        await t.query().select(['cat']).distinct().orderBy('cat').get();
    expect(cats.length, 2);

    final inRes = await t.where((w) => w.inList('cat', ['a'])).get();
    expect(inRes.length, 2);

    final btw = await t.where((w) => w.between('price', 15, 25)).get();
    expect(btw.length, 1);
    expect(btw.first['name'], 'apricot');

    final like = await t.where((w) => w.like('name', 'ap%')).get();
    expect(like.length, 2);
  });

  test('contains / startsWith / endsWith without wildcards', () async {
    final t = db.table('items');
    await t.insertMany([
      {'name': 'apple'},
      {'name': 'apricot'},
      {'name': 'banana'},
      {'name': '100% juice'},
    ]);

    expect((await t.whereContains('name', 'ap').get()).length, 2);
    expect(
        await t.where((w) => w.startsWith('name', 'ap')).pluck<String>('name'),
        ['apple', 'apricot']);
    expect((await t.whereEndsWith('name', 'ana').get()).length, 1);

    // literal % in the search text matches only the real % row
    final pct = await t.where((w) => w.contains('name', '100%')).get();
    expect(pct.length, 1);
    expect(pct.first['name'], '100% juice');

    // negations
    expect((await t.where((w) => w.notContains('name', 'ap')).get()).length, 2);
  });
}
