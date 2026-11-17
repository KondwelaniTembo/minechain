// The real Android Keystore, on the phone (plan M1). Unit tests cannot do
// this: they run on the laptop, which has no Keystore.
//
// Run with:  flutter test integration_test/device_key_test.dart -d <device id>
//
// TEST KEYS STAY ON THE PHONE. Each run makes keys under fresh random aliases
// (so runs never collide with each other or with a real user's key), and
// nothing deletes them: the channel has no delete method, on purpose, so that
// no bug in the app can throw away the key that unsynced steps depend on.
// Adding a delete only for tests would put it into the real app too. The test
// keys are removed when the app is uninstalled (or its data is cleared). They
// are a few hundred bytes each and are never registered with the server.
//
// What this proves: the key is P-256, its public key is the 91-byte SPKI the
// server expects, signatures are DER, and the refusals work. What it does not
// prove: that a signature VERIFIES. Dart has no built-in ECDSA check; the
// server's check comes in M2 (key registered) and M6 (a signed step
// accepted as "created").

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';

/// The registration vector's payload, copied from docs/signing-vectors.json
/// ("positive", "registration"). The phone cannot read files from the
/// laptop's repository, so it is written out here.
const String registrationVectorPayload =
    'minechain-step/1/registration\n'
    'step_id=6f1d2c3a-0000-4000-8000-000000000101\n'
    'actor_id=3f2b6c1e-0000-4000-8000-000000000101\n'
    'qr_code=MC-DEMO-000001\n'
    'mineral=gold\n'
    'weight_mg=1500000\n'
    'latitude=-15.419012\n'
    'longitude=28.288105\n'
    'captured_at=2026-11-10T08:00:00.000Z\n';

/// How every P-256 SPKI DER key begins: SEQUENCE, the EC algorithm id, the
/// P-256 curve id, then the BIT STRING header and 0x04 (an uncompressed
/// point). In base64 this is the familiar "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE".
const List<int> p256SpkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, //
  0x42, 0x00, 0x04,
];

final Random _random = Random.secure();

/// A fresh lower-case v4 UUID, used only to make unique test aliases.
String randomUuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String randomTestAlias() => deviceKeyAlias(randomUuid());

/// True if [der] is shaped like a DER ECDSA signature for P-256:
/// SEQUENCE { INTEGER r, INTEGER s }, each integer 1–33 bytes, minimal
/// (no needless leading zero), positive, and nothing left over.
bool looksLikeDerSignature(Uint8List der) {
  if (der.length < 8 || der.length > 72) return false;
  if (der[0] != 0x30 || der[1] != der.length - 2) return false;
  var i = 2;
  for (var n = 0; n < 2; n++) {
    if (i + 2 > der.length || der[i] != 0x02) return false;
    final len = der[i + 1];
    final start = i + 2;
    if (len < 1 || len > 33 || start + len > der.length) return false;
    // Negative numbers are not allowed in a signature.
    if (der[start] & 0x80 != 0) return false;
    // A leading 0x00 is only allowed when the next byte would look negative.
    if (len > 1 && der[start] == 0x00 && der[start + 1] & 0x80 == 0) {
      return false;
    }
    i = start + len;
  }
  return i == der.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final keys = DeviceKeyChannel();
  final payloadBytes = Uint8List.fromList(
    ascii.encode(registrationVectorPayload),
  );

  Matcher failsWith(DeviceKeyError error) =>
      throwsA(isA<DeviceKeyException>().having((e) => e.error, 'error', error));

  testWidgets('a new alias has no key', (tester) async {
    expect(await keys.publicKey(randomTestAlias()), isNull);
  });

  testWidgets('createKey makes a P-256 key with a 91-byte SPKI public key', (
    tester,
  ) async {
    final alias = randomTestAlias();

    final created = await keys.createKey(alias);

    expect(created.length, 91);
    expect(created.sublist(0, p256SpkiPrefix.length), p256SpkiPrefix);
    // Reading it back gives the same bytes.
    expect(await keys.publicKey(alias), created);
  });

  testWidgets('createKey never overwrites an existing key', (tester) async {
    final alias = randomTestAlias();
    final first = await keys.createKey(alias);

    await expectLater(
      keys.createKey(alias),
      failsWith(DeviceKeyError.keyExists),
    );
    // The original key is untouched.
    expect(await keys.publicKey(alias), first);
  });

  testWidgets('two aliases get two different keys', (tester) async {
    final a = await keys.createKey(randomTestAlias());
    final b = await keys.createKey(randomTestAlias());
    expect(a, isNot(b));
  });

  testWidgets('sign returns a DER signature over the registration vector', (
    tester,
  ) async {
    final alias = randomTestAlias();
    await keys.createKey(alias);

    final stopwatch = Stopwatch()..start();
    final first = await keys.sign(alias, payloadBytes);
    stopwatch.stop();
    final second = await keys.sign(alias, payloadBytes);

    expect(
      looksLikeDerSignature(first),
      isTrue,
      reason: 'not DER: ${base64.encode(first)}',
    );
    expect(looksLikeDerSignature(second), isTrue);
    // ECDSA uses a fresh random number each time, so two signatures over the
    // same bytes differ. Equal ones would mean something is badly wrong.
    expect(first, isNot(second));
    // Far inside NFR-03's 3 seconds for the whole save; a Keystore
    // signature normally takes well under 100 ms.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  testWidgets('sign with no key for the alias is keyNotFound', (tester) async {
    await expectLater(
      keys.sign(randomTestAlias(), payloadBytes),
      failsWith(DeviceKeyError.keyNotFound),
    );
  });

  group('Kotlin refuses bad arguments by itself', () {
    // These go straight to the channel, past deviceKeyAlias(), to prove the
    // Kotlin check works on its own.
    for (final alias in [
      'not_a_minechain_alias',
      'minechain_signing_3F2B6C1E-0000-4000-8000-000000000001',
      'minechain_signing_',
      '',
    ]) {
      testWidgets('alias "$alias"', (tester) async {
        await expectLater(
          keys.publicKey(alias),
          failsWith(DeviceKeyError.badArgument),
        );
        await expectLater(
          keys.createKey(alias),
          failsWith(DeviceKeyError.badArgument),
        );
        await expectLater(
          keys.sign(alias, payloadBytes),
          failsWith(DeviceKeyError.badArgument),
        );
      });
    }

    testWidgets('empty bytes to sign', (tester) async {
      final alias = randomTestAlias();
      await keys.createKey(alias);
      await expectLater(
        keys.sign(alias, Uint8List(0)),
        failsWith(DeviceKeyError.badArgument),
      );
    });

    testWidgets('more than 512 bytes to sign', (tester) async {
      final alias = randomTestAlias();
      await keys.createKey(alias);
      await expectLater(
        keys.sign(alias, Uint8List(513)),
        failsWith(DeviceKeyError.badArgument),
      );
      // 512 is still allowed: the server's largest payload.
      expect(
        looksLikeDerSignature(await keys.sign(alias, Uint8List(512))),
        isTrue,
      );
    });
  });
}
