import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/auth_fixtures.dart';

User parsed(Object? json) => switch (User.fromJson(json)) {
  UserParsed(:final user) => user,
  final other => fail('expected a user, got ${other.runtimeType}'),
};

void main() {
  group('the five roles', () {
    for (final role in Role.values) {
      test(role.name, () {
        expect(parsed(userJson(role: role.name)).role, role);
      });
    }
  });

  test('all fields are read', () {
    final user = parsed(userJson());
    expect(user.id, '3f2b6c1e-0000-4000-8000-000000000001');
    expect(user.username, 'mutale_banda');
    expect(user.fullName, 'Mutale Banda');
    expect(user.licenceNumber, 'ZM-ASM-0042');
    expect(user.status, AccountStatus.active);
    expect(user.createdAt, DateTime.utc(2026, 11, 5, 9));
    expect(user.publicKeyFingerprint, isNull);
  });

  test('every documented status is read', () {
    for (final status in AccountStatus.values) {
      expect(parsed(userJson(status: status.name)).status, status);
    }
  });

  test('an unknown role is "unsupported", never a guess', () {
    expect(
      User.fromJson(userJson(role: 'auditor')),
      isA<UserUnsupportedRole>(),
    );
    // Letter case matters: the API sends lower case only.
    expect(User.fromJson(userJson(role: 'Miner')), isA<UserUnsupportedRole>());
  });

  group('missing or odd fields are refused', () {
    for (final field in [
      'id',
      'username',
      'fullName',
      'licenceNumber',
      'role',
      'status',
      'createdAt',
      'publicKeyFingerprint',
    ]) {
      test('missing $field', () {
        final json = userJson()..remove(field);
        expect(User.fromJson(json), isA<UserMalformed>());
      });
    }

    test('a number where text belongs', () {
      expect(User.fromJson(userJson()..['id'] = 42), isA<UserMalformed>());
    });

    test('an empty username', () {
      expect(
        User.fromJson(userJson()..['username'] = ''),
        isA<UserMalformed>(),
      );
    });

    test('a date that is not a date', () {
      expect(
        User.fromJson(userJson()..['createdAt'] = 'yesterday'),
        isA<UserMalformed>(),
      );
    });

    test('an unknown status', () {
      expect(User.fromJson(userJson(status: 'frozen')), isA<UserMalformed>());
    });

    test('not an object at all', () {
      expect(User.fromJson('mutale'), isA<UserMalformed>());
      expect(User.fromJson(null), isA<UserMalformed>());
    });
  });

  test('toJson reads back as the same user', () {
    final user = parsed(userJson());
    expect(parsed(user.toJson()), user);
  });

  test('toString shows no personal details', () {
    final text = parsed(userJson()).toString();
    expect(text, isNot(contains('Mutale')));
    expect(text, isNot(contains('mutale_banda')));
    expect(text, isNot(contains('ZM-ASM')));
  });
}
