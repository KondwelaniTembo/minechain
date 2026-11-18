// AdminUsersApi and AdminUsersRepository against the fake server: what is
// sent (path, query, token, body), and what each answer becomes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/admin/data/admin_users_api.dart';
import 'package:minechain/features/admin/data/admin_users_repository.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart';

void main() {
  late FakeAdminServer server;
  late AdminUsersRepository repository;

  setUp(() {
    server = FakeAdminServer();
    repository = AdminUsersRepository(
      api: () async => AdminUsersApi(server.apiClient()),
    );
  });

  const id = '3f2b6c1e-0000-4000-8000-000000000101';

  group('pendingRequests', () {
    test('asks for pending accounts, 20 at a time, with the token', () async {
      final page = await repository.pendingRequests(token: fakeToken);

      final sent = server.lists.single;
      expect(sent.url.path, '/admin/users');
      expect(sent.url.queryParameters, {
        'status': 'pending',
        'limit': '20',
        'offset': '0',
      });
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(page.requests.map((r) => r.username), [
        'demo_user_1',
        'demo_user_2',
      ]);
      expect(page.total, 2);
    });

    test('passes the offset for the next page', () async {
      await repository.pendingRequests(token: fakeToken, offset: 20);
      expect(server.lists.single.url.queryParameters['offset'], '20');
    });

    for (final (name, body) in <(String, Object)>[
      ('no users list', {'total': 1}),
      ('no total', {'users': <Object>[]}),
      ('a negative total', {'users': <Object>[], 'total': -1}),
      ('a list that is not one', 'users'),
      (
        'one unreadable user',
        {
          'users': [
            pendingUserJson(1),
            {'id': 'x'},
          ],
          'total': 2,
        },
      ),
    ]) {
      test('$name -> BadResponse', () async {
        server.listAnswer = (_) => json200(body);
        await expectLater(
          repository.pendingRequests(token: fakeToken),
          throwsA(isA<BadResponse>()),
        );
      });
    }

    test('a refusal comes through as ServerRefused', () async {
      server.listAnswer = (_) => refusal(403, 'FORBIDDEN');
      await expectLater(
        repository.pendingRequests(token: fakeToken),
        throwsA(
          isA<ServerRefused>().having((f) => f.code, 'code', 'FORBIDDEN'),
        ),
      );
    });
  });

  group('approve', () {
    test('POSTs to /admin/users/{id}/approve with no body', () async {
      await repository.approve(token: fakeToken, id: id);

      final sent = server.approves.single;
      expect(sent.method, 'POST');
      expect(sent.url.path, '/admin/users/$id/approve');
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      // "None, or {}. Any field is refused."
      expect(sent.body, isEmpty);
      expect(sent.headers.containsKey('content-type'), isFalse);
    });

    test('409 INVALID_STATUS_TRANSITION comes through', () async {
      server.approveAnswer = (_) => refusal(409, 'INVALID_STATUS_TRANSITION');
      await expectLater(
        repository.approve(token: fakeToken, id: id),
        throwsA(
          isA<ServerRefused>().having(
            (f) => f.code,
            'code',
            'INVALID_STATUS_TRANSITION',
          ),
        ),
      );
    });
  });

  group('reject', () {
    test('POSTs the reason, trimmed, and nothing else', () async {
      await repository.reject(
        token: fakeToken,
        id: id,
        reason: '  Licence number could not be verified \n',
      );

      final sent = server.rejects.single;
      expect(sent.url.path, '/admin/users/$id/reject');
      expect(jsonDecode(sent.body), {
        'reason': 'Licence number could not be verified',
      });
    });
  });

  test('a pinning set-up failure becomes InsecureConnection', () async {
    final broken = AdminUsersRepository(
      api: () async => throw PinningSetupError('test'),
    );
    await expectLater(
      broken.pendingRequests(token: fakeToken),
      throwsA(isA<InsecureConnection>()),
    );
    await expectLater(
      broken.approve(token: fakeToken, id: id),
      throwsA(isA<InsecureConnection>()),
    );
  });

  test('no connection becomes NoConnection', () async {
    server.listAnswer = (_) => throw http.ClientException('offline');
    await expectLater(
      repository.pendingRequests(token: fakeToken),
      throwsA(isA<NoConnection>()),
    );
  });
}
