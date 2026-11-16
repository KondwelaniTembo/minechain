// AuthController and AuthRepository together, against a pretend server
// (MockClient), an in-memory secure store and a fixed clock.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/storage/secure_store.dart';
import 'package:minechain/features/auth/data/session_store.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_secure_store.dart';

final now = DateTime.utc(2026, 11, 16, 9);

/// A pretend server. [onLogin] and [onMe] answer the two endpoints; anything
/// else is a 404. [requests] records what was asked, in order.
class FakeServer {
  FakeServer({
    Future<http.Response> Function(http.Request)? onLogin,
    Future<http.Response> Function(http.Request)? onMe,
  }) : onLogin = onLogin ?? ((_) async => http.Response(loginAnswer(), 200)),
       onMe = onMe ?? ((_) async => http.Response(meAnswer(), 200));

  Future<http.Response> Function(http.Request) onLogin;
  Future<http.Response> Function(http.Request) onMe;
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) {
    requests.add(request);
    return switch (request.url.path) {
      '/auth/login' => onLogin(request),
      '/auth/me' => onMe(request),
      _ => Future.value(http.Response(errorAnswer('NOT_FOUND'), 404)),
    };
  });
}

class Harness {
  Harness({FakeServer? server, FakeSecureStore? store, DateTime? at})
    : server = server ?? FakeServer(),
      store = store ?? FakeSecureStore() {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        secureStoreProvider.overrideWithValue(this.store),
        clockProvider.overrideWithValue(() => at ?? now),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            client: this.server.client,
            baseUri: Uri.parse('https://api.example.test'),
            sessionEvents: ref.watch(sessionEventsProvider),
            delay: (_) => Completer<void>().future, // never times out
          ),
        ),
      ],
    );
  }

  final FakeServer server;
  final FakeSecureStore store;
  late final ProviderContainer container;

  AuthController get auth => container.read(authControllerProvider.notifier);
  AuthState get state => container.read(authControllerProvider);
  void announce(String code) =>
      container.read(sessionEventsProvider).report(code);
}

/// Lets background work (the refresh after restore, stream events) finish.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Saves a session as an earlier run of the app would have.
void saveSession(
  FakeSecureStore store, {
  Map<String, Object?>? user,
  String token = fakeToken,
  required DateTime expiresAt,
}) {
  store.values[SessionKeys.user] = jsonEncode(user ?? userJson());
  store.values[SessionKeys.token] = token;
  store.values[SessionKeys.expiresAt] = expiresAt.toIso8601String();
}

void main() {
  group('logIn', () {
    test('success -> SignedIn, saved, and announced', () async {
      final h = Harness();
      await h.auth.restore();
      final announced = <User>[];
      h.container.read(signedInEventsProvider).users.listen(announced.add);

      final outcome = await h.auth.logIn('mutale_banda', fakePassword);

      expect(outcome, isA<LoginSucceeded>());
      final state = h.state as SignedIn;
      expect(state.token, fakeToken);
      expect(state.user.username, 'mutale_banda');
      expect(state.expiresAt, now.add(const Duration(seconds: 3540)));
      expect(h.store.values.keys.toSet(), SessionKeys.all.toSet());
      await settle();
      expect(announced, hasLength(1));
    });

    test('the password is sent once and never saved', () async {
      final h = Harness();
      await h.auth.logIn('mutale_banda', fakePassword);

      final sent = jsonDecode(h.server.requests.single.body) as Map;
      expect(sent, {'username': 'mutale_banda', 'password': fakePassword});
      for (final value in h.store.values.values) {
        expect(value, isNot(contains(fakePassword)));
      }
    });

    test('INVALID_CREDENTIALS -> failure returned, still signed out, '
        'nothing saved', () async {
      final h = Harness(
        server: FakeServer(
          onLogin: (_) async =>
              http.Response(errorAnswer(ApiCodes.invalidCredentials), 401),
        ),
      );
      await h.auth.restore();

      final outcome = await h.auth.logIn('mutale_banda', 'wrong password');

      expect(
        outcome,
        isA<LoginFailed>().having(
          (o) => o.failure,
          'failure',
          isA<ServerRefused>().having(
            (f) => f.code,
            'code',
            ApiCodes.invalidCredentials,
          ),
        ),
      );
      expect(h.state, isA<SignedOut>());
      expect(h.store.values, isEmpty);
    });

    test('no network -> NoConnection returned', () async {
      final h = Harness(
        server: FakeServer(
          onLogin: (_) async => throw http.ClientException('offline'),
        ),
      );
      final outcome = await h.auth.logIn('mutale_banda', fakePassword);
      expect(
        outcome,
        isA<LoginFailed>().having((o) => o.failure, 'f', isA<NoConnection>()),
      );
    });

    test('an account with an unknown role -> not possible, nothing saved',
        () async {
      final h = Harness(
        server: FakeServer(
          onLogin: (_) async =>
              http.Response(loginAnswer(user: userJson(role: 'auditor')), 200),
        ),
      );
      final outcome = await h.auth.logIn('mutale_banda', fakePassword);
      expect(outcome, isA<LoginNotPossible>());
      expect(
        h.state,
        isA<SignedOut>().having(
          (s) => s.reason,
          'reason',
          AuthReasons.unsupportedRole,
        ),
      );
      expect(h.store.values, isEmpty);
    });

    test('a second logIn while one runs is ignored', () async {
      final answer = Completer<http.Response>();
      final h = Harness(server: FakeServer(onLogin: (_) => answer.future));

      final first = h.auth.logIn('mutale_banda', fakePassword);
      final second = await h.auth.logIn('mutale_banda', fakePassword);
      answer.complete(http.Response(loginAnswer(), 200));

      expect(second, isA<LoginIgnored>());
      expect(await first, isA<LoginSucceeded>());
      expect(h.server.requests, hasLength(1));
    });
  });

  group('restore at start-up', () {
    test('nothing saved -> SignedOut', () async {
      final h = Harness();
      expect(h.state, isA<AuthUnknown>());
      await h.auth.restore();
      expect(h.state, isA<SignedOut>());
      expect(h.server.requests, isEmpty);
    });

    test('a valid token -> SignedIn at once, then the user is refreshed',
        () async {
      final h = Harness(
        server: FakeServer(
          onMe: (_) async => http.Response(
            meAnswer(user: userJson(fullName: 'Mutale K. Banda')),
            200,
          ),
        ),
      );
      saveSession(h.store, expiresAt: now.add(const Duration(minutes: 30)));

      await h.auth.restore();
      expect(h.state, isA<SignedIn>());
      expect((h.state as SignedIn).user.fullName, 'Mutale Banda');

      await settle();
      expect((h.state as SignedIn).user.fullName, 'Mutale K. Banda');
      expect(h.server.requests.single.headers['authorization'],
          'Bearer $fakeToken');
    });

    test('the refresh failing (no network) keeps the session', () async {
      final h = Harness(
        server: FakeServer(
          onMe: (_) async => throw http.ClientException('offline'),
        ),
      );
      saveSession(h.store, expiresAt: now.add(const Duration(minutes: 30)));
      await h.auth.restore();
      await settle();
      expect(h.state, isA<SignedIn>());
    });

    test('an expired token -> needs password, token forgotten, user kept',
        () async {
      final h = Harness();
      saveSession(h.store, expiresAt: now.subtract(const Duration(minutes: 1)));

      await h.auth.restore();

      expect(h.state, isA<SignedInNeedsPassword>());
      expect(h.store.values.keys, [SessionKeys.user]);
      expect(h.server.requests, isEmpty);
    });

    test('a saved user with an unknown role -> SignedOut with the reason',
        () async {
      final h = Harness();
      saveSession(
        h.store,
        user: userJson(role: 'auditor'),
        expiresAt: now.add(const Duration(minutes: 30)),
      );

      await h.auth.restore();

      expect(
        h.state,
        isA<SignedOut>().having(
          (s) => s.reason,
          'reason',
          AuthReasons.unsupportedRole,
        ),
      );
      expect(h.store.values, isEmpty);
    });

    test('the refresh answered 401 TOKEN_INVALID -> full logout', () async {
      final h = Harness(
        server: FakeServer(
          onMe: (_) async =>
              http.Response(errorAnswer(ApiCodes.tokenInvalid), 401),
        ),
      );
      saveSession(h.store, expiresAt: now.add(const Duration(minutes: 30)));

      await h.auth.restore();
      await settle();

      expect(
        h.state,
        isA<SignedOut>().having((s) => s.reason, 'r', ApiCodes.tokenInvalid),
      );
      expect(h.store.values, isEmpty);
    });
  });

  group('the server refusing the session (SessionEvents)', () {
    Future<Harness> signedIn() async {
      final h = Harness();
      h.store.values['db.key'] = 'unrelated secret';
      await h.auth.logIn('mutale_banda', fakePassword);
      expect(h.state, isA<SignedIn>());
      return h;
    }

    test('TOKEN_EXPIRED -> needs password, user kept, token cleared',
        () async {
      final h = await signedIn();
      h.announce(ApiCodes.tokenExpired);
      await settle();

      expect(
        h.state,
        isA<SignedInNeedsPassword>().having(
          (s) => s.user.username,
          'username',
          'mutale_banda',
        ),
      );
      expect(h.store.values.keys.toSet(), {SessionKeys.user, 'db.key'});
    });

    for (final code in [
      ApiCodes.tokenInvalid,
      ApiCodes.tokenMissing,
      ApiCodes.accountPending,
      ApiCodes.accountSuspended,
      ApiCodes.accountRejected,
      ApiCodes.accountNotActive,
    ]) {
      test('$code -> full logout with that reason', () async {
        final h = await signedIn();
        h.announce(code);
        await settle();

        expect(h.state, isA<SignedOut>().having((s) => s.reason, 'r', code));
        expect(h.store.values, {'db.key': 'unrelated secret'});
      });
    }

    test('FORBIDDEN changes nothing', () async {
      final h = await signedIn();
      final before = h.state;
      h.announce(ApiCodes.forbidden);
      await settle();
      expect(h.state, same(before));
      expect(h.store.values.keys.toSet(), {...SessionKeys.all, 'db.key'});
    });

    test('while signed out, a late refusal changes nothing', () async {
      final h = Harness();
      await h.auth.restore();
      h.announce(ApiCodes.tokenInvalid);
      await settle();
      expect(h.state, isA<SignedOut>().having((s) => s.reason, 'r', isNull));
    });
  });

  group('reauthenticate', () {
    Future<Harness> needingPassword({FakeServer? server}) async {
      final h = Harness(server: server);
      saveSession(h.store, expiresAt: now.subtract(const Duration(minutes: 1)));
      await h.auth.restore();
      expect(h.state, isA<SignedInNeedsPassword>());
      return h;
    }

    test('success -> SignedIn, using the saved username', () async {
      final h = await needingPassword();

      final outcome = await h.auth.reauthenticate(fakePassword);

      expect(outcome, isA<LoginSucceeded>());
      expect(h.state, isA<SignedIn>());
      final sent = jsonDecode(h.server.requests.single.body) as Map;
      expect(sent['username'], 'mutale_banda');
    });

    test('a wrong password -> still needs password, failure returned',
        () async {
      final h = await needingPassword(
        server: FakeServer(
          onLogin: (_) async =>
              http.Response(errorAnswer(ApiCodes.invalidCredentials), 401),
        ),
      );
      expect(await h.auth.reauthenticate('wrong'), isA<LoginFailed>());
      expect(h.state, isA<SignedInNeedsPassword>());
    });

    test('a suspended account (403 at login) -> full logout', () async {
      final h = await needingPassword(
        server: FakeServer(
          onLogin: (_) async =>
              http.Response(errorAnswer(ApiCodes.accountSuspended), 403),
        ),
      );
      expect(await h.auth.reauthenticate(fakePassword), isA<LoginFailed>());
      expect(
        h.state,
        isA<SignedOut>().having(
          (s) => s.reason,
          'r',
          ApiCodes.accountSuspended,
        ),
      );
    });

    test('an answer for a different account -> signed out', () async {
      final h = await needingPassword(
        server: FakeServer(
          onLogin: (_) async => http.Response(
            loginAnswer(
              user: userJson(id: '3f2b6c1e-0000-4000-8000-000000000009'),
            ),
            200,
          ),
        ),
      );
      expect(
        await h.auth.reauthenticate(fakePassword),
        isA<LoginNotPossible>(),
      );
      expect(
        h.state,
        isA<SignedOut>().having(
          (s) => s.reason,
          'r',
          AuthReasons.accountChanged,
        ),
      );
      expect(h.store.values, isEmpty);
    });

    test('when not asked for, it does nothing', () async {
      final h = Harness();
      await h.auth.restore();
      expect(await h.auth.reauthenticate(fakePassword), isA<LoginIgnored>());
      expect(h.server.requests, isEmpty);
    });
  });

  test('logOut clears only the session keys', () async {
    final h = Harness();
    h.store.values['db.key'] = 'unrelated secret';
    await h.auth.logIn('mutale_banda', fakePassword);

    await h.auth.logOut();

    expect(h.state, isA<SignedOut>().having((s) => s.reason, 'r', isNull));
    expect(h.store.values, {'db.key': 'unrelated secret'});
  });

  test('a broken store at start-up -> SignedOut', () async {
    final h = Harness();
    saveSession(h.store, expiresAt: now.add(const Duration(minutes: 30)));
    h.store.failReads = true;
    await h.auth.restore();
    expect(h.state, isA<SignedOut>());
  });
}
