// Alert.fromJson and its parts: api.md's examples read as they are, and
// anything unreadable gives null (officer alerts plan, T1).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';

import '../../../fakes/fake_alerts_server.dart';

// docs/api.md, GET /alerts, 200 OK, copied as it is.
const apiListExample = '''
{
  "alerts": [
    {
      "id": "7a3e9b10-0000-4000-8000-000000000101",
      "type": "quantity_discrepancy",
      "severity": "medium",
      "status": "open",
      "details": {
        "weightMg": "1320000", "thresholdPercent": 10, "failedBaselines": ["registration"],
        "registration": { "stepId": "9d4e5f60-0000-4000-8000-000000000001", "weightMg": "1500000",
                          "differenceMg": "-180000", "exceeded": true }
      },
      "createdAt": "2026-11-15T09:00:01.120Z",
      "step": {
        "id": "9d4e5f60-0000-4000-8000-000000000002",
        "type": "handoff",
        "reviewStatus": "flagged",
        "anchorStatus": "pending",
        "capturedAt": "2026-11-15T08:55:00.000Z",
        "receivedAt": "2026-11-15T09:00:01.118Z"
      },
      "consignment": {
        "id": "5c0d7e21-0000-4000-8000-000000000001",
        "qrCode": "MC-2026-000123",
        "mineral": "gold",
        "stage": "registered",
        "held": true
      },
      "actor": { "id": "3f2b6c1e-0000-4000-8000-000000000002", "username": "bwalya_t", "role": "transporter" },
      "review": null
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0
}
''';

Map<String, Object?> exampleAlert() =>
    ((jsonDecode(apiListExample) as Map)['alerts'] as List).single
        as Map<String, Object?>;

void main() {
  group("api.md's example", () {
    test('reads every field', () {
      final alert = Alert.fromJson(exampleAlert())!;
      expect(alert.id, '7a3e9b10-0000-4000-8000-000000000101');
      expect(alert.type, AlertType.quantityDiscrepancy);
      expect(alert.severity, AlertSeverity.medium);
      expect(alert.status, AlertStatus.open);
      expect(alert.isOpen, isTrue);
      expect(alert.details['weightMg'], '1320000');
      expect(alert.createdAt, DateTime.utc(2026, 11, 15, 9, 0, 1, 120));
      expect(alert.createdAt.isUtc, isTrue);

      expect(alert.step.id, '9d4e5f60-0000-4000-8000-000000000002');
      expect(alert.step.type, StepType.handoff);
      expect(alert.step.reviewStatus, ReviewStatus.flagged);
      expect(alert.step.anchorStatus, AnchorStatus.pending);
      expect(alert.step.capturedAt, DateTime.utc(2026, 11, 15, 8, 55));
      expect(alert.step.receivedAt, DateTime.utc(2026, 11, 15, 9, 0, 1, 118));

      expect(alert.consignment.qrCode, 'MC-2026-000123');
      expect(alert.consignment.mineral, Mineral.gold);
      expect(alert.consignment.stage, ConsignmentStage.registered);
      expect(alert.consignment.held, isTrue);

      expect(alert.actor.username, 'bwalya_t');
      expect(alert.actor.role, Role.transporter);
      expect(alert.review, isNull);
      expect(alert.otherAlerts, isNull);
    });

    test('the detail example adds otherAlerts', () {
      final alert = Alert.fromJson({
        ...exampleAlert(),
        'otherAlerts': [
          {
            'id': '7a3e9b10-0000-4000-8000-000000000102',
            'type': 'gps_zone',
            'severity': 'medium',
            'status': 'dismissed',
            'stepId': '9d4e5f60-0000-4000-8000-000000000001',
            'createdAt': '2026-11-15T08:30:00.410Z',
          },
        ],
      })!;
      final other = alert.otherAlerts!.single;
      expect(other.type, AlertType.gpsZone);
      expect(other.status, AlertStatus.dismissed);
      expect(other.stepId, '9d4e5f60-0000-4000-8000-000000000001');
      expect(other.createdAt, DateTime.utc(2026, 11, 15, 8, 30, 0, 410));
    });

    test('a closed alert reads its review', () {
      final alert = Alert.fromJson(alertJson(1, status: 'dismissed'))!;
      expect(alert.isOpen, isFalse);
      expect(alert.review!.byUsername, 'officer_chanda');
      expect(alert.review!.byId, officerId);
      expect(alert.review!.notes, 'Weighed again at the depot.');
      expect(alert.review!.at, DateTime.utc(2026, 11, 20, 13));
    });

    test('extra fields are ignored', () {
      expect(Alert.fromJson({...exampleAlert(), 'later': 1}), isNotNull);
    });

    test('toString shows codes only, no QR code or username', () {
      final text = Alert.fromJson(exampleAlert()).toString();
      expect(text, contains('quantity_discrepancy'));
      expect(text, isNot(contains('MC-2026')));
      expect(text, isNot(contains('bwalya')));
    });
  });

  group('the type', () {
    for (final type in AlertType.values.where((t) => t != AlertType.unknown)) {
      test('${type.apiName} is known', () {
        final alert = Alert.fromJson({...exampleAlert(), 'type': type.apiName});
        expect(alert!.type, type);
      });
    }

    test('a type this app does not know is kept as unknown, not refused', () {
      final alert = Alert.fromJson({...exampleAlert(), 'type': 'new_check'});
      expect(alert!.type, AlertType.unknown);
    });

    test('an empty name is not mistaken for unknown\'s own spelling', () {
      expect(AlertType.fromApiName(''), AlertType.unknown);
    });
  });

  group('unreadable alerts give null', () {
    Map<String, Object?> without(String key) =>
        {...exampleAlert()}..remove(key);
    Map<String, Object?> withPart(String part, String key, Object? value) => {
      ...exampleAlert(),
      part: {...(exampleAlert()[part] as Map), key: value},
    };

    final cases = <String, Object?>{
      'not a map': 'alert',
      'no id': without('id'),
      'an empty id': {...exampleAlert(), 'id': ''},
      'no type': without('type'),
      'an unknown severity': {...exampleAlert(), 'severity': 'urgent'},
      'an unknown status': {...exampleAlert(), 'status': 'closed'},
      'details not a map': {...exampleAlert(), 'details': []},
      'a bad createdAt': {...exampleAlert(), 'createdAt': 'yesterday'},
      'no step': without('step'),
      'an unknown step type': withPart('step', 'type', 'relay'),
      'an unknown review status': withPart('step', 'reviewStatus', 'ok'),
      'an unknown anchor status': withPart('step', 'anchorStatus', 'done'),
      'a bad capturedAt': withPart('step', 'capturedAt', 5),
      'no consignment': without('consignment'),
      'an unknown mineral': withPart('consignment', 'mineral', 'silver'),
      'an unknown stage': withPart('consignment', 'stage', 'sold'),
      'held not a bool': withPart('consignment', 'held', 'yes'),
      'an empty QR code': withPart('consignment', 'qrCode', ''),
      'no actor': without('actor'),
      'an unknown role': withPart('actor', 'role', 'guard'),
      'no username': withPart('actor', 'username', null),
      'no review key': without('review'),
      'an open alert with a review': {
        ...exampleAlert(),
        'review': {
          'by': {'id': officerId, 'username': 'officer_chanda'},
          'notes': 'Done.',
          'at': '2026-11-20T13:00:00.000Z',
        },
      },
      'a closed alert without a review': {
        ...exampleAlert(),
        'status': 'reviewed',
      },
      'a review without notes': {
        ...alertJson(1, status: 'reviewed'),
        'review': {
          'by': {'id': officerId, 'username': 'officer_chanda'},
          'at': '2026-11-20T13:00:00.000Z',
        },
      },
      'otherAlerts not a list': {...exampleAlert(), 'otherAlerts': {}},
      'one unreadable other alert': {
        ...exampleAlert(),
        'otherAlerts': [
          {'id': 'x'},
        ],
      },
    };
    cases.forEach((name, json) {
      test(name, () => expect(Alert.fromJson(json), isNull));
    });
  });

  group('AlertDecisionResult', () {
    test("reads api.md's dismiss answer", () {
      final result = AlertDecisionResult.fromJson({
        'alert': {'id': alertId(1), 'status': 'dismissed'},
        'step': {'id': stepIdFor(1), 'reviewStatus': 'cleared'},
        'consignment': {
          'id': consignmentA,
          'stage': 'in_transit',
          'held': false,
        },
      });
      expect(result.stepStatus, ReviewStatus.cleared);
      expect(result.stage, ConsignmentStage.inTransit);
      expect(result.held, isFalse);
    });

    test('an odd answer gives nulls, never an error', () {
      for (final json in <Object?>[
        null,
        'ok',
        {'step': 'x', 'consignment': 3},
        {
          'step': {'reviewStatus': 'odd'},
          'consignment': {'stage': 'odd', 'held': 'no'},
        },
      ]) {
        final result = AlertDecisionResult.fromJson(json);
        expect(result.stepStatus, isNull);
        expect(result.stage, isNull);
        expect(result.held, isNull);
      }
    });
  });
}
