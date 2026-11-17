// RegisterConsignment.save with a fake Keystore channel that "signs" by
// recording the bytes, and the real repository on an in-memory database.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';
import 'package:minechain/features/device_key/domain/key_fingerprint.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/registration/data/register_consignment.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';

/// Signs by recording exactly what it was given, and answering with a fake
/// DER-looking signature. Can be told to fail.
class SigningChannel extends FakeDeviceKeyChannel {
  SigningChannel({super.keys});

  final List<Uint8List> signed = [];
  bool failSign = false;

  @override
  Future<Uint8List> sign(String alias, Uint8List bytes) async {
    if (failSign) throw const DeviceKeyException(DeviceKeyError.keystoreError);
    signed.add(Uint8List.fromList(bytes));
    return Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
  }
}

final miner = userOf(Role.miner);
final alias = deviceKeyAlias(miner.id);
final phoneKey = fakeKey(1);
final phoneFingerprint = keyFingerprint(phoneKey);
final now = DateTime.utc(2026, 11, 17, 10, 30, 0, 250, 999);

late SigningChannel channel;
late InMemoryLocalDatabase database;
late LocalStepsRepository steps;

RegisterConsignment useCase({
  DeviceKeyState? keyState,
  Random? random,
  Future<LocalStepsRepository> Function()? stepsSource,
}) => RegisterConsignment(
  channel: channel,
  steps: stepsSource ?? () async => steps,
  keyState: () => keyState ?? DeviceKeyReady(phoneFingerprint),
  clock: () => now,
  random: random,
);

Future<SaveResult> saveWith(RegisterConsignment registration) =>
    registration.save(
      user: miner,
      qrCode: 'MC-DEMO-000001',
      mineral: Mineral.gold,
      weightMg: '1500000',
      latitude: -15.4190123,
      longitude: 28.2881049,
      gpsAccuracyM: 6.5,
    );

Future<List<LocalStep>> saved() => steps.listForActor(miner.id);

void main() {
  setUp(() {
    channel = SigningChannel(keys: {alias: phoneKey});
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
  });
  tearDown(() => database.close());

  test('saved: one row, and only after it is committed', () async {
    final result = await saveWith(useCase());

    expect(result, isA<SaveDone>());
    final row = (await saved()).single;
    expect(row.stepId, (result as SaveDone).stepId);
    expect(row.syncState, SyncState.queued);
  });

  test('the stored payload is exactly the bytes that were signed', () async {
    await saveWith(useCase());

    final row = (await saved()).single;
    expect(channel.signed, hasLength(1));
    expect(utf8.encode(row.payload), channel.signed.single);
    // And the stored signature is the one the Keystore returned.
    expect(base64.decode(row.signature), [
      0x30,
      0x06,
      0x02,
      0x01,
      0x01,
      0x02,
      0x01,
      0x02,
    ]);
    expect(row.keyFingerprint, phoneFingerprint);
  });

  test('the payload holds the values, formatted once', () async {
    final result = await saveWith(useCase()) as SaveDone;

    final row = (await saved()).single;
    expect(
      row.payload,
      'minechain-step/1/registration\n'
      'step_id=${result.stepId}\n'
      'actor_id=${miner.id}\n'
      'qr_code=MC-DEMO-000001\n'
      'mineral=gold\n'
      'weight_mg=1500000\n'
      'latitude=-15.419012\n'
      'longitude=28.288105\n'
      // The clock's 250 ms 999 µs, truncated.
      'captured_at=2026-11-17T10:30:00.250Z\n',
    );
    // The row's own columns are the same text as the payload's.
    expect(row.latitude, '-15.419012');
    expect(row.capturedAt, '2026-11-17T10:30:00.250Z');
    expect(row.mineral, 'gold');
    expect(row.gpsAccuracyM, 6.5);
  });

  test('also allowed while the key is not registered yet', () async {
    final result = await saveWith(
      useCase(keyState: DeviceKeyUnregistered(phoneFingerprint)),
    );
    expect(result, isA<SaveDone>());
  });

  group('refused before anything is signed or stored', () {
    for (final (name, state) in <(String, DeviceKeyState)>[
      ('other device', const DeviceKeyOtherDevice()),
      ('failed', const DeviceKeyFailed('x')),
      ('checking', const DeviceKeyChecking()),
      ('not needed (no key)', const DeviceKeyNotNeeded()),
    ]) {
      test(name, () async {
        expect(
          await saveWith(useCase(keyState: state)),
          isA<SaveKeyNotUsable>(),
        );
        expect(channel.signed, isEmpty);
        expect(await saved(), isEmpty);
      });
    }

    test('the Keystore key is not the approved one', () async {
      channel.keys[alias] = fakeKey(2);
      expect(await saveWith(useCase()), isA<SaveKeyNotUsable>());
      expect(channel.signed, isEmpty);
      expect(await saved(), isEmpty);
    });

    test('no key in the Keystore at all', () async {
      channel.keys.clear();
      expect(await saveWith(useCase()), isA<SaveKeyNotUsable>());
      expect(await saved(), isEmpty);
    });

    test('a QR code that breaks the grammar', () async {
      final result = await useCase().save(
        user: miner,
        qrCode: 'MC 1',
        mineral: Mineral.gold,
        weightMg: '1500000',
        latitude: -15.4,
        longitude: 28.2,
      );
      expect(result, isA<SaveInvalidField>());
      expect((result as SaveInvalidField).field, 'qr_code');
      expect(channel.signed, isEmpty);
    });

    test('a GPS value out of range', () async {
      final result = await useCase().save(
        user: miner,
        qrCode: 'MC-DEMO-000001',
        mineral: Mineral.gold,
        weightMg: '1500000',
        latitude: 91,
        longitude: 28.2,
      );
      expect((result as SaveInvalidField).field, 'latitude');
      expect(channel.signed, isEmpty);
    });

    test('the database cannot be opened', () async {
      final result = await saveWith(
        useCase(stepsSource: () async => throw const DatabaseWrongKey()),
      );
      expect(result, isA<SaveStorageFailed>());
      expect((result as SaveStorageFailed).failure, isA<DatabaseWrongKey>());
      expect(channel.signed, isEmpty); // never signed what cannot be saved
    });
  });

  test('signing fails: nothing is stored', () async {
    channel.failSign = true;

    expect(await saveWith(useCase()), isA<SaveSigningFailed>());
    expect(await saved(), isEmpty);
  });

  test('a step id already saved: a typed error, the first row kept', () async {
    // The same seeded randomness gives the same step id twice.
    final first = await saveWith(useCase(random: Random(7))) as SaveDone;

    final second = await saveWith(useCase(random: Random(7)));

    expect(second, isA<SaveDuplicateStepId>());
    final rows = await saved();
    expect(rows.single.stepId, first.stepId);
  });

  test('two saves get two different step ids', () async {
    final registration = useCase();
    final a = await saveWith(registration) as SaveDone;
    final b = await saveWith(registration) as SaveDone;
    expect(a.stepId, isNot(b.stepId));
    expect(await saved(), hasLength(2));
  });
}
