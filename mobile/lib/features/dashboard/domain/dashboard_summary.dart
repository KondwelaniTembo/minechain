// The officer's dashboard (FR-14; dashboard plan, T3) as read from
// GET /dashboard (docs/api.md, "GET /dashboard"): counts only.
//
// Read strictly, as the other views are: a field the docs promise that is
// missing or of the wrong type makes the whole answer unreadable (null). A
// half-read dashboard could show "0 open alerts" when there are some. Two
// things a newer server may add are kept instead of refused: an alert type
// this app does not know counts under AlertType.unknown, and a mineral it
// does not know keeps its API name with a null [MineralCount.mineral].
//
// Weights stay text (whole milligrams), never doubles.
//
// Plain Dart, no Flutter.

import '../../alerts/domain/alert.dart' show AlertSeverity, AlertType;
import '../../registration/domain/mineral.dart';
import '../../verification/domain/consignment_view.dart'
    show ConsignmentStage, StepType;

/// Steps of each type, for a day, a group of days or the whole period.
class StepCounts {
  const StepCounts({
    required this.registration,
    required this.handoff,
    required this.purchase,
  });

  static const zero = StepCounts(registration: 0, handoff: 0, purchase: 0);

  final int registration;
  final int handoff;
  final int purchase;

  int get total => registration + handoff + purchase;

  int of(StepType type) => switch (type) {
    StepType.registration => registration,
    StepType.handoff => handoff,
    StepType.purchase => purchase,
  };

  StepCounts operator +(StepCounts other) => StepCounts(
    registration: registration + other.registration,
    handoff: handoff + other.handoff,
    purchase: purchase + other.purchase,
  );
}

/// The steps of one bar of the chart: one day, or a group of days.
class StepBucket {
  const StepBucket({
    required this.start,
    required this.days,
    required this.steps,
  });

  /// The first day, a UTC midnight.
  final DateTime start;

  /// How many days the bar covers (1 for a day; 7, or fewer at the end, for
  /// a week).
  final int days;

  final StepCounts steps;
}

class MineralCount {
  const MineralCount({
    required this.apiName,
    required this.mineral,
    required this.steps,
    required this.registeredWeightMg,
  });

  /// The API's spelling, kept for a mineral this app does not know.
  final String apiName;

  /// Null for a mineral this app does not know.
  final Mineral? mineral;

  final int steps;

  /// Whole milligrams, as text.
  final String registeredWeightMg;
}

class ZoneCount {
  const ZoneCount({
    required this.zoneId,
    required this.zoneName,
    required this.active,
    required this.steps,
  });

  final String zoneId;
  final String zoneName;

  /// False for a zone deactivated since its steps arrived.
  final bool active;

  final int steps;
}

class AnomalyCounts {
  const AnomalyCounts({
    required this.total,
    required this.open,
    required this.byType,
    required this.bySeverity,
  });

  final int total;

  /// Of [total], still open.
  final int open;

  /// Every known type, and [AlertType.unknown] for any other.
  final Map<AlertType, int> byType;

  final Map<AlertSeverity, int> bySeverity;
}

class DashboardSummary {
  const DashboardSummary({
    required this.from,
    required this.to,
    required this.mineral,
    required this.openAlerts,
    required this.consignments,
    required this.steps,
    required this.registeredWeightMg,
    required this.byDay,
    required this.byMineral,
    required this.byZone,
    required this.outsideZones,
    required this.anomalies,
  });

  /// The first and last day of the period, UTC midnights.
  final DateTime from;
  final DateTime to;

  /// The mineral asked for; null for all (or one this app does not know).
  final Mineral? mineral;

  /// Open alerts now, on any day.
  final int openAlerts;

  /// Consignments by their stage now.
  final Map<ConsignmentStage, int> consignments;

  final StepCounts steps;

  /// Whole milligrams of accepted registrations, as text.
  final String registeredWeightMg;

  /// Every day of the period, in order.
  final List<StepBucket> byDay;

  final List<MineralCount> byMineral;
  final List<ZoneCount> byZone;
  final int outsideZones;
  final AnomalyCounts anomalies;

  int get days => byDay.length;

  bool get isEmpty => steps.total == 0;

  /// [byDay] grouped into bars of [size] days from the first day; the last
  /// bar has the days left over.
  List<StepBucket> grouped(int size) {
    if (size <= 1) return byDay;
    final bars = <StepBucket>[];
    for (var i = 0; i < byDay.length; i += size) {
      final group = byDay.sublist(i, (i + size).clamp(0, byDay.length));
      bars.add(
        StepBucket(
          start: group.first.start,
          days: group.length,
          steps: group.fold(StepCounts.zero, (sum, day) => sum + day.steps),
        ),
      );
    }
    return List.unmodifiable(bars);
  }

  /// Reads the answer, or null when it is not the documented shape.
  static DashboardSummary? fromJson(Object? json) {
    if (json is! Map) return null;

    final period = json['period'];
    if (period is! Map) return null;
    final from = _day(period['from']);
    final to = _day(period['to']);
    final days = _count(period['days']);
    if (from == null || to == null || days == null) return null;
    if (to.difference(from).inDays + 1 != days) return null;

    final mineralJson = json['mineral'];
    if (mineralJson != null && mineralJson is! String) return null;

    final now = json['now'];
    if (now is! Map) return null;
    final openAlerts = _count(now['openAlerts']);
    final consignments = _keyed(
      now['consignments'],
      ConsignmentStage.values,
      (stage) => stage.apiName,
    );

    final steps = _stepCounts(json['steps'], withTotal: true);
    final weight = _milligrams(json['registeredWeightMg']);
    final byDay = _list(json['byDay'], _dayRow);
    final byMineral = _list(json['byMineral'], _mineralRow);
    final byZone = _list(json['byZone'], _zoneRow);
    final outsideZones = _count(json['outsideZones']);
    final anomalies = _anomalies(json['anomalies']);
    if (openAlerts == null ||
        consignments == null ||
        steps == null ||
        weight == null ||
        byDay == null ||
        byMineral == null ||
        byZone == null ||
        outsideZones == null ||
        anomalies == null) {
      return null;
    }

    // Every day of the period, in order, as the docs promise: a gap would
    // draw a wrong chart.
    if (byDay.length != days) return null;
    for (var i = 0; i < days; i++) {
      final expected = DateTime.utc(from.year, from.month, from.day + i);
      if (byDay[i].start != expected) return null;
    }

    return DashboardSummary(
      from: from,
      to: to,
      mineral: mineralJson is String ? Mineral.fromApiName(mineralJson) : null,
      openAlerts: openAlerts,
      consignments: consignments,
      steps: steps,
      registeredWeightMg: weight,
      byDay: byDay,
      byMineral: byMineral,
      byZone: byZone,
      outsideZones: outsideZones,
      anomalies: anomalies,
    );
  }
}

final _dayFormat = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A YYYY-MM-DD day as a UTC midnight, or null (an unreal date included:
/// DateTime would quietly turn 2026-02-30 into 2 March).
DateTime? _day(Object? value) {
  if (value is! String || !_dayFormat.hasMatch(value)) return null;
  final day = DateTime.tryParse('${value}T00:00:00Z');
  if (day == null) return null;
  final again =
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
  return again == value ? day : null;
}

/// A whole number of at least 0, or null.
int? _count(Object? value) => value is int && value >= 0 ? value : null;

/// Whole milligrams as digits, or null.
String? _milligrams(Object? value) =>
    value is String && RegExp(r'^[0-9]+$').hasMatch(value) ? value : null;

/// Every row read with [read], or null when the value is not a list or one
/// row is unreadable.
List<T>? _list<T>(Object? json, T? Function(Object?) read) {
  if (json is! List) return null;
  final rows = <T>[];
  for (final row in json) {
    final value = read(row);
    if (value == null) return null;
    rows.add(value);
  }
  return List.unmodifiable(rows);
}

/// A count for every one of [keys] (by [nameOf]), or null when one is
/// missing or not a count. Other keys are ignored.
Map<K, int>? _keyed<K>(Object? json, List<K> keys, String Function(K) nameOf) {
  if (json is! Map) return null;
  final counts = <K, int>{};
  for (final key in keys) {
    final count = _count(json[nameOf(key)]);
    if (count == null) return null;
    counts[key] = count;
  }
  return Map.unmodifiable(counts);
}

StepCounts? _stepCounts(Object? json, {bool withTotal = false}) {
  if (json is! Map) return null;
  final registration = _count(json['registration']);
  final handoff = _count(json['handoff']);
  final purchase = _count(json['purchase']);
  if (registration == null || handoff == null || purchase == null) return null;
  final counts = StepCounts(
    registration: registration,
    handoff: handoff,
    purchase: purchase,
  );
  if (withTotal && _count(json['total']) != counts.total) return null;
  return counts;
}

StepBucket? _dayRow(Object? json) {
  if (json is! Map) return null;
  final day = _day(json['day']);
  final steps = _stepCounts(json);
  if (day == null || steps == null) return null;
  return StepBucket(start: day, days: 1, steps: steps);
}

MineralCount? _mineralRow(Object? json) {
  if (json is! Map) return null;
  final name = json['mineral'];
  final steps = _count(json['steps']);
  final weight = _milligrams(json['registeredWeightMg']);
  if (name is! String || steps == null || weight == null) return null;
  return MineralCount(
    apiName: name,
    mineral: Mineral.fromApiName(name),
    steps: steps,
    registeredWeightMg: weight,
  );
}

ZoneCount? _zoneRow(Object? json) {
  if (json is! Map) return null;
  final id = json['zoneId'];
  final name = json['zoneName'];
  final active = json['active'];
  final steps = _count(json['steps']);
  if (id is! String || name is! String || active is! bool || steps == null) {
    return null;
  }
  return ZoneCount(zoneId: id, zoneName: name, active: active, steps: steps);
}

AnomalyCounts? _anomalies(Object? json) {
  if (json is! Map) return null;
  final total = _count(json['total']);
  final open = _count(json['open']);
  final typesJson = json['byType'];
  final bySeverity = _keyed(
    json['bySeverity'],
    AlertSeverity.values,
    (severity) => severity.name,
  );
  if (total == null ||
      open == null ||
      typesJson is! Map ||
      bySeverity == null) {
    return null;
  }
  if (open > total) return null;

  final known = AlertType.values.where((t) => t != AlertType.unknown).toList();
  final byType = <AlertType, int>{};
  for (final type in known) {
    final count = _count(typesJson[type.apiName]);
    if (count == null) return null;
    byType[type] = count;
  }
  // A type added on the server after this app version is still counted.
  var unknown = 0;
  for (final entry in typesJson.entries) {
    if (known.any((t) => t.apiName == entry.key)) continue;
    final count = _count(entry.value);
    if (count == null) return null;
    unknown += count;
  }
  byType[AlertType.unknown] = unknown;

  return AnomalyCounts(
    total: total,
    open: open,
    byType: Map.unmodifiable(byType),
    bySeverity: bySeverity,
  );
}
