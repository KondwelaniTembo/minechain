// "Dashboard": the regulatory officer's view of the supply chain (FR-14;
// dashboard plan §5, T4), from GET /dashboard. Read-only: it changes
// nothing, and detail stays in "Alerts", "Check a consignment" and
// "Reports".
//
// Top to bottom: the period and mineral chips; right now (open alerts and
// consignments by stage); volumes, with a bar per day (per week for 12
// months); by mineral; where (zones); anomalies. An empty period shows one
// line instead of empty cards.
//
// The server checks the role on every request; the router only keeps other
// roles from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../alerts/domain/alert.dart' show AlertSeverity, AlertType;
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage;
import '../../alerts/presentation/alert_words.dart'
    show alertHeading, severityWord;
import '../../auth/presentation/password_prompt.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../reports/presentation/report_widgets.dart' show ReportFilterChips;
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../../verification/domain/consignment_view.dart'
    show ConsignmentStage, StepType;
import '../domain/dashboard_period.dart';
import '../domain/dashboard_summary.dart';
import 'dashboard_controller.dart';
import 'dashboard_widgets.dart';
import 'dashboard_words.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  DashboardController get _controller =>
      ref.read(dashboardControllerProvider.notifier);

  Future<void> _refresh() => _tell(_controller.refresh());

  Future<void> _choose(DashboardQuery query) =>
      _tell(_controller.choose(query));

  /// A failure while an answer stays on screen is said in a short message.
  Future<void> _tell(Future<AppFailure?> read) async {
    final failure = await read;
    if (failure != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failureText(failure))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardControllerProvider);
    final canRefresh = switch (state) {
      DashboardLoading() => false,
      DashboardLoaded(:final refreshing) => !refreshing,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.officer),
        ),
        title: const Text(AppText.dashboard),
        actions: [
          IconButton(
            tooltip: AppText.refreshDashboard,
            icon: const Icon(Icons.refresh),
            onPressed: canRefresh ? _refresh : null,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            // Scrollable even when short, so it can always be pulled down.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              for (final child in [..._choices(state), ..._body(state)])
                Center(
                  child: ConstrainedBox(
                    // A readable width on a turned phone.
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: child,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _choices(DashboardState state) {
    final query = state.query;
    return [
      OneOfChips<DashboardPeriod>(
        label: AppText.dashboardPeriod,
        choices: {for (final p in DashboardPeriod.values) p: periodWords(p)},
        selected: query.period,
        onSelected: (period) =>
            _choose(DashboardQuery(period: period, mineral: query.mineral)),
      ),
      const SizedBox(height: AppSizes.spaceM),
      ReportFilterChips<Mineral>(
        label: AppText.dashboardMineral,
        choices: {for (final m in Mineral.values) m: mineralName(m)},
        selected: query.mineral,
        onSelected: (mineral) =>
            _choose(DashboardQuery(period: query.period, mineral: mineral)),
      ),
      const SizedBox(height: AppSizes.spaceM),
    ];
  }

  List<Widget> _body(DashboardState state) => switch (state) {
    DashboardLoading() => const [_Loading()],
    DashboardNeedsPassword() => [
      AlertStateMessage(
        icon: Icons.key,
        text: AppText.dashboardNeedsPassword,
        action: FilledButton(
          onPressed: () async {
            final controller = _controller;
            if (await showPasswordPrompt(context)) await controller.refresh();
          },
          child: const Text(AppText.enterYourPassword),
        ),
      ),
    ],
    DashboardFailed(:final failure) => [
      AlertStateMessage(
        icon: failure is NoConnection ? Icons.wifi_off : Icons.error_outline,
        text: failureText(failure),
        // No casual "Try again" for an unsafe connection: it may mean
        // someone is intercepting the network.
        action: failure is InsecureConnection
            ? null
            : FilledButton(
                onPressed: () => _controller.refresh(),
                child: const Text(AppText.tryAgain),
              ),
      ),
    ],
    DashboardLoaded(:final query, :final summary, :final refreshing) => [
      if (refreshing) const LinearProgressIndicator(),
      Text(
        AppText.dashboardDays(summary.from, summary.to),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      Text(
        AppText.dashboardDaysNote,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      _rightNow(summary),
      _volumes(summary, query),
      if (!summary.isEmpty) ...[
        _byMineral(summary),
        _where(summary),
        _anomalies(summary),
      ],
    ],
  };

  Widget _rightNow(DashboardSummary summary) {
    final stages = summary.consignments;
    final max = _maxOf(stages.values);
    return DashboardSection(
      key: const ValueKey('section-now'),
      title: AppText.rightNow,
      children: [
        AlertInfoLine(
          icon: Icons.notification_important,
          text: AppText.openAlertsNow(summary.openAlerts),
        ),
        const SizedBox(height: AppSizes.spaceS),
        Text(
          AppText.consignmentsByStage,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSizes.spaceXs),
        for (final stage in ConsignmentStage.values)
          CountBar(
            label: stageWords(stage),
            value: '${stages[stage] ?? 0}',
            count: stages[stage] ?? 0,
            max: max,
          ),
      ],
    );
  }

  Widget _volumes(DashboardSummary summary, DashboardQuery query) {
    if (summary.isEmpty) {
      return DashboardSection(
        key: const ValueKey('section-volumes'),
        title: AppText.volumesHeading,
        children: [
          AlertInfoLine(
            icon: Icons.info_outline,
            text: AppText.nothingInPeriod(periodWords(query.period)),
          ),
        ],
      );
    }
    final perBar = daysPerBar(summary.days);
    final types = {for (final t in StepType.values) t: summary.steps.of(t)};
    final max = _maxOf(types.values);
    return DashboardSection(
      key: const ValueKey('section-volumes'),
      title: AppText.volumesHeading,
      children: [
        AlertInfoLine(
          icon: Icons.timeline,
          text: AppText.stepsRecorded(summary.steps.total),
        ),
        AlertInfoLine(
          icon: Icons.scale,
          text: AppText.registeredKg(kilogramsOf(summary.registeredWeightMg)),
        ),
        Text(
          AppText.registeredWeightNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSizes.spaceM),
        Text(
          perBar == 1 ? AppText.stepsPerDay : AppText.stepsPerWeek,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSizes.spaceS),
        StepBars(bars: summary.grouped(perBar)),
        const SizedBox(height: AppSizes.spaceM),
        for (final entry in types.entries)
          CountBar(
            label: stepTypePlural(entry.key),
            value: '${entry.value}',
            count: entry.value,
            max: max,
          ),
      ],
    );
  }

  Widget _byMineral(DashboardSummary summary) {
    final max = _maxOf(summary.byMineral.map((m) => m.steps));
    return DashboardSection(
      key: const ValueKey('section-minerals'),
      title: AppText.byMineralHeading,
      children: [
        for (final row in summary.byMineral)
          CountBar(
            label: switch (row.mineral) {
              final mineral? => mineralName(mineral),
              null => row.apiName,
            },
            value: AppText.mineralSteps(
              row.steps,
              kilogramsOf(row.registeredWeightMg),
            ),
            count: row.steps,
            max: max,
          ),
      ],
    );
  }

  Widget _where(DashboardSummary summary) {
    final max = _maxOf([
      ...summary.byZone.map((z) => z.steps),
      summary.outsideZones,
    ]);
    return DashboardSection(
      key: const ValueKey('section-where'),
      title: AppText.whereHeading,
      children: [
        for (final zone in summary.byZone)
          CountBar(
            label: zone.active
                ? zone.zoneName
                : AppText.zoneDeactivated(zone.zoneName),
            value: '${zone.steps}',
            count: zone.steps,
            max: max,
          ),
        if (summary.outsideZones > 0)
          CountBar(
            label: AppText.outsideEveryZone,
            value: '${summary.outsideZones}',
            count: summary.outsideZones,
            max: max,
          ),
      ],
    );
  }

  Widget _anomalies(DashboardSummary summary) {
    final anomalies = summary.anomalies;
    // Only the rules that fired, in the server's order of checks.
    final fired = [
      for (final type in AlertType.values)
        if ((anomalies.byType[type] ?? 0) > 0) type,
    ];
    final typeMax = _maxOf(fired.map((t) => anomalies.byType[t]!));
    final severityMax = _maxOf(anomalies.bySeverity.values);
    return DashboardSection(
      key: const ValueKey('section-anomalies'),
      title: AppText.anomaliesHeading,
      children: [
        AlertInfoLine(
          icon: Icons.report_problem,
          text: AppText.anomaliesRaised(anomalies.total, anomalies.open),
        ),
        if (anomalies.total > 0) ...[
          const SizedBox(height: AppSizes.spaceS),
          for (final type in fired)
            CountBar(
              label: alertHeading(type),
              value: '${anomalies.byType[type]}',
              count: anomalies.byType[type]!,
              max: typeMax,
            ),
          const SizedBox(height: AppSizes.spaceS),
          Text(
            AppText.bySeverity,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSizes.spaceXs),
          // Most serious first.
          for (final severity in AlertSeverity.values.reversed)
            CountBar(
              label: severityWord(severity),
              value: '${anomalies.bySeverity[severity] ?? 0}',
              count: anomalies.bySeverity[severity] ?? 0,
              max: severityMax,
            ),
        ],
      ],
    );
  }

  static int _maxOf(Iterable<int> counts) =>
      counts.fold(0, (max, n) => n > max ? n : max);
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
      child: Column(
        children: [
          CircularProgressIndicator(),
          SizedBox(height: AppSizes.spaceM),
          Text(AppText.loadingDashboard, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
