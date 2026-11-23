// The dashboard's three periods (dashboard plan, Q4 A): the last 7 days, 30
// days or 12 months, each ending today in UTC, as UTC days for
// GET /dashboard (docs/api.md, "GET /dashboard"). The server counts a step on
// the UTC day its phone recorded it, so the days here are UTC too.
//
// Plain Dart, no Flutter.

import '../../registration/domain/mineral.dart';

enum DashboardPeriod {
  week(days: 7),
  month(days: 30),
  // 365 days, not a calendar year, so the period always fits the server's
  // 366-day limit and ends today like the other two.
  year(days: 365);

  const DashboardPeriod({required this.days});

  /// How many days, today included.
  final int days;
}

/// One request to the dashboard: a period of UTC days and an optional
/// mineral.
class DashboardQuery {
  const DashboardQuery({required this.period, this.mineral});

  final DashboardPeriod period;

  /// Null for every mineral.
  final Mineral? mineral;

  /// The first and last UTC day of [period], for the clock reading [now].
  ({String from, String to}) daysAt(DateTime now) {
    final utc = now.toUtc();
    final today = DateTime.utc(utc.year, utc.month, utc.day);
    // Calendar days, not 24-hour steps: DateTime.utc has no daylight saving,
    // so both are the same here, but this reads as what it means.
    final first = DateTime.utc(
      today.year,
      today.month,
      today.day - (period.days - 1),
    );
    return (from: utcDay(first), to: utcDay(today));
  }

  /// The query parameters for the clock reading [now].
  Map<String, String> parametersAt(DateTime now) {
    final days = daysAt(now);
    return {
      'from': days.from,
      'to': days.to,
      if (mineral != null) 'mineral': mineral!.name,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DashboardQuery &&
      other.period == period &&
      other.mineral == mineral;

  @override
  int get hashCode => Object.hash(period, mineral);
}

/// [day] (a UTC midnight) as YYYY-MM-DD.
String utcDay(DateTime day) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
}
