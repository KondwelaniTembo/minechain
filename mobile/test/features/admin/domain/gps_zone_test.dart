// GpsZone, its page and the deactivation warning read from api.md's examples
// (GPS zones plan, T1): every field, both statuses, no licence number, and
// anything unreadable refused rather than guessed.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/gps_zone.dart';

import '../../../fakes/fake_zones_server.dart';

void main() {
  group('GpsZone.fromJson', () {
    test("api.md's create example, every field", () {
      final zone = GpsZone.fromJson({
        'id': '7a1c2d3e-0000-4000-8000-0000000000aa',
        'name': 'Kasempa North',
        'licenceNumber': 'DEMO-LML-0001',
        'status': 'active',
        'boundary': [
          [-13.45, 25.82],
          [-13.47, 25.86],
          [-13.49, 25.81],
        ],
        'createdBy': '3f2b6c1e-0000-4000-8000-0000000000ad',
        'createdAt': '2026-11-10T09:00:00.000Z',
        'updatedAt': '2026-11-10T11:30:00.000Z',
      })!;
      expect(zone.id, '7a1c2d3e-0000-4000-8000-0000000000aa');
      expect(zone.name, 'Kasempa North');
      expect(zone.licenceNumber, 'DEMO-LML-0001');
      expect(zone.status, ZoneStatus.active);
      expect(zone.isActive, isTrue);
      expect(zone.boundary, const [
        ZoneCorner(-13.45, 25.82),
        ZoneCorner(-13.47, 25.86),
        ZoneCorner(-13.49, 25.81),
      ]);
      expect(zone.createdAt, DateTime.utc(2026, 11, 10, 9));
      expect(zone.updatedAt, DateTime.utc(2026, 11, 10, 11, 30));
    });

    test('inactive, and no licence number (null or empty)', () {
      final inactive = GpsZone.fromJson(
        zoneJson(1, status: 'inactive', licenceNumber: null),
      )!;
      expect(inactive.status, ZoneStatus.inactive);
      expect(inactive.isActive, isFalse);
      expect(inactive.licenceNumber, isNull);
      expect(
        GpsZone.fromJson(zoneJson(1, licenceNumber: ''))!.licenceNumber,
        isNull,
      );
    });

    test('whole-number corners are read as doubles', () {
      final zone = GpsZone.fromJson(
        zoneJson(
          1,
          boundary: const [
            [-13, 25],
            [-13.5, 26],
            [-14, 25],
          ],
        ),
      )!;
      expect(zone.boundary.first, const ZoneCorner(-13.0, 25.0));
    });

    final broken = <String, Map<String, Object?>>{
      'no id': {...zoneJson(1)}..remove('id'),
      'an empty name': {...zoneJson(1), 'name': ''},
      'an unknown status': {...zoneJson(1), 'status': 'pending'},
      'a licence number that is a number': {...zoneJson(1), 'licenceNumber': 7},
      'a bad time': {...zoneJson(1), 'createdAt': 'yesterday'},
      'no updatedAt': {...zoneJson(1)}..remove('updatedAt'),
      'no boundary': {...zoneJson(1)}..remove('boundary'),
      'two corners': {
        ...zoneJson(1),
        'boundary': [
          [-13.45, 25.82],
          [-13.47, 25.86],
        ],
      },
      'a corner of three numbers': {
        ...zoneJson(1),
        'boundary': [
          [-13.45, 25.82, 1],
          [-13.47, 25.86],
          [-13.49, 25.81],
        ],
      },
      'a corner sent as text': {
        ...zoneJson(1),
        'boundary': [
          ['-13.45', '25.82'],
          [-13.47, 25.86],
          [-13.49, 25.81],
        ],
      },
    };
    broken.forEach((what, json) {
      test('$what: unreadable', () => expect(GpsZone.fromJson(json), isNull));
    });

    test('not a map: unreadable', () {
      expect(GpsZone.fromJson(null), isNull);
      expect(GpsZone.fromJson('zone'), isNull);
    });

    test('toString() holds no name, licence number or corner', () {
      final zone = GpsZone.fromJson(zoneJson(1, name: 'Kasempa North'))!;
      final text = '$zone ${zone.boundary.first}';
      expect(text, 'GpsZone(status: active, corners: 3) ZoneCorner(hidden)');
      expect(text, isNot(contains('Kasempa')));
      expect(text, isNot(contains('13.45')));
      expect(text, isNot(contains('DEMO')));
    });
  });

  group('ZoneWarning.fromJson', () {
    test('null or absent: no warning', () {
      expect(ZoneWarning.fromJson(null), isNull);
    });

    test("api.md's NO_ACTIVE_ZONES", () {
      final warning = ZoneWarning.fromJson({
        'code': 'NO_ACTIVE_ZONES',
        'message': noActiveZonesMessage,
      })!;
      expect(warning.code, 'NO_ACTIVE_ZONES');
      expect(warning.message, noActiveZonesMessage);
    });

    test('an unreadable warning is still a warning, never missed', () {
      for (final json in <Object>['oops', 3, <String, Object?>{}]) {
        final warning = ZoneWarning.fromJson(json);
        expect(warning, isNotNull, reason: '$json');
        expect(warning!.message, isNull);
      }
      expect(
        ZoneWarning.fromJson({'code': 'NO_ACTIVE_ZONES', 'message': '  '})!
            .message,
        isNull,
      );
    });
  });

  test('ZoneCorner.toJson is [latitude, longitude]', () {
    expect(const ZoneCorner(-15.418327, 28.289494).toJson(), [
      -15.418327,
      28.289494,
    ]);
  });
}
