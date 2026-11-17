// AccountRequestsController with the real repository and ApiClient, talking
// to the fake server. No widgets: a ProviderContainer is Riverpod on its own.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/features/admin/domain/account_request.dart';
import 'package:minechain/features/admin/presentation/account_requests_controller.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart';
import '../../../fakes/fake_controllers.dart';

late FakeAdminServer server;
late ProviderContainer container;

/// A container with [auth] signed in (an administrator by default), the fake
/// server, and the controller kept alive by a listener, as the screen would.
void start({AuthState? auth}) {
  container = ProviderContainer.test(
    retry: noRetry,
    overrides: [
      ...fakeOverrides(FakeAuthController(auth ?? signedInAs(Role.admin))),
      ...server.overrides(),
    ],
  );
  container.listen(accountRequestsControllerProvider, (_, _) {});
}

RequestsState get state => container.read(accountRequestsControllerProvider);
AccountRequestsController get controller =>
    container.read(accountRequestsControllerProvider.notifier);
RequestsLoaded get loaded => state as RequestsLoaded;

/// Lets every pending future finish (the fetch started by build, mock
/// answers, the follow-up refreshes).
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

AccountRequest requestAt(int index) => loaded.requests[index];

void main() {
  setUp(() => server = FakeAdminServer());

  group('loading', () {
    test('starts loading, then shows the pending list', () async {
      start();
      expect(state, isA<RequestsLoading>());

      await settle();

      expect(loaded.requests.map((r) => r.username), [
        'demo_user_1',
        'demo_user_2',
      ]);
      expect(loaded.total, 2);
      expect(loaded.hasMore, isFalse);
      expect(server.lists.single.headers['authorization'], 'Bearer $fakeToken');
    });

    test('no pending requests: an empty list', () async {
      server.pending.clear();
      start();
      await settle();
      expect(loaded.requests, isEmpty);
      expect(loaded.total, 0);
    });

    test('token expired: asks for the password and sends nothing', () async {
      start(auth: SignedInNeedsPassword(userOf(Role.admin)));
      await settle();
      expect(state, isA<RequestsNeedPassword>());
      expect(server.received, isEmpty);
    });

    for (final (name, answer, type) in <(String, Answer, Type)>[
      ('a server fault', (_) => refusal(500, 'INTERNAL_ERROR'), ServerRefused),
      ('an HTML page', (_) => http.Response('<html>', 502), BadResponse),
      ('no connection', (_) => throw http.ClientException('x'), NoConnection),
    ]) {
      test('$name: the failure becomes the state', () async {
        server.listAnswer = answer;
        start();
        await settle();
        expect(state, isA<RequestsFailed>());
        expect((state as RequestsFailed).failure.runtimeType, type);
      });
    }

    test('Try again after a failure loads the list', () async {
      server.listAnswer = (_) => throw http.ClientException('x');
      start();
      await settle();
      server.listAnswer = null;

      await controller.refresh();

      expect(loaded.requests, hasLength(2));
    });

    test('a failed refresh keeps the list and reports the failure', () async {
      start();
      await settle();
      server.listAnswer = (_) => throw http.ClientException('x');

      final failure = await controller.refresh();

      expect(failure, isA<NoConnection>());
      expect(loaded.requests, hasLength(2));
    });

    test('a refresh picks up new requests', () async {
      start();
      await settle();
      server.pending.add(pendingUserJson(3));

      expect(await controller.refresh(), isNull);
      expect(loaded.requests, hasLength(3));
    });
  });

  group('Show more', () {
    setUp(() {
      server = FakeAdminServer([
        for (var n = 1; n <= 25; n++) pendingUserJson(n),
      ]);
    });

    test('the first page is 20 of 25', () async {
      start();
      await settle();
      expect(loaded.requests, hasLength(20));
      expect(loaded.total, 25);
      expect(loaded.hasMore, isTrue);
    });

    test('loads the next page with offset 20 and adds it', () async {
      start();
      await settle();

      expect(await controller.loadMore(), isNull);

      expect(server.lists.last.url.queryParameters['offset'], '20');
      expect(loaded.requests, hasLength(25));
      expect(loaded.hasMore, isFalse);
      expect(loaded.loadingMore, isFalse);
    });

    test('rows already on screen are not added twice', () async {
      start();
      await settle();
      // Someone else approved two of the first page meanwhile, so the next
      // page starts two rows later than expected and overlaps with ours.
      server.pending.removeRange(0, 2);

      await controller.loadMore();

      final ids = loaded.requests.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('a failure keeps the list and is reported', () async {
      start();
      await settle();
      server.listAnswer = (_) => throw http.ClientException('x');

      expect(await controller.loadMore(), isA<NoConnection>());
      expect(loaded.requests, hasLength(20));
      expect(loaded.loadingMore, isFalse);
    });
  });

  group('approve', () {
    test('success: the row leaves only after the server says 200', () async {
      start();
      await settle();
      server.hold = Completer<void>();
      final first = requestAt(0);

      final outcome = controller.approve(first);
      await settle();
      // Waiting for the server: still listed, and marked busy.
      expect(loaded.requests, contains(first));
      expect(loaded.busyId, first.id);

      server.hold!.complete();
      expect(await outcome, isA<RequestActionDone>());
      expect(loaded.requests.map((r) => r.id), isNot(contains(first.id)));
      expect(loaded.total, 1);
      expect(loaded.busyId, isNull);
      expect(
        server.approves.single.url.path,
        '/admin/users/${first.id}/approve',
      );
    });

    test('while one is running, another action is ignored', () async {
      start();
      await settle();
      server.hold = Completer<void>();

      final first = controller.approve(requestAt(0));
      await settle();
      expect(
        await controller.approve(requestAt(1)),
        isA<RequestActionIgnored>(),
      );
      expect(
        await controller.reject(requestAt(1), 'Duplicate request'),
        isA<RequestActionIgnored>(),
      );
      // A refresh would replace the list under the running action.
      expect(await controller.refresh(), isNull);

      server.hold!.complete();
      await first;
      expect(server.approves, hasLength(1));
      expect(server.lists, hasLength(1));
    });

    for (final (status, code) in [
      (409, ApiCodes.invalidStatusTransition),
      (404, ApiCodes.userNotFound),
    ]) {
      test(
        '$status $code: already handled, and the list is fetched again',
        () async {
          start();
          await settle();
          server.approveAnswer = (_) => refusal(status, code);

          expect(
            await controller.approve(requestAt(0)),
            isA<RequestAlreadyHandled>(),
          );
          expect(server.lists, hasLength(2));
          expect(loaded.busyId, isNull);
        },
      );
    }

    for (final (status, code) in [
      (409, ApiCodes.roleNotApprovable),
      (403, ApiCodes.forbidden),
      (500, ApiCodes.internalError),
    ]) {
      test('$status $code: failed, the row stays', () async {
        start();
        await settle();
        server.approveAnswer = (_) => refusal(status, code);
        final first = requestAt(0);

        final outcome = await controller.approve(first);

        expect(outcome, isA<RequestActionFailed>());
        expect(
          ((outcome as RequestActionFailed).failure as ServerRefused).code,
          code,
        );
        expect(loaded.requests, contains(first));
        expect(loaded.busyId, isNull);
        expect(server.lists, hasLength(1)); // not fetched again
      });
    }

    test('no connection: failed, the row stays', () async {
      start();
      await settle();
      server.approveAnswer = (_) => throw http.ClientException('x');

      final outcome = await controller.approve(requestAt(0));

      expect((outcome as RequestActionFailed).failure, isA<NoConnection>());
      expect(loaded.requests, hasLength(2));
    });

    test('token expired: nothing is sent', () async {
      final auth = FakeAuthController(signedInAs(Role.admin));
      container = ProviderContainer.test(
        retry: noRetry,
        overrides: [...fakeOverrides(auth), ...server.overrides()],
      );
      container.listen(accountRequestsControllerProvider, (_, _) {});
      await settle();
      auth.setState(SignedInNeedsPassword(userOf(Role.admin)));

      expect(
        await controller.approve(requestAt(0)),
        isA<RequestNeedsPassword>(),
      );
      expect(server.approves, isEmpty);
    });

    test('approving the last loaded row fetches the rest', () async {
      server = FakeAdminServer([
        for (var n = 1; n <= 21; n++) pendingUserJson(n),
      ]);
      start();
      await settle();
      // Approve the 20 loaded ones; the 21st is still on the server.
      for (var i = 0; i < 20; i++) {
        await controller.approve(requestAt(0));
      }
      await settle();

      expect(loaded.requests.single.username, 'demo_user_21');
      expect(loaded.total, 1);
    });
  });

  group('reject', () {
    test('sends the reason and removes the row', () async {
      start();
      await settle();
      final first = requestAt(0);

      final outcome = await controller.reject(first, 'Duplicate request');

      expect(outcome, isA<RequestActionDone>());
      expect(jsonDecode(server.rejects.single.body), {
        'reason': 'Duplicate request',
      });
      expect(loaded.requests, hasLength(1));
    });

    test("the server's reason error comes back for the field", () async {
      start();
      await settle();
      server.rejectAnswer = (_) => http.Response(
        errorAnswer(ApiCodes.validationFailed, 'Some fields are missing.', [
          {'field': 'reason', 'message': 'must be at least 3 characters'},
        ]),
        400,
      );

      final outcome = await controller.reject(requestAt(0), 'no');

      final failed = outcome as RequestActionFailed;
      expect(failed.fieldErrors, {'reason': 'must be at least 3 characters'});
      expect(loaded.requests, hasLength(2));
    });

    test('409: already handled', () async {
      start();
      await settle();
      server.rejectAnswer = (_) =>
          refusal(409, ApiCodes.invalidStatusTransition);

      expect(
        await controller.reject(requestAt(0), 'Duplicate request'),
        isA<RequestAlreadyHandled>(),
      );
    });
  });

  test('the states print no personal details', () async {
    start();
    await settle();
    final text = state.toString();
    expect(text, isNot(contains('Demo Person')));
    expect(text, isNot(contains('demo_user')));
  });
}
