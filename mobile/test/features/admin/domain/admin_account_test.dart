// AdminAccount, ActivationCode and InvitedAccount read from api.md's
// examples (admin accounts plan, T1).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/admin_account.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/fake_accounts_server.dart';

void main() {
  group('AdminAccount.fromJson', () {
    test("reads every field the pages show from api.md's approve example", () {
      final account = AdminAccount.fromJson({
        'id': '3f2b6c1e-0000-4000-8000-000000000001',
        'username': 'mutale_banda',
        'fullName': 'Mutale Banda',
        'licenceNumber': 'ZM-ASM-0042',
        'role': 'miner',
        'status': 'active',
        'statusReason': null,
        'approvedBy': '3f2b6c1e-0000-4000-8000-0000000000ad',
        'approvedAt': '2026-11-06T10:15:00.000Z',
        'createdAt': '2026-11-05T09:00:00.000Z',
        'updatedAt': '2026-11-06T10:15:00.000Z',
        'publicKeyFingerprint': null,
        'activationExpiresAt': null,
      })!;

      expect(account.id, '3f2b6c1e-0000-4000-8000-000000000001');
      expect(account.username, 'mutale_banda');
      expect(account.fullName, 'Mutale Banda');
      expect(account.licenceNumber, 'ZM-ASM-0042');
      expect(account.role, Role.miner);
      expect(account.status, AccountStatus.active);
      expect(account.statusReason, isNull);
      expect(account.approvedAt, DateTime.utc(2026, 11, 6, 10, 15));
      expect(account.createdAt, DateTime.utc(2026, 11, 5, 9));
      expect(account.publicKeyFingerprint, isNull);
      expect(account.hasDeviceKey, isFalse);
      expect(account.activationExpiresAt, isNull);
    });

    test("api.md's created officer: invited, with the code's expiry", () {
      final account = AdminAccount.fromJson(
        accountJson(
          1,
          role: 'officer',
          status: 'invited',
          licenceNumber: null,
          approvedAt: null,
          activationExpiresAt: '2026-11-14T09:00:00.000Z',
        ),
      )!;
      expect(account.status, AccountStatus.invited);
      expect(account.role, Role.officer);
      expect(account.licenceNumber, isNull);
      expect(account.approvedAt, isNull);
      expect(account.activationExpiresAt, DateTime.utc(2026, 11, 14, 9));
    });

    test('an invited account whose code was erased has no expiry', () {
      final account = AdminAccount.fromJson(
        accountJson(1, role: 'officer', status: 'invited'),
      )!;
      expect(account.activationExpiresAt, isNull);
    });

    test('a suspended account with its reason and key', () {
      final account = AdminAccount.fromJson(
        accountJson(
          1,
          status: 'suspended',
          statusReason: 'Lost device reported',
          fingerprint: fakeFingerprint,
        ),
      )!;
      expect(account.status, AccountStatus.suspended);
      expect(account.statusReason, 'Lost device reported');
      expect(account.publicKeyFingerprint, fakeFingerprint);
      expect(account.hasDeviceKey, isTrue);
    });

    test('every status the list can show is read', () {
      for (final status in AccountStatus.values) {
        expect(
          AdminAccount.fromJson(accountJson(1, status: status.name))?.status,
          status,
        );
      }
    });

    test('empty optional strings are read as none', () {
      final account = AdminAccount.fromJson({
        ...accountJson(1),
        'licenceNumber': '',
        'statusReason': '',
        'publicKeyFingerprint': '',
      })!;
      expect(account.licenceNumber, isNull);
      expect(account.statusReason, isNull);
      expect(account.publicKeyFingerprint, isNull);
    });

    test('extra fields are ignored', () {
      expect(
        AdminAccount.fromJson({...accountJson(1), 'somethingNew': 42}),
        isNotNull,
      );
    });

    group('anything unreadable gives null', () {
      final cases = <String, Map<String, Object?>>{
        'no id': {...accountJson(1)}..remove('id'),
        'empty username': {...accountJson(1), 'username': ''},
        'a number as name': {...accountJson(1), 'fullName': 7},
        'an unknown role': {...accountJson(1), 'role': 'exporter'},
        'an unknown status': {...accountJson(1), 'status': 'archived'},
        'a bad createdAt': {...accountJson(1), 'createdAt': 'yesterday'},
        'a bad approvedAt': {...accountJson(1), 'approvedAt': 'soon'},
        'a bad expiry': {...accountJson(1), 'activationExpiresAt': 'x'},
        'a number as reason': {...accountJson(1), 'statusReason': 3},
        'a list as fingerprint': {
          ...accountJson(1),
          'publicKeyFingerprint': <String>[],
        },
      };
      cases.forEach((name, json) {
        test(name, () => expect(AdminAccount.fromJson(json), isNull));
      });
      test('not a map', () {
        expect(AdminAccount.fromJson('account'), isNull);
        expect(AdminAccount.fromJson(null), isNull);
      });
    });

    test('toString names only the role and status', () {
      final text = AdminAccount.fromJson(
        accountJson(1, statusReason: 'Lost device reported'),
      ).toString();
      expect(text, 'AdminAccount(role: miner, status: active)');
      expect(text, isNot(contains('demo_user_1')));
      expect(text, isNot(contains('Demo Person')));
      expect(text, isNot(contains('ZM-ASM')));
    });
  });

  group('ActivationCode', () {
    test("reads api.md's activation", () {
      final code = ActivationCode.fromJson({
        'code': '7KQ4-M2XD-9TNE',
        'expiresAt': '2026-11-14T09:00:00.000Z',
      })!;
      expect(code.code, '7KQ4-M2XD-9TNE');
      expect(code.expiresAt, DateTime.utc(2026, 11, 14, 9));
    });

    test('unreadable gives null', () {
      expect(ActivationCode.fromJson(null), isNull);
      expect(
        ActivationCode.fromJson({'code': '', 'expiresAt': '2026-11-14'}),
        isNull,
      );
      expect(
        ActivationCode.fromJson({'code': 'ABC', 'expiresAt': 'later'}),
        isNull,
      );
      expect(ActivationCode.fromJson({'code': 1, 'expiresAt': 2}), isNull);
    });

    test('the code is never in toString', () {
      final code = ActivationCode(
        code: '7KQ4-M2XD-9TNE',
        expiresAt: DateTime.utc(2026, 11, 14, 9),
      );
      expect(code.toString(), isNot(contains('7KQ4')));
      final invited = InvitedAccount(
        account: AdminAccount.fromJson(accountJson(1, status: 'invited'))!,
        activation: code,
      );
      expect(invited.toString(), isNot(contains('7KQ4')));
      expect(invited.toString(), isNot(contains('demo_user_1')));
    });
  });
}
