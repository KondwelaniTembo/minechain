// RecordHandoff.save with a fake Keystore channel that "signs" by recording
// the bytes, and the real repository on an in-memory database (the same
// schema as the phone, no cipher). The shared parts of the save (key check,
// database first, busy moments) are covered once, in
// register_consignment_test.dart; here, what a handoff has of its own, plus
// one of each refusal to show it goes through the same path.

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
import 'package:minechain/features/handoff/data/record_handoff.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';

class SigningChannel extends FakeDeviceKeyChannel {
  SigningChannel({super.keys});

  final List<Uint8List> signed = [];
  bool failSign = false;
  bool noScreenLock = false;

  @override
  Future<Uint8List> sign(String alias, Uint8List bytes) async {
    if (failSign) throw const DeviceKeyException(DeviceKeyError.keystoreError);
    if (noScreenLock) {
      throw const DeviceKeyException(DeviceKeyError.noScreenLock);
    }
    signed.add(Uint8List.fromList(bytes));
    return Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
  }
}

final transporter = userOf(Role.transporter);
final alias = deviceKeyAlias(transporter.id);
final phoneKey = fakeKey(3);
final phoneFingerprint = keyFingerprint(phoneKey);
final now = DateTime.utc(2026, 11, 20, 11, 54, 7, 125, 600);

late SigningChannel channel;
late InMemoryLocalDatabase database;
late LocalStepsRepository steps;

RecordHandoff useCase({
  DeviceKeyState? keyState,
  Random? random,
  Future<LocalStepsRepository> Function()? stepsSource,
}) => RecordHandoff(
  channel: channel,
  steps: stepsSource ?? () async => steps,
  keyState: () => keyState ?? DeviceKeyReady(phoneFingerprint),
  clock: () => now,
  random: random,
);

Future<SaveResult> saveWith(
  RecordHandoff handoff, {
  String qrCode = 'MC-DEMO-000001',
  Mineral mineral = Mineral.copper,
  String weightMg = '1500000',
  double latitude = -15.4189004,
  double longitude = 28.2886996,
}) => handoff.save(
  user: transporter,
  qrCode: qrCode,
  mineral: mineral,
  weightMg: weightMg,
  latitude: latitude,
  longitude: longitude,
  gpsAccuracyM: 4.5,
);

Future<List<LocalStep>> saved() => steps.listForActor(transporter.id);

void main() {
  setUp(() {
    channel = SigningChannel(keys: {alias: phoneKey});
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
  });
  tearDown(() => database.close());

  test('saved: one handoff row, queued', () async {
    final result = await saveWith(useCase());

    expect(result, isA<SaveDone>());
    final row = (await saved()).single;
    expect(row.stepId, (result as SaveDone).stepId);
    expect(row.type, 'handoff');
    expect(row.actorId, transporter.id);
    expect(row.syncState, SyncState.queued);
  });

  test('a 1.5 kg copper bag: the 8-line payload, no mineral line', () async {
    final result = await saveWith(useCase()) as SaveDone;

    final row = (await saved()).single;
    expect(
      row.payload,
      'minechain-step/1/handoff\n'
      'step_id=${result.stepId}\n'
      'actor_id=${transporter.id}\n'
      'qr_code=MC-DEMO-000001\n'
      'weight_mg=1500000\n'
      'latitude=-15.418900\n'
      'longitude=28.288700\n'
      // The clock's 125 ms 600 µs, truncated.
      'captured_at=2026-11-20T11:54:07.125Z\n',
    );
    expect(row.payload, isNot(contains('mineral')));
  });

  test('the stored payload is exactly the bytes that were signed', () async {
    await saveWith(useCase());

    final row = (await saved()).single;
    expect(channel.signed, hasLength(1));
    expect(utf8.encode(row.payload), channel.signed.single);
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

  test('the mineral is kept only as the unsigned hint (Q3)', () async {
    await saveWith(useCase(), mineral: Mineral.gold, weightMg: '15300');

    final row = (await saved()).single;
    expect(row.mineral, isNull); // no signed mineral on a handoff
    expect(row.mineralHint, 'gold');
    expect(row.weightMg, '15300');
    expect(row.latitude, '-15.418900');
    expect(row.capturedAt, '2026-11-20T11:54:07.125Z');
    expect(row.gpsAccuracyM, 4.5);
  });

  test('"My handoffs" can read it back with its hint', () async {
    await saveWith(useCase());

    final item = (await steps.listOfTypeForActor(
      transporter.id,
      'handoff',
    )).single;
    expect(item.mineral, 'copper');
    expect(item.weightMg, '1500000');
  });

  test('the next sync offers it, like any saved step', () async {
    final result = await saveWith(useCase()) as SaveDone;

    final due = await steps.dueForSync(actorId: transporter.id, now: now);
    expect(due.map((s) => s.stepId), [result.stepId]);
  });

  test('Q4: the lookup finds it afterwards', () async {
    await saveWith(useCase());
    expect(
      await steps.handedOffOn('MC-DEMO-000001', transporter.id),
      DateTime.utc(2026, 11, 20, 11, 54, 7, 125),
    );
  });

  test('two saves get two different step ids', () async {
    final handoff = useCase();
    final a = await saveWith(handoff) as SaveDone;
    final b = await saveWith(handoff) as SaveDone;
    expect(a.stepId, isNot(b.stepId));
    expect(await saved(), hasLength(2));
  });

  group('refused, nothing signed or stored', () {
    test('a phone that may not sign for this account', () async {
      expect(
        await saveWith(useCase(keyState: const DeviceKeyOtherDevice())),
        isA<SaveKeyNotUsable>(),
      );
      expect(channel.signed, isEmpty);
      expect(await saved(), isEmpty);
    });

    test('the Keystore key is not the approved one', () async {
      channel.keys[alias] = fakeKey(4);
      expect(await saveWith(useCase()), isA<SaveKeyNotUsable>());
      expect(channel.signed, isEmpty);
      expect(await saved(), isEmpty);
    });

    test('a QR code that breaks the grammar', () async {
      final result = await saveWith(useCase(), qrCode: 'MC 1');
      expect((result as SaveInvalidField).field, 'qr_code');
      expect(channel.signed, isEmpty);
    });

    test('a weight that is not whole milligrams', () async {
      final result = await saveWith(useCase(), weightMg: '0');
      expect((result as SaveInvalidField).field, 'weight_mg');
      expect(channel.signed, isEmpty);
    });

    test('a GPS value out of range', () async {
      final result = await saveWith(useCase(), longitude: 181);
      expect((result as SaveInvalidField).field, 'longitude');
      expect(channel.signed, isEmpty);
    });

    test('the database cannot be opened', () async {
      final result = await saveWith(
        useCase(stepsSource: () async => throw const DatabaseWrongKey()),
      );
      expect((result as SaveStorageFailed).failure, isA<DatabaseWrongKey>());
      expect(channel.signed, isEmpty);
    });

    test('the database busy for a moment', () async {
      final result = await saveWith(
        useCase(stepsSource: () async => throw const DatabaseBusy('key-check')),
      );
      expect(result, isA<SaveBusy>());
      expect(channel.signed, isEmpty);
    });
  });

  test('signing fails: nothing is stored', () async {
    channel.failSign = true;
    expect(await saveWith(useCase()), isA<SaveSigningFailed>());
    expect(await saved(), isEmpty);
  });

  test('no screen lock at signing: its own result, nothing stored', () async {
    channel.noScreenLock = true;
    expect(await saveWith(useCase()), isA<SaveNoScreenLock>());
    expect(await saved(), isEmpty);
  });

  test('a step id already saved: a typed error, the first row kept', () async {
    final first = await saveWith(useCase(random: Random(7))) as SaveDone;
    final second = await saveWith(useCase(random: Random(7)));

    expect(second, isA<SaveDuplicateStepId>());
    expect((await saved()).single.stepId, first.stepId);
  });
}
