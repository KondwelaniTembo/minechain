import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/auth/data/session_store.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_secure_store.dart';

final now = DateTime.utc(2026, 11, 16, 9);
final user = (User.fromJson(userJson()) as UserParsed).user;

void main() {
  late FakeSecureStore store;
  late SessionStore session;

  setUp(() {
    store = FakeSecureStore();
    session = SessionStore(store, clock: () => now);
  });

  test('saves exactly the three keys, and reads them back', () async {
    await session.save(user: user, token: fakeToken, expiresIn: 3600);

    expect(store.values.keys.toSet(), SessionKeys.all.toSet());
    final read = await session.read();
    expect(read, isA<StoredSession>());
    final saved = read as StoredSession;
    expect(saved.user, user);
    expect(saved.token, fakeToken);
  });

  test('expiry = login time + expiresIn - 60 s', () async {
    final expiresAt = await session.save(
      user: user,
      token: fakeToken,
      expiresIn: 3600,
    );
    final expected = now.add(const Duration(seconds: 3600 - 60));
    expect(expiresAt, expected);
    expect(store.values[SessionKeys.expiresAt], expected.toIso8601String());
    expect((await session.read() as StoredSession).expiresAt, expected);
  });

  test('clear() removes the session keys and leaves any other key', () async {
    store.values['db.key'] = 'unrelated secret';
    await session.save(user: user, token: fakeToken, expiresIn: 3600);

    await session.clear();

    expect(store.values, {'db.key': 'unrelated secret'});
  });

  test('forgetToken() keeps the user', () async {
    await session.save(user: user, token: fakeToken, expiresIn: 3600);
    await session.forgetToken();

    expect(store.values.keys, [SessionKeys.user]);
    final read = await session.read() as StoredSession;
    expect(read.user, user);
    expect(read.token, isNull);
  });

  test('nothing saved -> no session', () async {
    expect(await session.read(), isA<NoStoredSession>());
  });

  test('broken user JSON -> no session, and the keys are cleared', () async {
    store.values.addAll({
      SessionKeys.user: '{not json',
      SessionKeys.token: fakeToken,
      SessionKeys.expiresAt: now.toIso8601String(),
      'db.key': 'unrelated secret',
    });

    expect(await session.read(), isA<NoStoredSession>());
    expect(store.values, {'db.key': 'unrelated secret'});
  });

  test('a user JSON with a field missing -> no session, keys cleared', () async {
    store.values[SessionKeys.user] = jsonEncode(userJson()..remove('role'));
    expect(await session.read(), isA<NoStoredSession>());
    expect(store.values, isEmpty);
  });

  test('a saved user with an unknown role -> unsupported, keys cleared', () async {
    store.values[SessionKeys.user] = jsonEncode(userJson(role: 'auditor'));
    store.values[SessionKeys.token] = fakeToken;
    expect(await session.read(), isA<UnsupportedStoredSession>());
    expect(store.values, isEmpty);
  });

  test('a token without its expiry is forgotten, the user kept', () async {
    store.values[SessionKeys.user] = jsonEncode(userJson());
    store.values[SessionKeys.token] = fakeToken;

    final read = await session.read() as StoredSession;
    expect(read.token, isNull);
    expect(store.values.keys, [SessionKeys.user]);
  });

  test('an unreadable expiry is treated the same way', () async {
    store.values[SessionKeys.user] = jsonEncode(userJson());
    store.values[SessionKeys.token] = fakeToken;
    store.values[SessionKeys.expiresAt] = 'soon';

    final read = await session.read() as StoredSession;
    expect(read.token, isNull);
    expect(read.expiresAt, isNull);
  });

  test('a token with no user is tidied away', () async {
    store.values[SessionKeys.token] = fakeToken;
    expect(await session.read(), isA<NoStoredSession>());
    expect(store.values, isEmpty);
  });

  test('a store that cannot be read -> no session', () async {
    await session.save(user: user, token: fakeToken, expiresIn: 3600);
    store.failReads = true;
    expect(await session.read(), isA<NoStoredSession>());
  });
}
