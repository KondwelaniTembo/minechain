// DeviceKeyController: every row of the plan's §4 table and every PUT answer,
// with a fake Keystore channel, the real ApiClient on a MockClient, and a
// fake secure store under the real SessionStore.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/storage/secure_store.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/data/session_store.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';
import 'package:minechain/features/device_key/domain/key_fingerprint.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';
import '../../../fakes/fake_secure_store.dart';

const minerId = '3f2b6c1e-0000-4000-8000-000000000001';
const otherMinerId = '3f2b6c1e-0000-4000-8000-000000000002';

final phoneKey = fakeKey(1);
final phoneFingerprint = keyFingerprint(phoneKey);
final otherFingerprint = keyFingerprint(fakeKey(9));

/// A user of [role] whose server copy has [fingerprint].
User userWith({
  Role role = Role.miner,
  String id = minerId,
  String? fingerprint,
}) => (User.fromJson({
  ...userJson(id: id, role: role.name),
  'publicKeyFingerprint': fingerprint,
}) as UserParsed).user;

SignedIn sessionFor(User user) => SignedIn(
  user: user,
  token: fakeToken,
  expiresAt: DateTime.utc(2026, 11, 16, 10),
);

/// The PUT endpoint. By default it accepts the key and answers with the
/// user, now carrying that key's fingerprint, as the real server does.
class FakeKeyServer {
  final List<http.Request> puts = [];
  FutureOr<http.Response> Function(http.Request request)? answer;
  Completer<void>? hold;

  late final MockClient client = MockClient((request) async {
    if (request.method != 'PUT' || request.url.path != '/auth/me/public-key') {
      return http.Response(errorAnswer('NOT_FOUND', 'Route not found'), 404);
    }
    puts.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;
    final custom = answer;
    if (custom != null) return await custom(request);

    final sent = base64.decode(
      (jsonDecode(request.body) as Map)['publicKey'] as String,
    );
    return http.Response(
      jsonEncode({
        'user': {
          ...userJson(id: minerId),
          'publicKeyFingerprint': keyFingerprint(Uint8List.fromList(sent)),
        },
      }),
      200,
    );
  });
}

late FakeDeviceKeyChannel channel;
late FakeKeyServer server;
late FakeSecureStore store;
late FakeAuthController auth;
late ProviderContainer container;

void start(AuthState signedIn) {
  auth = FakeAuthController(signedIn);
  container = ProviderContainer.test(
    retry: noRetry,
    overrides: [
      ...fakeOverrides(auth),
      deviceKeyChannelProvider.overrideWithValue(channel),
      secureStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWith(
        (ref) async => ApiClient(
          client: server.client,
          baseUri: Uri.parse('https://api.example.test'),
          sessionEvents: ref.watch(sessionEventsProvider),
          delay: (_) => Completer<void>().future,
        ),
      ),
    ],
  );
  // Created now, as main.dart does before restore().
  container.read(deviceKeyControllerProvider);
}

DeviceKeyController get controller =>
    container.read(deviceKeyControllerProvider.notifier);
DeviceKeyState get state => container.read(deviceKeyControllerProvider);

final minerAlias = deviceKeyAlias(minerId);

Map<String, Object?>? savedUser() {
  final saved = store.values[SessionKeys.user];
  return saved == null ? null : jsonDecode(saved) as Map<String, Object?>;
}

/// Lets queued work (an event delivered on the stream) finish.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    channel = FakeDeviceKeyChannel(nextKey: phoneKey);
    server = FakeKeyServer();
    store = FakeSecureStore();
  });

  group('roles', () {
    for (final role in [Role.officer, Role.admin]) {
      test(
        '${role.name}: not needed, and the Keystore is never touched',
        () async {
          final user = userWith(role: role);
          start(sessionFor(user));

          await controller.check(user);

          expect(state, isA<DeviceKeyNotNeeded>());
          expect(channel.calls, isEmpty);
          expect(server.puts, isEmpty);
        },
      );
    }

    for (final role in signingRoles) {
      test('${role.name}: checked', () async {
        final user = userWith(role: role);
        start(sessionFor(user));
        await controller.check(user);
        expect(state, isA<DeviceKeyReady>());
      });
    }
  });

  group('the §4 table', () {
    test('row 1, no key and none on the server: create it, PUT it', () async {
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(channel.createCalls, 1);
      expect(channel.keys[minerAlias], phoneKey);
      final body = jsonDecode(server.puts.single.body);
      expect(body, {'publicKey': base64.encode(phoneKey)});
      expect((body as Map)['publicKey'], hasLength(124));
      expect(server.puts.single.headers['authorization'], 'Bearer $fakeToken');
      expect(state, isA<DeviceKeyReady>());
      expect((state as DeviceKeyReady).fingerprint, phoneFingerprint);
    });

    test('row 2, a key the server does not know: PUT that key, never a '
        'second one', () async {
      channel.keys[minerAlias] = phoneKey;
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(channel.createCalls, 0);
      expect(jsonDecode(server.puts.single.body), {
        'publicKey': base64.encode(phoneKey),
      });
      expect(state, isA<DeviceKeyReady>());
    });

    test('row 3, the same key on both: nothing is sent', () async {
      channel.keys[minerAlias] = phoneKey;
      final user = userWith(fingerprint: phoneFingerprint);
      start(sessionFor(user));

      await controller.check(user);

      expect(server.puts, isEmpty);
      expect(channel.createCalls, 0);
      expect((state as DeviceKeyReady).fingerprint, phoneFingerprint);
      expect(state.maySign, isTrue);
    });

    test(
      'row 4, a different key on the server: otherDevice, nothing sent',
      () async {
        channel.keys[minerAlias] = phoneKey;
        final user = userWith(fingerprint: otherFingerprint);
        start(sessionFor(user));

        await controller.check(user);

        expect(state, isA<DeviceKeyOtherDevice>());
        expect(state.maySign, isFalse);
        expect(server.puts, isEmpty);
        expect(channel.createCalls, 0);
      },
    );

    test('row 5, no key here but one on the server (reinstall): '
        'otherDevice, and no key is made', () async {
      final user = userWith(fingerprint: otherFingerprint);
      start(sessionFor(user));

      await controller.check(user);

      expect(state, isA<DeviceKeyOtherDevice>());
      expect(channel.createCalls, 0);
      expect(channel.keys, isEmpty);
      expect(server.puts, isEmpty);
    });
  });

  group('after a 200', () {
    test('the returned user is saved, with the fingerprint', () async {
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(savedUser()!['publicKeyFingerprint'], phoneFingerprint);
    });

    test('and the signed-in user in memory has it too', () async {
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      final now = container.read(authControllerProvider) as SignedIn;
      expect(now.user.publicKeyFingerprint, phoneFingerprint);
      expect(now.token, fakeToken); // the token is unchanged
    });

    test('a 200 naming another key is not called registered', () async {
      server.answer = (_) => http.Response(
        jsonEncode({
          'user': {
            ...userJson(id: minerId),
            'publicKeyFingerprint': otherFingerprint,
          },
        }),
        200,
      );
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(state, isA<DeviceKeyFailed>());
      expect(savedUser(), isNull);
    });

    test('an unreadable 200: left unregistered for the next sign-in', () async {
      server.answer = (_) => http.Response(jsonEncode({'user': 'x'}), 200);
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(state, isA<DeviceKeyUnregistered>());
    });
  });

  group('PUT refused or not sent', () {
    for (final (status, code, expected) in [
      (409, ApiCodes.publicKeyAlreadyRegistered, DeviceKeyOtherDevice),
      (409, ApiCodes.publicKeyInUse, DeviceKeyFailed),
      (400, ApiCodes.invalidPublicKey, DeviceKeyFailed),
      (400, ApiCodes.validationFailed, DeviceKeyFailed),
      (403, ApiCodes.forbidden, DeviceKeyFailed),
      (500, ApiCodes.internalError, DeviceKeyUnregistered),
    ]) {
      test('$status $code -> $expected', () async {
        server.answer = (_) =>
            http.Response(errorAnswer(code, 'Refused.'), status);
        final user = userWith();
        start(sessionFor(user));

        await controller.check(user);

        expect(state.runtimeType, expected);
        // Whatever the answer, the key stays on the phone.
        expect(channel.keys[minerAlias], phoneKey);
        expect(savedUser(), isNull);
      });
    }

    test("PUBLIC_KEY_IN_USE shows the server's own sentence", () async {
      server.answer = (_) => http.Response(
        errorAnswer(
          ApiCodes.publicKeyInUse,
          'This device key is already registered to another account.',
        ),
        409,
      );
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(
        (state as DeviceKeyFailed).message,
        'This device key is already registered to another account.',
      );
    });

    test('no network: unregistered, may sign, and the SAME key is sent at '
        'the next sign-in', () async {
      server.answer = (_) => throw http.ClientException('offline');
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);
      expect(state, isA<DeviceKeyUnregistered>());
      expect(state.maySign, isTrue);
      expect(server.puts, hasLength(1));

      // No timer, no loop: nothing more happens by itself.
      await settle();
      expect(server.puts, hasLength(1));

      // The next sign-in (here, as SignedInEvents announces it).
      server.answer = null;
      container.read(signedInEventsProvider).report(user);
      await settle();

      expect(server.puts, hasLength(2));
      expect(channel.createCalls, 1); // still only the first key
      expect(jsonDecode(server.puts.last.body), {
        'publicKey': base64.encode(phoneKey),
      });
      expect(state, isA<DeviceKeyReady>());
    });

    test(
      '401 TOKEN_EXPIRED goes through SessionEvents; the key waits',
      () async {
        server.answer = (_) => http.Response(
          errorAnswer(ApiCodes.tokenExpired, 'Your session has expired.'),
          401,
        );
        final user = userWith();
        start(sessionFor(user));
        final reported = <String>[];
        final sub = container
            .read(sessionEventsProvider)
            .refusals
            .listen(reported.add);
        addTearDown(sub.cancel);

        await controller.check(user);
        await settle();

        expect(reported, [ApiCodes.tokenExpired]);
        expect(state, isA<DeviceKeyUnregistered>());
      },
    );

    test(
      'token expired before the PUT: nothing is sent, the key waits',
      () async {
        final user = userWith();
        start(SignedInNeedsPassword(user));

        await controller.check(user);

        expect(channel.createCalls, 1);
        expect(server.puts, isEmpty);
        expect(state, isA<DeviceKeyUnregistered>());
      },
    );
  });

  group('the Keystore', () {
    test(
      'another check made the key first: that key is used, not a second',
      () async {
        channel.createLosesRace = true;
        final user = userWith();
        start(sessionFor(user));

        await controller.check(user);

        expect(channel.keys, hasLength(1));
        expect(jsonDecode(server.puts.single.body), {
          'publicKey': base64.encode(phoneKey),
        });
        expect(state, isA<DeviceKeyReady>());
      },
    );

    test('reading fails: failed, nothing sent', () async {
      channel.failPublicKey = DeviceKeyError.keystoreError;
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect((state as DeviceKeyFailed).message, AppText.deviceKeyProblem);
      expect(server.puts, isEmpty);
    });

    test('creating fails: failed, nothing sent', () async {
      channel.failCreate = DeviceKeyError.keystoreError;
      final user = userWith();
      start(sessionFor(user));

      await controller.check(user);

      expect(state, isA<DeviceKeyFailed>());
      expect(server.puts, isEmpty);
    });
  });

  group('sign-ins and sign-outs', () {
    test('a sign-in announced by SignedInEvents runs the check', () async {
      final user = userWith();
      start(sessionFor(user));

      container.read(signedInEventsProvider).report(user);
      await settle();

      expect(state, isA<DeviceKeyReady>());
    });

    test('signing in again with the key registered sends nothing', () async {
      final user = userWith();
      start(sessionFor(user));
      await controller.check(user);
      expect(server.puts, hasLength(1));

      // The next sign-in brings the user as saved, with the fingerprint.
      final saved = (User.fromJson(savedUser()) as UserParsed).user;
      await controller.check(saved);

      expect(server.puts, hasLength(1));
      expect(channel.createCalls, 1);
      expect(state, isA<DeviceKeyReady>());
    });

    test('signing out: not needed', () async {
      final user = userWith();
      start(sessionFor(user));
      await controller.check(user);

      auth.setState(const SignedOut());

      expect(state, isA<DeviceKeyNotNeeded>());
    });

    test('a PUT answered after a sign-out changes nothing', () async {
      server.hold = Completer<void>();
      final user = userWith();
      start(sessionFor(user));

      final running = controller.check(user);
      await settle();
      auth.setState(const SignedOut());
      server.hold!.complete();
      await running;

      expect(state, isA<DeviceKeyNotNeeded>());
      expect(savedUser(), isNull);
    });

    test('another person on the same phone gets their own key', () async {
      final first = userWith();
      start(sessionFor(first));
      await controller.check(first);

      final second = userWith(id: otherMinerId);
      auth.setState(sessionFor(second));
      channel.nextKey = fakeKey(2);
      server.answer = (request) {
        final sent = base64.decode(
          (jsonDecode(request.body) as Map)['publicKey'] as String,
        );
        return http.Response(
          jsonEncode({
            'user': {
              ...userJson(id: otherMinerId),
              'publicKeyFingerprint': keyFingerprint(Uint8List.fromList(sent)),
            },
          }),
          200,
        );
      };
      await controller.check(second);

      expect(channel.keys.keys, {minerAlias, deviceKeyAlias(otherMinerId)});
      expect(channel.keys[minerAlias], phoneKey); // the first is untouched
      expect(state, isA<DeviceKeyReady>());
    });
  });
}
