// Tests the Dart wrapper only. The real Kotlin side is not here: a unit test
// runs on the laptop, where there is no Android Keystore. Instead, Flutter's
// test messenger answers the channel in place of Kotlin, so each test decides
// what "Kotlin" replies and checks what the wrapper sent and made of it.
//
// The real Keystore is tested on the phone by integration_test/device_key_test.dart.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';

void main() {
  // The test binding provides the fake messenger used below.
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(DeviceKeyChannel.channelName);
  const alias = 'minechain_signing_3f2b6c1e-0000-4000-8000-000000000001';

  late List<MethodCall> calls;

  // Makes "Kotlin" answer every call with [answer], and records the calls.
  void kotlinAnswers(Future<Object?> Function(MethodCall call) answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return answer(call);
        });
  }

  // Makes "Kotlin" fail every call with [code], as result.error(code) does.
  void kotlinFails(String code) =>
      kotlinAnswers((_) async => throw PlatformException(code: code));

  setUp(() => calls = []);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Matcher failsWith(DeviceKeyError error) =>
      throwsA(isA<DeviceKeyException>().having((e) => e.error, 'error', error));

  final publicKey = Uint8List(91)..[0] = 0x30;
  final signature = Uint8List(70)..[0] = 0x30;

  group('publicKey', () {
    test('sends the alias and returns the 91 bytes', () async {
      kotlinAnswers((_) async => publicKey);

      final key = await DeviceKeyChannel().publicKey(alias);

      expect(key, publicKey);
      expect(calls.single.method, 'publicKey');
      expect(calls.single.arguments, {'alias': alias});
    });

    test('null from Kotlin means no key, not an error', () async {
      kotlinAnswers((_) async => null);

      expect(await DeviceKeyChannel().publicKey(alias), isNull);
    });

    test('a key of the wrong length is refused', () async {
      kotlinAnswers((_) async => Uint8List(65));

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.keystoreError),
      );
    });

    test('something that is not bytes is refused', () async {
      kotlinAnswers((_) async => 'MFkw...');

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.keystoreError),
      );
    });
  });

  group('createKey', () {
    test('sends the alias and returns the new public key', () async {
      kotlinAnswers((_) async => publicKey);

      final key = await DeviceKeyChannel().createKey(alias);

      expect(key, publicKey);
      expect(calls.single.method, 'createKey');
      expect(calls.single.arguments, {'alias': alias});
    });

    test('null is not a key here: createKey always returns one', () async {
      kotlinAnswers((_) async => null);

      await expectLater(
        DeviceKeyChannel().createKey(alias),
        failsWith(DeviceKeyError.keystoreError),
      );
    });

    test('KEY_EXISTS becomes keyExists', () async {
      kotlinFails('KEY_EXISTS');

      await expectLater(
        DeviceKeyChannel().createKey(alias),
        failsWith(DeviceKeyError.keyExists),
      );
    });
  });

  group('sign', () {
    test('sends the alias and the exact bytes, and returns the DER', () async {
      kotlinAnswers((_) async => signature);
      final payload = Uint8List.fromList(
        'minechain-step/1/registration\n'.codeUnits,
      );

      final result = await DeviceKeyChannel().sign(alias, payload);

      expect(result, signature);
      expect(calls.single.method, 'sign');
      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['alias'], alias);
      // The payload itself, not a hash of it (signing spec, section 5).
      expect(arguments['bytes'], payload);
    });

    test(
      'the shortest and longest signatures the server accepts pass',
      () async {
        for (final length in [8, 72]) {
          kotlinAnswers((_) async => Uint8List(length));
          final result = await DeviceKeyChannel().sign(alias, Uint8List(1));
          expect(result.length, length);
        }
      },
    );

    for (final length in [0, 7, 73]) {
      test('a $length-byte signature is refused', () async {
        kotlinAnswers((_) async => Uint8List(length));

        await expectLater(
          DeviceKeyChannel().sign(alias, Uint8List(1)),
          failsWith(DeviceKeyError.keystoreError),
        );
      });
    }

    test('KEY_NOT_FOUND becomes keyNotFound', () async {
      kotlinFails('KEY_NOT_FOUND');

      await expectLater(
        DeviceKeyChannel().sign(alias, Uint8List(1)),
        failsWith(DeviceKeyError.keyNotFound),
      );
    });
  });

  group('errors', () {
    test('BAD_ARGUMENT becomes badArgument', () async {
      kotlinFails('BAD_ARGUMENT');

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.badArgument),
      );
    });

    // Hardening H1: Kotlin refuses createKey and sign on a phone with no
    // screen lock.
    test(
      'NO_SCREEN_LOCK becomes noScreenLock, for createKey and sign',
      () async {
        kotlinFails('NO_SCREEN_LOCK');

        await expectLater(
          DeviceKeyChannel().createKey(alias),
          failsWith(DeviceKeyError.noScreenLock),
        );
        await expectLater(
          DeviceKeyChannel().sign(alias, Uint8List(1)),
          failsWith(DeviceKeyError.noScreenLock),
        );
      },
    );

    test('KEYSTORE_ERROR becomes keystoreError', () async {
      kotlinFails('KEYSTORE_ERROR');

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.keystoreError),
      );
    });

    test('an unknown code is treated as a Keystore error', () async {
      kotlinFails('SOMETHING_NEW');

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.keystoreError),
      );
    });

    test('no Kotlin side at all becomes unavailable', () async {
      // No handler registered: the messenger answers as if no plugin
      // exists, which invokeMethod reports as a MissingPluginException.
      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        failsWith(DeviceKeyError.unavailable),
      );
    });

    test('a platform message never reaches the exception text', () async {
      kotlinAnswers(
        (_) async => throw PlatformException(
          code: 'KEYSTORE_ERROR',
          message: 'secret device detail',
        ),
      );

      await expectLater(
        DeviceKeyChannel().publicKey(alias),
        throwsA(
          isA<DeviceKeyException>().having(
            (e) => e.toString(),
            'text',
            'DeviceKeyException(keystoreError)',
          ),
        ),
      );
    });
  });
}
