import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/account_request.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/fake_admin_server.dart';

void main() {
  test('reads the fields the screen needs from the admin view', () {
    final request = AccountRequest.fromJson(pendingUserJson(1))!;

    expect(request.id, '3f2b6c1e-0000-4000-8000-000000000101');
    expect(request.username, 'demo_user_1');
    expect(request.fullName, 'Demo Person 1');
    expect(request.licenceNumber, 'ZM-ASM-0042');
    expect(request.role, Role.miner);
    expect(request.requestedAt, DateTime.utc(2026, 11, 5, 9));
  });

  test('a null or empty licence becomes "no licence"', () {
    expect(
      AccountRequest.fromJson(pendingUserJson(1, licenceNumber: null))!
          .licenceNumber,
      isNull,
    );
    expect(
      AccountRequest.fromJson(pendingUserJson(1, licenceNumber: ''))!
          .licenceNumber,
      isNull,
    );
  });

  test('extra fields are ignored', () {
    final json = pendingUserJson(1)..['somethingNew'] = 42;
    expect(AccountRequest.fromJson(json), isNotNull);
  });

  for (final (name, change) in <(String, void Function(Map<String, Object?>))>[
    ('missing id', (j) => j.remove('id')),
    ('empty username', (j) => j['username'] = ''),
    ('numeric full name', (j) => j['fullName'] = 7),
    ('a licence that is not text', (j) => j['licenceNumber'] = 12),
    ('an unknown role', (j) => j['role'] = 'inspector'),
    ('a date that is not a date', (j) => j['createdAt'] = 'yesterday'),
  ]) {
    test('refuses $name', () {
      final json = pendingUserJson(1);
      change(json);
      expect(AccountRequest.fromJson(json), isNull);
    });
  }

  test('refuses something that is not an object', () {
    expect(AccountRequest.fromJson('Demo Person 1'), isNull);
    expect(AccountRequest.fromJson(null), isNull);
  });

  test('toString holds no personal details', () {
    final text = AccountRequest.fromJson(pendingUserJson(1)).toString();
    expect(text, isNot(contains('Demo Person')));
    expect(text, isNot(contains('demo_user')));
    expect(text, isNot(contains('ZM-ASM')));
  });
}
