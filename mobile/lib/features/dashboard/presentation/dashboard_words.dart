// The dashboard's words for its choices and rows (dashboard plan, T4). The
// words themselves are in AppText; minerals, alert types and severities use
// the same words as Registration and Alerts, so a thing is named the same
// everywhere.

import '../../../core/text/app_text.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';
import '../../verification/domain/consignment_view.dart'
    show ConsignmentStage, StepType;
import '../domain/dashboard_period.dart';

String periodWords(DashboardPeriod period) => switch (period) {
  DashboardPeriod.week => AppText.last7Days,
  DashboardPeriod.month => AppText.last30Days,
  DashboardPeriod.year => AppText.last12Months,
};

String stageWords(ConsignmentStage stage) => switch (stage) {
  ConsignmentStage.registered => AppText.stageRegistered,
  ConsignmentStage.inTransit => AppText.stageInTransit,
  ConsignmentStage.purchased => AppText.stagePurchased,
};

/// "Registrations", "Handoffs", "Purchases".
String stepTypePlural(StepType type) => switch (type) {
  StepType.registration => AppText.stepRegistrations,
  StepType.handoff => AppText.stepHandoffs,
  StepType.purchase => AppText.stepPurchases,
};

/// Whole milligrams (text) as kilograms, exactly: "18500000" is "18.5".
/// Every mineral in kilograms, so the rows can be compared. Falls back to
/// the digits if the text is not plain digits (the parser refuses that, so
/// this does not happen).
String kilogramsOf(String milligrams) =>
    weightInUnit(milligrams, WeightUnit.kilograms) ?? milligrams;

/// How many days each bar of the chart covers: one bar per day up to a
/// month, one per week for longer.
int daysPerBar(int days) => days <= 31 ? 1 : 7;
