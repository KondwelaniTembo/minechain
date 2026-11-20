// The words for each alert type (officer alerts plan §4, T1): headings,
// severities and the sentences from `details`, with weights in the
// mineral's unit worked out from milligram text.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/alerts/presentation/alert_words.dart';

import '../../../fakes/fake_alerts_server.dart';

Alert alertOf(
  String type,
  Map<String, Object?> details, {
  String stepType = 'handoff',
  String mineral = 'copper',
}) => Alert.fromJson(
  alertJson(
    1,
    type: type,
    details: details,
    stepType: stepType,
    mineral: mineral,
  ),
)!;

List<String> findings(
  String type,
  Map<String, Object?> details, {
  String stepType = 'handoff',
  String mineral = 'copper',
}) =>
    alertFindings(alertOf(type, details, stepType: stepType, mineral: mineral));

Map<String, Object?> baseline(
  String weightMg,
  String differenceMg, {
  bool exceeded = true,
}) => {
  'stepId': stepIdFor(0),
  'weightMg': weightMg,
  'differenceMg': differenceMg,
  'exceeded': exceeded,
};

void main() {
  test('a heading for every type', () {
    expect(alertHeading(AlertType.quantityDiscrepancy), AppText.alertQuantity);
    expect(
      alertHeading(AlertType.duplicateConsignment),
      AppText.alertDuplicate,
    );
    expect(alertHeading(AlertType.gpsZone), AppText.alertGpsZone);
    expect(alertHeading(AlertType.invalidSignature), AppText.alertSignature);
    expect(alertHeading(AlertType.handoffOrder), AppText.alertHandoffOrder);
    expect(alertHeading(AlertType.recordTampered), AppText.alertTampered);
    expect(alertHeading(AlertType.unknown), AppText.alertUnknown);
  });

  test('severities as words', () {
    expect(severityWord(AlertSeverity.high), 'High');
    expect(severityWord(AlertSeverity.medium), 'Medium');
    expect(severityWord(AlertSeverity.low), 'Low');
  });

  group('quantity_discrepancy', () {
    test("MC-2026-LSK-0008's handoff, in kilograms (plan §4)", () {
      expect(findings('quantity_discrepancy', quantityDetails()), [
        'This handoff: 1.6 kg.',
        'The registration: 2 kg. This handoff is 0.4 kg (20%) lighter.',
      ]);
    });

    test('a purchase in grams, heavier, with one decimal of a percent', () {
      expect(
        findings(
          'quantity_discrepancy',
          {
            'weightMg': '166000',
            'thresholdPercent': 10,
            'failedBaselines': ['registration'],
            'registration': baseline('150000', '16000'),
          },
          stepType: 'purchase',
          mineral: 'gold',
        ),
        [
          'This purchase: 166 g.',
          'The registration: 150 g. This purchase is 16 g (10.6%) heavier.',
        ],
      );
    });

    test("database-schema.md's example: the failed previous step first, the "
        'registration within the limit after it', () {
      expect(
        findings('quantity_discrepancy', {
          'weightMg': '1460000',
          'thresholdPercent': 10,
          'failedBaselines': ['previous'],
          'previous': baseline('1640000', '-180000'),
          'registration': baseline('1500000', '-40000', exceeded: false),
        }),
        [
          'This handoff: 1.46 kg.',
          // 180000 / 1640000 = 10.97...%, cut to 10.9%, never rounded up.
          'The previous step: 1.64 kg. This handoff is 0.18 kg (10.9%) '
              'lighter.',
          'The registration: 1.5 kg. This handoff is 0.04 kg (2.6%) '
              'lighter, within the 10% allowed.',
        ],
      );
    });

    test('a flagged difference that would read "10%" says "more than 10%"', () {
      // 200001 / 2000000 = 10.00005%.
      expect(
        findings('quantity_discrepancy', {
          'weightMg': '1799999',
          'thresholdPercent': 10,
          'failedBaselines': ['registration'],
          'registration': baseline('2000000', '-200001'),
        })[1],
        'The registration: 2 kg. This handoff is 0.200001 kg (more than 10%) '
        'lighter.',
      );
    });

    test('the same weight as a baseline', () {
      expect(
        findings('quantity_discrepancy', {
          'weightMg': '2000000',
          'thresholdPercent': 10,
          'failedBaselines': ['previous'],
          'previous': baseline('1700000', '300000'),
          'registration': baseline('2000000', '0', exceeded: false),
        }),
        [
          'This handoff: 2 kg.',
          'The previous step: 1.7 kg. This handoff is 0.3 kg (17.6%) heavier.',
          'The registration: 2 kg, the same weight.',
        ],
      );
    });

    for (final (name, details) in <(String, Map<String, Object?>)>[
      ('no weight', {...quantityDetails()}..remove('weightMg')),
      ('a weight as a number', {...quantityDetails(), 'weightMg': 1600000}),
      (
        'a weight with a decimal point',
        {...quantityDetails(), 'weightMg': '1.6'},
      ),
      ('no threshold', {...quantityDetails()}..remove('thresholdPercent')),
      ('no failedBaselines', {...quantityDetails()}..remove('failedBaselines')),
      (
        'no baseline at all',
        {
          'weightMg': '1600000',
          'thresholdPercent': 10,
          'failedBaselines': <String>[],
        },
      ),
      (
        'a zero baseline',
        {...quantityDetails(), 'registration': baseline('0', '1600000')},
      ),
      (
        'a difference that is not digits',
        {
          ...quantityDetails(),
          'registration': baseline('2000000', 'minus 400000'),
        },
      ),
      (
        'exceeded not a bool',
        {
          ...quantityDetails(),
          'registration': {
            ...baseline('2000000', '-400000'),
            'exceeded': 'yes',
          },
        },
      ),
    ]) {
      test('$name -> the fallback sentence', () {
        expect(findings('quantity_discrepancy', details), [
          AppText.alertDetailsUnreadable,
        ]);
      });
    }
  });

  group('gps_zone', () {
    test('outside the nearest zone', () {
      expect(
        findings('gps_zone', {
          'nearestZoneId': '5c0d7e21-0000-4000-8000-000000000001',
          'nearestZoneName': 'ZCAS Campus (demo)',
          'distanceMetres': 142,
          'toleranceMetres': 25,
        }, stepType: 'registration'),
        ['142 m outside ZCAS Campus (demo); 25 m is allowed.'],
      );
    });

    test('no zone active', () {
      expect(
        findings('gps_zone', {
          'noActiveZones': true,
          'toleranceMetres': 25,
        }, stepType: 'registration'),
        [AppText.noZoneActive],
      );
    });

    test('a distance as text -> the fallback sentence', () {
      expect(
        findings('gps_zone', {
          'nearestZoneName': 'ZCAS Campus (demo)',
          'distanceMetres': '142',
          'toleranceMetres': 25,
        }),
        [AppText.alertDetailsUnreadable],
      );
    });
  });

  group('duplicate_consignment', () {
    Map<String, Object?> duplicate({
      bool sameMiner = false,
      String mineral = 'gold',
      String originalMineral = 'gold',
    }) => {
      'originalTransactionId': stepIdFor(0),
      'originalReviewStatus': 'passed',
      'sameMiner': sameMiner,
      'mineral': mineral,
      'originalMineral': originalMineral,
    };

    test('by another miner, the same mineral', () {
      expect(findings('duplicate_consignment', duplicate()), [
        'Registered before by another miner.',
      ]);
    });

    test('by the same miner', () {
      expect(findings('duplicate_consignment', duplicate(sameMiner: true)), [
        'Registered before by the same miner.',
      ]);
    });

    test('both minerals when they differ', () {
      expect(
        findings(
          'duplicate_consignment',
          duplicate(mineral: 'copper', originalMineral: 'cobalt'),
        ),
        [
          'Registered before by another miner.',
          'This registration says Copper; the first one said Cobalt.',
        ],
      );
    });

    test('no sameMiner -> the fallback sentence', () {
      expect(
        findings(
          'duplicate_consignment',
          {...duplicate()}..remove('sameMiner'),
        ),
        [AppText.alertDetailsUnreadable],
      );
    });
  });

  group('invalid_signature', () {
    test('names the first 8 characters of the key fingerprint', () {
      expect(
        findings('invalid_signature', {
          'keyFingerprint': '50a035283b1f0c9e3b1f0c9e3b1f0c9e3b1f0c9e3b1f0c9e3b1f0c9e3b1f0c9e',
        }),
        [
          "The signature was not made by this account's registered device "
              'key (50a03528).',
        ],
      );
    });

    test('a fingerprint that is not 64 hex characters -> the fallback', () {
      expect(findings('invalid_signature', {'keyFingerprint': '50a03528'}), [
        AppText.alertDetailsUnreadable,
      ]);
    });
  });

  group('handoff_order', () {
    final details = {'consignmentStage': 'purchased', 'stepType': 'handoff'};

    test('a handoff', () {
      expect(findings('handoff_order', details), [
        AppText.handoffAfterPurchase,
      ]);
    });

    test('a second purchase', () {
      expect(findings('handoff_order', details, stepType: 'purchase'), [
        AppText.purchaseAfterPurchase,
      ]);
    });
  });

  group('record_tampered', () {
    Map<String, Object?> tampered(List<Object?> fields) => {
      'source': 'verification',
      'fields': fields,
      'chainTxHash': '0x${'c0' * 32}',
    };

    test('one field', () {
      expect(findings('record_tampered', tampered(['weight_mg'])), [
        'The weight no longer matches the blockchain.',
      ]);
    });

    test('several, each word once, unknown names last', () {
      expect(
        findings(
          'record_tampered',
          tampered([
            'later_field',
            'weight_mg',
            'latitude',
            'longitude',
            'receipt.status',
            'event.weightMg',
          ]),
        ),
        [
          'The weight, location, blockchain receipt and other details no '
              'longer match the blockchain.',
        ],
      );
    });

    test('no fields named', () {
      expect(findings('record_tampered', tampered([])), [
        'Something in this record no longer matches the blockchain.',
      ]);
    });

    test('a field that is not text -> the fallback', () {
      expect(findings('record_tampered', tampered([3])), [
        AppText.alertDetailsUnreadable,
      ]);
    });
  });

  test('an unknown type -> the fallback sentence', () {
    expect(findings('new_check', {'anything': 1}), [
      AppText.alertDetailsUnreadable,
    ]);
  });
}
