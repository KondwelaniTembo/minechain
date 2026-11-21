// The "Accounts" calls of AdminUsersApi and AdminUsersRepository against the
// fake accounts server (admin accounts plan, T1): what is sent (path, query,
// token, exact body), and what each answer becomes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/admin/data/admin_users_api.dart';
import 'package:minechain/features/admin/data/admin_users_repository.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_accounts_server.dart';

void main() {
  late FakeAccountsServer server;
  late AdminUsersRepository repository;

  setUp(() {
    server = FakeAccountsServer();
    repository = AdminUsersRepository(
      api: () async => AdminUsersApi(server.apiClient()),
    );
  });

  final miner = accountId(1);

  Map<String, Object?> sentBody(http.Request request) => request.body.isEmpty
      ? {}
      : jsonDecode(request.body) as Map<String, Object?>;

  group('accounts', () {
    test('asks for one status, 20 at a time, with the token', () async {
      final page = await repository.accounts(
        token: fakeToken,
        status: AccountStatus.active,
      );

      final sent = server.lists.single;
      expect(sent.url.path, '/admin/users');
      expect(sent.url.queryParameters, {
        'status': 'active',
        'limit': '20',
        'offset': '0',
      });
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(page.accounts.map((a) => a.username), [
        'mutale_banda',
        'demo_user_1',
        'demo_user_2',
        'demo_user_3',
      ]);
      expect(page.total, 4);
    });

    test('each status by its API name, and the offset', () async {
      for (final status in [
        AccountStatus.suspended,
        AccountStatus.invited,
        AccountStatus.rejected,
        AccountStatus.deleted,
      ]) {
        await repository.accounts(token: fakeToken, status: status, offset: 20);
        expect(server.lists.last.url.queryParameters['status'], status.name);
        expect(server.lists.last.url.queryParameters['offset'], '20');
      }
    });

    test('one unreadable account makes the page unreadable', () async {
      server.accounts.add({...accountJson(9), 'role': 'exporter'});
      expect(
        () =>
            repository.accounts(token: fakeToken, status: AccountStatus.active),
        throwsA(isA<BadResponse>()),
      );
    });

    test('a page without a total is unreadable', () async {
      server.answers['list'] = (_) => json200({'users': []});
      expect(
        () =>
            repository.accounts(token: fakeToken, status: AccountStatus.active),
        throwsA(isA<BadResponse>()),
      );
    });

    test('a pinning set-up failure is an insecure connection', () {
      final broken = AdminUsersRepository(
        api: () async => throw PinningSetupError('no certificates'),
      );
      expect(
        () => broken.accounts(token: fakeToken, status: AccountStatus.active),
        throwsA(isA<InsecureConnection>()),
      );
    });
  });

  group('create', () {
    test('sends exactly username, fullName and role, trimmed', () async {
      final invited = await repository.create(
        token: fakeToken,
        username: '  chanda_mwale ',
        fullName: ' Chanda Mwale  ',
        role: Role.officer,
      );

      final sent = server.creates.single;
      expect(sent.url.path, '/admin/users');
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(sentBody(sent), {
        'username': 'chanda_mwale',
        'fullName': 'Chanda Mwale',
        'role': 'officer',
      });
      expect(invited.account.status, AccountStatus.invited);
      expect(invited.account.username, 'chanda_mwale');
      expect(invited.activation.code, '7KQ4-M2XD-9TNE');
      expect(invited.activation.expiresAt, DateTime.utc(2026, 11, 24, 9));
    });

    test('an administrator account', () async {
      await repository.create(
        token: fakeToken,
        username: 'second_admin',
        fullName: 'Second Admin',
        role: Role.admin,
      );
      expect(sentBody(server.creates.single)['role'], 'admin');
    });

    test('a taken username is refused with USERNAME_TAKEN', () async {
      await expectLater(
        repository.create(
          token: fakeToken,
          username: 'DEMO_USER_1',
          fullName: 'Someone',
          role: Role.officer,
        ),
        throwsA(
          isA<ServerRefused>().having(
            (f) => f.code,
            'code',
            ApiCodes.usernameTaken,
          ),
        ),
      );
    });

    test('an answer without its code is unreadable', () async {
      server.answers['create'] = (_) => http.Response(
        jsonEncode({'user': accountJson(9, status: 'invited')}),
        201,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        repository.create(
          token: fakeToken,
          username: 'chanda_mwale',
          fullName: 'Chanda Mwale',
          role: Role.officer,
        ),
        throwsA(isA<BadResponse>()),
      );
    });
  });

  group('the actions', () {
    test('rename sends exactly { fullName }, trimmed', () async {
      final account = await repository.rename(
        token: fakeToken,
        id: miner,
        fullName: '  Demo Person One ',
      );
      final sent = server.actions('rename').single;
      expect(sent.url.path, '/admin/users/$miner/rename');
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(sentBody(sent), {'fullName': 'Demo Person One'});
      expect(account.fullName, 'Demo Person One');
    });

    test('suspend sends exactly { reason }, trimmed', () async {
      final account = await repository.suspend(
        token: fakeToken,
        id: miner,
        reason: '  Lost device reported  ',
      );
      final sent = server.actions('suspend').single;
      expect(sent.url.path, '/admin/users/$miner/suspend');
      expect(sentBody(sent), {'reason': 'Lost device reported'});
      expect(account.status, AccountStatus.suspended);
      expect(account.statusReason, 'Lost device reported');
    });

    test('reactivate sends no body', () async {
      server.byId(miner)!['status'] = 'suspended';
      final account = await repository.reactivate(token: fakeToken, id: miner);
      final sent = server.actions('reactivate').single;
      expect(sent.url.path, '/admin/users/$miner/reactivate');
      expect(sent.body, isEmpty);
      expect(account.status, AccountStatus.active);
    });

    test('reset-key sends { reason } and the key is gone', () async {
      server.byId(miner)!['status'] = 'suspended';
      final account = await repository.resetKey(
        token: fakeToken,
        id: miner,
        reason: 'Phone replaced ',
      );
      final sent = server.actions('reset-key').single;
      expect(sent.url.path, '/admin/users/$miner/reset-key');
      expect(sentBody(sent), {'reason': 'Phone replaced'});
      expect(account.hasDeviceKey, isFalse);
      expect(account.status, AccountStatus.suspended);
    });

    test('activation-code sends no body and gives a new code', () async {
      final officer = accountId(3);
      server.byId(officer)!['status'] = 'invited';
      final invited = await repository.newActivationCode(
        token: fakeToken,
        id: officer,
      );
      final sent = server.actions('activation-code').single;
      expect(sent.url.path, '/admin/users/$officer/activation-code');
      expect(sent.body, isEmpty);
      expect(invited.activation.code, '7KQ4-M2XD-9TNE');
      expect(invited.account.status, AccountStatus.invited);
    });

    test('delete sends { reason }, trimmed', () async {
      final account = await repository.delete(
        token: fakeToken,
        id: miner,
        reason: ' Left the cooperative ',
      );
      final sent = server.actions('delete').single;
      expect(sent.url.path, '/admin/users/$miner/delete');
      expect(sentBody(sent), {'reason': 'Left the cooperative'});
      expect(account.status, AccountStatus.deleted);
      expect(account.statusReason, 'Left the cooperative');
    });

    test('a 200 whose account is unreadable is an odd answer', () async {
      server.answers['suspend'] = (_) => json200({
        'user': {'id': miner},
      });
      await expectLater(
        repository.suspend(token: fakeToken, id: miner, reason: 'Lost phone'),
        throwsA(isA<BadResponse>()),
      );
    });

    group("the server's refusals reach the caller as they are", () {
      Future<String> codeOf(Future<Object?> Function() call) async {
        try {
          await call();
        } on ServerRefused catch (failure) {
          return failure.code;
        }
        fail('expected a refusal');
      }

      test('suspending yourself', () async {
        expect(
          await codeOf(
            () => repository.suspend(
              token: fakeToken,
              id: ownId,
              reason: 'Testing',
            ),
          ),
          ApiCodes.cannotSuspendSelf,
        );
      });

      test('a key reset on an active account', () async {
        expect(
          await codeOf(
            () => repository.resetKey(
              token: fakeToken,
              id: miner,
              reason: 'Testing',
            ),
          ),
          ApiCodes.invalidStatusTransition,
        );
      });

      test('a key reset with no key', () async {
        final transporter = accountId(2);
        server.byId(transporter)!['status'] = 'suspended';
        expect(
          await codeOf(
            () => repository.resetKey(
              token: fakeToken,
              id: transporter,
              reason: 'Testing',
            ),
          ),
          ApiCodes.noPublicKey,
        );
      });

      test('the last active administrator', () async {
        server.accounts.add(
          accountJson(8, role: 'admin', status: 'active', licenceNumber: null),
        );
        server.byId(ownId)!['status'] = 'suspended';
        expect(
          await codeOf(
            () => repository.delete(
              token: fakeToken,
              id: accountId(8),
              reason: 'Testing',
            ),
          ),
          ApiCodes.lastActiveAdmin,
        );
      });

      test('an account that does not exist', () async {
        expect(
          await codeOf(
            () => repository.reactivate(
              token: fakeToken,
              id: '3f2b6c1e-0000-4000-8000-999999999999',
            ),
          ),
          ApiCodes.userNotFound,
        );
      });
    });
  });
}
