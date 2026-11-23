// Reading GET /dashboard's answer strictly (dashboard plan, T3), and grouping
// its days into weeks.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/dashboard/domain/dashboard_summary.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart'
    show ConsignmentStage, StepType;

import '../../../fakes/fake_dashboard_server.dart';

/// [json] with [path]'s value replaced by [value] (or removed when [remove]).
Map<String, Object?> changed(
  Map<String, Object?> json,
  List<Object> path,
  Object? value, {
  bool remove = false,
}) {
  Object? copy(Object? v) => switch (v) {
    Map() => {for (final e in v.entries) e.key as String: copy(e.value)},
    List() => [for (final e in v) copy(e)],
    _ => v,
  };
  final root = copy(json) as Map<String, Object?>;
  Object? node = root;
  for (final key in path.take(path.length - 1)) {
    node = node is Map ? node[key] : (node as List)[key as int];
  }
  final last = path.last;
  if (node is Map) {
    if (remove) {
      node.remove(last);
    } else {
      node[last] = value;
    }
  } else {
    (node as List)[last as int] = value;
  }
  return root;
}

void main() {
  test('reads api.md-style example in full', () {
    final summary = DashboardSummary.fromJson(dashboardJson())!;

    expect(summary.from, DateTime.utc(2026, 11, 17));
    expect(summary.to, DateTime.utc(2026, 11, 23));
    expect(summary.days, 7);
    expect(summary.mineral, isNull);
    expect(summary.openAlerts, 8);
    expect(summary.consignments, {
      ConsignmentStage.registered: 4,
      ConsignmentStage.inTransit: 3,
      ConsignmentStage.purchased: 2,
    });
    expect(summary.steps.total, 21);
    expect(summary.steps.of(StepType.registration), 9);
    expect(summary.steps.of(StepType.handoff), 7);
    expect(summary.steps.of(StepType.purchase), 5);
    expect(summary.registeredWeightMg, '18500000');
    expect(summary.byDay.map((d) => d.start.day), [17, 18, 19, 20, 21, 22, 23]);
    expect(summary.byDay[3].steps.total, 8);
    expect(summary.byDay.every((d) => d.days == 1), isTrue);
    expect(summary.byMineral.map((m) => m.mineral), [
      Mineral.gold,
      Mineral.copper,
    ]);
    expect(summary.byMineral.first.registeredWeightMg, '6500000');
    expect(summary.byZone.single.zoneName, 'ZCAS Campus (demo)');
    expect(summary.byZone.single.active, isTrue);
    expect(summary.outsideZones, 6);
    expect(summary.anomalies.total, 5);
    expect(summary.anomalies.open, 3);
    expect(summary.anomalies.byType[AlertType.quantityDiscrepancy], 2);
    expect(summary.anomalies.byType[AlertType.unknown], 0);
    expect(summary.anomalies.bySeverity, {
      AlertSeverity.low: 0,
      AlertSeverity.medium: 3,
      AlertSeverity.high: 2,
    });
    expect(summary.isEmpty, isFalse);
  });

  test('an empty period: every day, zeros, no rows', () {
    final summary = DashboardSummary.fromJson(emptyDashboardJson())!;

    expect(summary.isEmpty, isTrue);
    expect(summary.byDay, hasLength(7));
    expect(summary.byMineral, isEmpty);
    expect(summary.byZone, isEmpty);
    expect(summary.registeredWeightMg, '0');
  });

  test('the mineral asked for, and a deactivated zone', () {
    final summary = DashboardSummary.fromJson(
      dashboardJson(
        mineral: 'cobalt',
        byZone: [
          {
            'zoneId': dashboardZoneId(2),
            'zoneName': 'Old Site',
            'active': false,
            'steps': 3,
          },
        ],
      ),
    )!;

    expect(summary.mineral, Mineral.cobalt);
    expect(summary.byZone.single.active, isFalse);
  });

  test('keeps what a newer server may add: an alert type and a mineral', () {
    final json = dashboardJson(
      byType: const {
        'duplicate_consignment': 1,
        'quantity_discrepancy': 2,
        'gps_zone': 1,
        'invalid_signature': 0,
        'handoff_order': 1,
        'record_tampered': 0,
        'price_outlier': 4,
      },
      byMineral: const [
        {'mineral': 'lithium', 'steps': 2, 'registeredWeightMg': '900'},
      ],
    );

    final summary = DashboardSummary.fromJson(json)!;

    expect(summary.anomalies.byType[AlertType.unknown], 4);
    expect(summary.byMineral.single.mineral, isNull);
    expect(summary.byMineral.single.apiName, 'lithium');
  });

  test('keeps a weight past 2^53 milligrams as text', () {
    final summary = DashboardSummary.fromJson(
      dashboardJson(registeredWeightMg: '12000000000000002'),
    )!;

    expect(summary.registeredWeightMg, '12000000000000002');
  });

  group('refuses an answer that is not the documented shape', () {
    final good = dashboardJson();
    final cases = <String, Map<String, Object?> Function()>{
      'no period': () => changed(good, ['period'], null, remove: true),
      'an unreal day': () => changed(good, ['period', 'from'], '2026-11-31'),
      'days not matching the period': () =>
          changed(good, ['period', 'days'], 8),
      'a mineral that is a number': () => changed(good, ['mineral'], 3),
      'no open alerts count': () =>
          changed(good, ['now', 'openAlerts'], null, remove: true),
      'a negative count': () => changed(good, ['now', 'openAlerts'], -1),
      'a stage missing': () => changed(
        good,
        ['now', 'consignments', 'in_transit'],
        null,
        remove: true,
      ),
      'a total that is not the sum': () =>
          changed(good, ['steps', 'total'], 22),
      'a weight as a JSON number': () =>
          changed(good, ['registeredWeightMg'], 18500000),
      'a weight with a point': () =>
          changed(good, ['registeredWeightMg'], '18.5'),
      'a day missing from byDay': () =>
          changed(good, ['byDay'], (good['byDay'] as List).sublist(1)),
      'days out of order': () =>
          changed(good, ['byDay', 0, 'day'], '2026-11-18'),
      'a day count that is a string': () =>
          changed(good, ['byDay', 2, 'handoff'], '1'),
      'a mineral row without its weight': () => changed(
        good,
        ['byMineral', 0, 'registeredWeightMg'],
        null,
        remove: true,
      ),
      'a zone without "active"': () =>
          changed(good, ['byZone', 0, 'active'], null, remove: true),
      'no outsideZones': () =>
          changed(good, ['outsideZones'], null, remove: true),
      'more open alerts than raised': () =>
          changed(good, ['anomalies', 'open'], 6),
      'a known alert type missing': () => changed(
        good,
        ['anomalies', 'byType', 'gps_zone'],
        null,
        remove: true,
      ),
      'a new alert type with a bad count': () =>
          changed(good, ['anomalies', 'byType', 'price_outlier'], 'many'),
      'a severity missing': () =>
          changed(good, ['anomalies', 'bySeverity', 'low'], null, remove: true),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(DashboardSummary.fromJson(entry.value()), isNull);
      });
    }
    test('not a map', () {
      expect(DashboardSummary.fromJson(['period']), isNull);
      expect(DashboardSummary.fromJson(null), isNull);
    });
  });

  group('grouped', () {
    test('one day per bar is the days themselves', () {
      final summary = DashboardSummary.fromJson(dashboardJson())!;
      expect(summary.grouped(1), same(summary.byDay));
    });

    test('weeks from the first day, the days left over in the last bar', () {
      final summary = DashboardSummary.fromJson(
        dashboardJson(
          from: '2026-11-15',
          to: '2026-11-23',
          steps: const {
            '2026-11-15': (1, 0, 0),
            '2026-11-21': (0, 2, 0),
            '2026-11-22': (0, 0, 3),
            '2026-11-23': (4, 0, 0),
          },
        ),
      )!;

      final weeks = summary.grouped(7);

      expect(weeks.map((w) => w.start), [
        DateTime.utc(2026, 11, 15),
        DateTime.utc(2026, 11, 22),
      ]);
      expect(weeks.map((w) => w.days), [7, 2]);
      expect(weeks[0].steps.registration, 1);
      expect(weeks[0].steps.handoff, 2);
      expect(weeks[1].steps.purchase, 3);
      expect(weeks[1].steps.registration, 4);
      expect(
        weeks.fold(0, (sum, w) => sum + w.steps.total),
        summary.steps.total,
      );
    });

    test('365 days are 52 weeks and one day', () {
      final summary = DashboardSummary.fromJson(
        emptyDashboardJson(from: '2025-11-24', to: '2026-11-23'),
      )!;

      final weeks = summary.grouped(7);

      expect(weeks, hasLength(53));
      expect(weeks.last.days, 1);
      expect(weeks.last.start, DateTime.utc(2026, 11, 23));
    });
  });
}
