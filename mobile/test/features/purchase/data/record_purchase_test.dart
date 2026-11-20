// RecordPurchase.save with a fake Keystore that "signs" by recording the
// bytes, and the real repository on an in-memory database (the phone's
// schema, no cipher). The shared parts of the save are covered once, in
// register_consignment_test.dart and record_handoff_test.dart; here, what
// a purchase has of its own, plus refusals to show it takes the same path.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';
import 'package:minechain/features/device_key/domain/key_fingerprint.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/purchase/data/record_purchase.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';
import '../../../fakes/signing_channel.dart';

final buyer = userOf(Role.buyer);
final alias = deviceKeyAlias(buyer.id);
final phoneKey = fakeKey(5);
final phoneFingerprint = keyFingerprint(phoneKey);
final now = DateTime.utc(2026, 11, 20, 16, 10, 2, 340, 900);

late SigningChannel channel;
late InMemoryLocalDatabase database;
late LocalStepsRepository steps;

RecordPurchase useCase({DeviceKeyState? keyState}) => RecordPurchase(
  channel: channel,
  steps: () async => steps,
  keyState: () => keyState ?? DeviceKeyReady(phoneFingerprint),
  clock: () => now,
);

Future<SaveResult> saveWith(
  RecordPurchase purchase, {
  Mineral mineral = Mineral.copper,
  String weightMg = '1900000',
}) => purchase.save(
  user: buyer,
  qrCode: 'MC-2026-LSK-0007',
  mineral: mineral,
  weightMg: weightMg,
  latitude: -15.4193001,
  longitude: 28.2877999,
  gpsAccuracyM: 6,
);

Future<List<LocalStep>> saved() => steps.listForActor(buyer.id);

void main() {
  setUp(() {
    channel = SigningChannel(keys: {alias: phoneKey});
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
  });
  tearDown(() => database.close());

  test('a 1.9 kg copper bag: one purchase row, queued, the 8-line payload '
      'under the purchase header', () async {
    final result = await saveWith(useCase()) as SaveDone;

    final row = (await saved()).single;
    expect(row.type, 'purchase');
    expect(row.actorId, buyer.id);
    expect(row.syncState, SyncState.queued);
    expect(
      row.payload,
      'minechain-step/1/purchase\n'
      'step_id=${result.stepId}\n'
      'actor_id=${buyer.id}\n'
      'qr_code=MC-2026-LSK-0007\n'
      'weight_mg=1900000\n'
      'latitude=-15.419300\n'
      'longitude=28.287800\n'
      // The clock's 340 ms 900 µs, truncated.
      'captured_at=2026-11-20T16:10:02.340Z\n',
    );
  });

  test('the stored payload is exactly the bytes that were signed', () async {
    await saveWith(useCase());

    final row = (await saved()).single;
    expect(utf8.encode(row.payload), channel.signed.single);
    expect(base64.decode(row.signature), SigningChannel.signature);
    expect(row.keyFingerprint, phoneFingerprint);
  });

  test('the mineral is kept only as the unsigned hint', () async {
    await saveWith(useCase(), mineral: Mineral.gold, weightMg: '15300');

    final row = (await saved()).single;
    expect(row.mineral, isNull);
    expect(row.mineralHint, 'gold');
    expect(row.payload, isNot(contains('mineral')));
    expect(row.gpsAccuracyM, 6);
  });

  test('"My purchases" reads it back; the sync offers it', () async {
    final result = await saveWith(useCase()) as SaveDone;

    final item = (await steps.listOfTypeForActor(buyer.id, 'purchase')).single;
    expect(item.mineral, 'copper');
    expect(item.weightMg, '1900000');
    final due = await steps.dueForSync(actorId: buyer.id, now: now);
    expect(due.map((s) => s.stepId), [result.stepId]);
  });

  test('the "already recorded" lookup finds it as a purchase only', () async {
    await saveWith(useCase());

    expect(
      await steps.firstStepOn('MC-2026-LSK-0007', buyer.id, 'purchase'),
      DateTime.utc(2026, 11, 20, 16, 10, 2, 340),
    );
    expect(await steps.handedOffOn('MC-2026-LSK-0007', buyer.id), isNull);
  });

  test(
    'a phone that may not sign: refused, nothing signed or stored',
    () async {
      expect(
        await saveWith(useCase(keyState: const DeviceKeyOtherDevice())),
        isA<SaveKeyNotUsable>(),
      );
      expect(channel.signed, isEmpty);
      expect(await saved(), isEmpty);
    },
  );

  test('no screen lock at signing: its own result, nothing stored', () async {
    channel.refuse = DeviceKeyError.noScreenLock;
    expect(await saveWith(useCase()), isA<SaveNoScreenLock>());
    expect(await saved(), isEmpty);
  });

  test('a weight that is not whole milligrams: refused by field', () async {
    final result = await saveWith(useCase(), weightMg: '1.9');
    expect((result as SaveInvalidField).field, 'weight_mg');
    expect(channel.signed, isEmpty);
  });
}
