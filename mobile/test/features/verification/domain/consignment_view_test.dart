// ConsignmentView.fromJson against docs/api.md, "GET /consignments/by-qr":
// the example body, each viewer's field set from "What each viewer sees",
// absent vs null, and the strict refusals.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';

const _hash =
    '0xccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0';

/// The api.md example step, as an officer sees it.
Map<String, Object?> officerStep() => {
  'id': '9d4e5f60-0000-4000-8000-000000000001',
  'type': 'registration',
  'byYou': false,
  'actor': {'role': 'miner', 'username': 'mutale_banda'},
  'weightMg': '1500000',
  'location': {'latitude': '-15.419012', 'longitude': '28.288105'},
  'zoneName': 'ZCAS Campus (demo)',
  'capturedAt': '2026-11-10T08:00:00.000Z',
  'receivedAt': '2026-11-10T08:05:01.118Z',
  'anchor': {'status': 'confirmed', 'chainTxHash': _hash},
  'check': {'result': 'match'},
  'reviewStatus': 'passed',
  'alerts': <Object?>[],
  'evidence': {
    'signedPayload': 'minechain-step/1/registration\nstep_id=…\n',
    'signature': 'MEQCIF…FAKE…==',
    'signerPublicKey': 'MFkwEw…FAKE…==',
  },
};

/// A step with only what a blind transporter gets (the disclosure table's
/// last column): no weight, no location, no username, no hash.
Map<String, Object?> blindTransporterStep() => {
  'id': '9d4e5f60-0000-4000-8000-000000000001',
  'type': 'registration',
  'byYou': false,
  'actor': {'role': 'miner'},
  'zoneName': 'ZCAS Campus (demo)',
  'capturedAt': '2026-11-10T08:00:00.000Z',
  'receivedAt': '2026-11-10T08:05:01.118Z',
  'anchor': {'status': 'confirmed'},
  'check': {'result': 'match'},
};

Map<String, Object?> body({
  List<Map<String, Object?>>? steps,
  Map<String, Object?> consignment = const {},
}) => {
  'consignment': {
    'id': '5c0d7e21-0000-4000-8000-000000000001',
    'qrCode': 'MC-2026-000123',
    'mineral': 'gold',
    'stage': 'purchased',
    'held': false,
    'weightsHidden': false,
    ...consignment,
  },
  'steps': steps ?? [officerStep()],
};

/// [step] with [key] removed.
Map<String, Object?> without(Map<String, Object?> step, String key) =>
    Map.of(step)..remove(key);

void main() {
  group('the api.md example (an officer)', () {
    late ConsignmentView view;
    setUp(() => view = ConsignmentView.fromJson(body())!);

    test('the consignment', () {
      expect(view.id, '5c0d7e21-0000-4000-8000-000000000001');
      expect(view.qrCode, 'MC-2026-000123');
      expect(view.mineral, Mineral.gold);
      expect(view.stage, ConsignmentStage.purchased);
      expect(view.held, isFalse);
      expect(view.weightsHidden, isFalse);
      expect(view.steps, hasLength(1));
    });

    test('every field of the step, values kept as text', () {
      final step = view.steps.single;
      expect(step.type, StepType.registration);
      expect(step.byYou, isFalse);
      expect(step.actor.role, Role.miner);
      expect(step.actor.username, 'mutale_banda');
      expect(step.weightMg, '1500000');
      expect(step.location!.latitude, '-15.419012');
      expect(step.location!.longitude, '28.288105');
      expect(step.zoneName, 'ZCAS Campus (demo)');
      expect(step.capturedAt, DateTime.utc(2026, 11, 10, 8));
      expect(step.capturedAt.isUtc, isTrue);
      expect(step.receivedAt, DateTime.utc(2026, 11, 10, 8, 5, 1, 118));
      expect(step.anchorStatus, AnchorStatus.confirmed);
      expect(step.chainTxHashShown, isTrue);
      expect(step.chainTxHash, _hash);
      expect(step.check, CheckResult.match);
      expect(step.mismatchFields, isNull);
      expect(step.reviewStatus, ReviewStatus.passed);
      expect(step.alerts, isEmpty);
    });

    test('toString holds no QR code, username or weight', () {
      final text = '$view ${view.steps.single}';
      expect(text, isNot(contains('MC-2026')));
      expect(text, isNot(contains('mutale')));
      expect(text, isNot(contains('1500000')));
    });
  });

  group('each viewer\'s fields (api.md "What each viewer sees")', () {
    test('a blind transporter: role only, no weight, location or hash', () {
      final view = ConsignmentView.fromJson(
        body(
          steps: [blindTransporterStep()],
          consignment: {'stage': 'in_transit', 'weightsHidden': true},
        ),
      )!;
      final step = view.steps.single;
      expect(view.weightsHidden, isTrue);
      expect(step.actor.role, Role.miner);
      expect(step.actor.username, isNull);
      expect(step.weightMg, isNull);
      expect(step.location, isNull);
      expect(step.zoneName, 'ZCAS Campus (demo)');
      expect(step.chainTxHashShown, isFalse);
      expect(step.chainTxHash, isNull);
      expect(step.check, CheckResult.match);
      expect(step.reviewStatus, isNull);
      expect(step.alerts, isNull);
    });

    test('a transporter who has handed off: weight and hash, no names', () {
      final step = Map.of(blindTransporterStep())
        ..['weightMg'] = '1500000'
        ..['anchor'] = {'status': 'confirmed', 'chainTxHash': _hash};
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!
          .steps
          .single;
      expect(parsed.weightMg, '1500000');
      expect(parsed.chainTxHash, _hash);
      expect(parsed.actor.username, isNull);
      expect(parsed.location, isNull);
    });

    test('any buyer in transit: usernames, weight, hash; no location, no '
        'review status', () {
      final step = without(
        without(without(officerStep(), 'location'), 'alerts'),
        'reviewStatus',
      )..remove('evidence');
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!
          .steps
          .single;
      expect(parsed.actor.username, 'mutale_banda');
      expect(parsed.weightMg, '1500000');
      expect(parsed.location, isNull);
      expect(parsed.reviewStatus, isNull);
      expect(parsed.alerts, isNull);
    });

    test('the owning buyer: location too, still no review status', () {
      final step = without(without(officerStep(), 'alerts'), 'reviewStatus');
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!
          .steps
          .single;
      expect(parsed.location, isNotNull);
      expect(parsed.reviewStatus, isNull);
    });

    test('an officer on a mismatch: field names and the reason', () {
      final step = Map.of(officerStep())
        ..['check'] = {
          'result': 'mismatch',
          'fields': ['chain_tx_hash'],
          'reason': 'TX_NOT_FOUND',
        }
        ..['reviewStatus'] = 'flagged'
        ..['alerts'] = [
          {'id': 'a1', 'type': 'record_tampered', 'status': 'open'},
        ];
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!
          .steps
          .single;
      expect(parsed.check, CheckResult.mismatch);
      expect(parsed.mismatchFields, ['chain_tx_hash']);
      expect(parsed.mismatchReason, 'TX_NOT_FOUND');
      expect(parsed.reviewStatus, ReviewStatus.flagged);
      expect(parsed.alerts!.single.type, 'record_tampered');
    });
  });

  group('absent is not null', () {
    test('zoneName null means outside every zone, and is accepted', () {
      final step = Map.of(officerStep())..['zoneName'] = null;
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!;
      expect(parsed.steps.single.zoneName, isNull);
    });

    test('zoneName absent is refused: every viewer gets it', () {
      expect(
        ConsignmentView.fromJson(
          body(steps: [without(officerStep(), 'zoneName')]),
        ),
        isNull,
      );
    });

    test('chainTxHash null means not sent yet, and is shown as such', () {
      final step = Map.of(officerStep())
        ..['anchor'] = {'status': 'pending', 'chainTxHash': null}
        ..['check'] = {'result': 'not_anchored_yet'};
      final parsed = ConsignmentView.fromJson(body(steps: [step]))!
          .steps
          .single;
      expect(parsed.chainTxHashShown, isTrue);
      expect(parsed.chainTxHash, isNull);
      expect(parsed.anchorStatus, AnchorStatus.pending);
      expect(parsed.check, CheckResult.notAnchoredYet);
    });
  });

  group('every API spelling is understood', () {
    for (final stage in ConsignmentStage.values) {
      test('stage ${stage.apiName}', () {
        final view = ConsignmentView.fromJson(
          body(consignment: {'stage': stage.apiName}),
        );
        expect(view!.stage, stage);
      });
    }
    for (final result in CheckResult.values) {
      test('check ${result.apiName}', () {
        final step = Map.of(officerStep())
          ..['check'] = {'result': result.apiName};
        expect(
          ConsignmentView.fromJson(body(steps: [step]))!.steps.single.check,
          result,
        );
      });
    }
    for (final type in StepType.values) {
      test('type ${type.name}', () {
        final step = Map.of(officerStep())..['type'] = type.name;
        expect(
          ConsignmentView.fromJson(body(steps: [step]))!.steps.single.type,
          type,
        );
      });
    }
  });

  group('refused: the whole answer is unreadable', () {
    final cases = <String, Object? Function()>{
      'not a map': () => [],
      'no steps list': () => body()..remove('steps'),
      'an unknown stage': () => body(consignment: {'stage': 'exported'}),
      'an unknown mineral': () => body(consignment: {'mineral': 'diamond'}),
      'held as text': () => body(consignment: {'held': 'false'}),
      'an unknown check result': () => body(
        steps: [
          Map.of(officerStep())..['check'] = {'result': 'probably_fine'},
        ],
      ),
      'no check': () => body(steps: [without(officerStep(), 'check')]),
      'an unknown step type': () =>
          body(steps: [Map.of(officerStep())..['type'] = 'export']),
      'an unknown actor role': () => body(
        steps: [
          Map.of(officerStep())..['actor'] = {'role': 'smuggler'},
        ],
      ),
      'a weight as a number': () =>
          body(steps: [Map.of(officerStep())..['weightMg'] = 1500000]),
      'a weight with a decimal point': () =>
          body(steps: [Map.of(officerStep())..['weightMg'] = '1500.5']),
      'a weight sent as null': () =>
          body(steps: [Map.of(officerStep())..['weightMg'] = null]),
      'a latitude as a number': () => body(
        steps: [
          Map.of(officerStep())
            ..['location'] = {'latitude': -15.419012, 'longitude': '28.288105'},
        ],
      ),
      'a malformed hash': () => body(
        steps: [
          Map.of(officerStep())
            ..['anchor'] = {'status': 'confirmed', 'chainTxHash': '0x1234'},
        ],
      ),
      'an unknown anchor status': () => body(
        steps: [
          Map.of(officerStep())..['anchor'] = {'status': 'mined'},
        ],
      ),
      'an unreadable capture time': () =>
          body(steps: [Map.of(officerStep())..['capturedAt'] = 'yesterday']),
      'an unknown review status': () =>
          body(steps: [Map.of(officerStep())..['reviewStatus'] = 'ok']),
      'mismatch fields that are not text': () => body(
        steps: [
          Map.of(officerStep())
            ..['check'] = {
              'result': 'mismatch',
              'fields': [1],
            },
        ],
      ),
      'one good step and one bad one': () => body(
        steps: [officerStep(), Map.of(officerStep())..['type'] = 'export'],
      ),
    };
    cases.forEach((name, make) {
      test(name, () => expect(ConsignmentView.fromJson(make()), isNull));
    });
  });

  test('extra fields are ignored', () {
    final step = Map.of(officerStep())..['newField'] = 1;
    final json = body(steps: [step])..['meta'] = {'v': 2};
    expect(ConsignmentView.fromJson(json), isNotNull);
  });

  test('no steps is a readable answer', () {
    final view = ConsignmentView.fromJson(
      body(steps: [], consignment: {'held': true}),
    );
    expect(view!.steps, isEmpty);
  });
}
