// What a report download asks the server for (reports plan, T1): the path,
// the query, and the name to save the file under if the server's name is not
// usable. Plain Dart, no Flutter.
//
// Days are UTC calendar days, as the server reads them (api.md, "Reports"):
// `from=2026-11-01&to=2026-11-30` covers every step recorded from
// 2026-11-01T00:00Z up to, but not including, 2026-12-01T00:00Z. Zambia is
// UTC+2, so a step at 01:00 in Lusaka on 10 Nov falls on 9 Nov. The screen
// says so; the app does not try to shift the days.

import '../../registration/domain/mineral.dart';
import '../../verification/domain/consignment_view.dart'
    show AnchorStatus, ReviewStatus, StepType;

/// The longest period the server accepts, counting both days (decision
/// Reports (4)).
const int maxReportDays = 366;

/// The length of the period the screens start with (Q4): the 30 days ending
/// today.
const int defaultReportDays = 30;

/// [date]'s calendar day as a UTC midnight, whatever zone [date] is in.
///
/// The date picker gives local midnights; the clock gives UTC instants. Both
/// keep only their year, month and day here, so the day the user saw is the
/// day that is sent.
DateTime reportDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// [day] as `YYYY-MM-DD`, the form the server expects.
String utcDayText(DateTime day) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
      '${two(day.day)}';
}

/// How many days [from] to [to] covers, counting both. UTC days are always
/// 24 hours long, so the difference is exact.
int daysCounted(DateTime from, DateTime to) =>
    reportDay(to).difference(reportDay(from)).inDays + 1;

/// The default period on [nowUtc]: from 29 days before today to today, in
/// UTC. Every step recorded up to now falls on or before today's UTC day.
({DateTime from, DateTime to}) defaultPeriod(DateTime nowUtc) {
  final to = reportDay(nowUtc.toUtc());
  return (
    from: to.subtract(const Duration(days: defaultReportDays - 1)),
    to: to,
  );
}

/// What is wrong with a period, as the server would say it.
enum PeriodProblem {
  /// "To" is before "From".
  toBeforeFrom,

  /// More than [maxReportDays] days, counting both.
  tooLong,
}

/// The problem with [from] to [to], or null when the server will accept it.
PeriodProblem? periodProblem(DateTime from, DateTime to) {
  final days = daysCounted(from, to);
  if (days < 1) return PeriodProblem.toBeforeFrom;
  if (days > maxReportDays) return PeriodProblem.tooLong;
  return null;
}

/// One report download.
sealed class ReportRequest {
  const ReportRequest();

  /// The path under the API's base address.
  List<String> get path;

  /// The query parameters, every filter left out unless it is set.
  Map<String, String> get query;

  /// The server's filename for this request (api.md, "The file"), used when
  /// the answer's own name is missing or not in the safe form.
  String get fallbackFilename;

  /// The problem with this request's period, if it has one.
  PeriodProblem? get problem;
}

/// The transactions report (FR-09): every step recorded in a period.
final class TransactionsReport extends ReportRequest {
  const TransactionsReport({
    required this.from,
    required this.to,
    this.mineral,
    this.type,
    this.reviewStatus,
    this.anchorStatus,
  });

  final DateTime from;
  final DateTime to;

  /// Each filter: null means "Any", and the parameter is not sent.
  final Mineral? mineral;
  final StepType? type;
  final ReviewStatus? reviewStatus;
  final AnchorStatus? anchorStatus;

  @override
  List<String> get path => const ['reports', 'transactions'];

  @override
  Map<String, String> get query => {
    'from': utcDayText(from),
    'to': utcDayText(to),
    // The enums' names are exactly the API's values.
    if (mineral != null) 'mineral': mineral!.name,
    if (type != null) 'type': type!.name,
    if (reviewStatus != null) 'reviewStatus': reviewStatus!.name,
    if (anchorStatus != null) 'anchorStatus': anchorStatus!.name,
  };

  @override
  String get fallbackFilename =>
      'minechain-transactions-${utcDayText(from)}-to-${utcDayText(to)}.csv';

  @override
  PeriodProblem? get problem => periodProblem(from, to);

  @override
  String toString() => 'TransactionsReport($query)';
}

/// The audit trail of one consignment (FR-13): its whole history.
final class ConsignmentAuditTrail extends ReportRequest {
  const ConsignmentAuditTrail(this.consignmentId);

  final String consignmentId;

  @override
  List<String> get path => const ['reports', 'audit-trail'];

  // In lower case, as the server records filters (api.md, "Every download is
  // recorded").
  @override
  Map<String, String> get query => {
    'consignmentId': consignmentId.toLowerCase(),
  };

  @override
  String get fallbackFilename =>
      'minechain-audit-trail-consignment-${consignmentId.toLowerCase()}.csv';

  @override
  PeriodProblem? get problem => null;

  @override
  String toString() => 'ConsignmentAuditTrail()';
}

/// The audit trail of one person (FR-13): what they did in a period.
final class PersonAuditTrail extends ReportRequest {
  const PersonAuditTrail({
    required this.actorId,
    required this.from,
    required this.to,
  });

  final String actorId;
  final DateTime from;
  final DateTime to;

  @override
  List<String> get path => const ['reports', 'audit-trail'];

  @override
  Map<String, String> get query => {
    'actorId': actorId.toLowerCase(),
    'from': utcDayText(from),
    'to': utcDayText(to),
  };

  @override
  String get fallbackFilename =>
      'minechain-audit-trail-user-${actorId.toLowerCase()}-'
      '${utcDayText(from)}-to-${utcDayText(to)}.csv';

  @override
  PeriodProblem? get problem => periodProblem(from, to);

  @override
  String toString() => 'PersonAuditTrail()';
}
