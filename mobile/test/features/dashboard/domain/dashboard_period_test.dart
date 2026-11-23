// The dashboard's periods as UTC days (dashboard plan, T3, Q4).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/dashboard/domain/dashboard_period.dart';
import 'package:minechain/features/registration/domain/mineral.dart';

void main() {
  final noon = DateTime.utc(2026, 11, 23, 12);

  test('each period ends today and counts today in its days', () {
    expect(const DashboardQuery(period: DashboardPeriod.week).daysAt(noon), (
      from: '2026-11-17',
      to: '2026-11-23',
    ));
    expect(const DashboardQuery(period: DashboardPeriod.month).daysAt(noon), (
      from: '2026-10-25',
      to: '2026-11-23',
    ));
    expect(const DashboardQuery(period: DashboardPeriod.year).daysAt(noon), (
      from: '2025-11-24',
      to: '2026-11-23',
    ));
  });

  test('"today" is the UTC day, not Lusaka\'s', () {
    // 01:30 on 24 Nov in Lusaka (UTC+2) is still 23 Nov in UTC.
    final lusakaEarly = DateTime.parse('2026-11-24T01:30:00+02:00');

    expect(
      const DashboardQuery(period: DashboardPeriod.week).daysAt(lusakaEarly).to,
      '2026-11-23',
    );
  });

  test('a period over the end of a month, a year and 29 February', () {
    expect(
      const DashboardQuery(period: DashboardPeriod.week)
          .daysAt(DateTime.utc(2027, 1, 3)),
      (from: '2026-12-28', to: '2027-01-03'),
    );
    expect(
      const DashboardQuery(period: DashboardPeriod.week)
          .daysAt(DateTime.utc(2028, 3, 2)),
      (from: '2028-02-25', to: '2028-03-02'),
    );
  });

  test('the parameters: the days, and the mineral only when chosen', () {
    expect(
      const DashboardQuery(period: DashboardPeriod.week).parametersAt(noon),
      {'from': '2026-11-17', 'to': '2026-11-23'},
    );
    expect(
      const DashboardQuery(
        period: DashboardPeriod.month,
        mineral: Mineral.cobalt,
      ).parametersAt(noon),
      {'from': '2026-10-25', 'to': '2026-11-23', 'mineral': 'cobalt'},
    );
  });

  test('a year is 365 days, within the server\'s 366', () {
    expect(DashboardPeriod.year.days, 365);
  });

  test('queries with the same choices are equal', () {
    expect(
      const DashboardQuery(period: DashboardPeriod.week, mineral: Mineral.gold),
      const DashboardQuery(period: DashboardPeriod.week, mineral: Mineral.gold),
    );
    expect(
      const DashboardQuery(period: DashboardPeriod.week),
      isNot(const DashboardQuery(period: DashboardPeriod.month)),
    );
  });
}
