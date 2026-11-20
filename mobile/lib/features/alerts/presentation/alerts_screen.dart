// "Alerts": the regulatory officer's list of anomaly alerts (officer alerts
// plan §4.1, T2; FR-08, Scope (2)).
//
// Three lists behind one switch (Q1): "Open" (the queue, oldest first, the
// default), "Confirmed" and "Cleared" (newest decision first). Each card says
// what was found, how serious it is (an icon AND a word, never colour alone),
// which consignment, who recorded the step and when, and whether it holds
// the consignment. A tap opens the alert (T3); coming back reads the list
// again, so a decision just made is never shown wrongly.
//
// The server checks the role on every request (administrators get 403); the
// router only keeps other roles from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/alert.dart';
import 'alert_widgets.dart';
import 'alerts_list_controller.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  AlertStatus _status = AlertStatus.open;

  AlertsListController get _controller =>
      ref.read(alertsListControllerProvider(_status).notifier);

  Future<void> _refresh() async {
    final failure = await _controller.refresh();
    if (failure != null && mounted) _say(context, failureText(failure));
  }

  /// Opens one alert. Its page answers with the decision's message, if a
  /// decision was made; the list is read again either way.
  Future<void> _open(Alert alert) async {
    final message = await context.push<String>(
      AppRoutes.officerAlert(alert.id),
    );
    if (!mounted) return;
    if (message != null) _say(context, message);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(alertsListControllerProvider(_status));
    final canRefresh = switch (state) {
      AlertsLoading() => false,
      AlertsLoaded(:final loadingMore) => !loadingMore,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.officer),
        ),
        title: const Text(AppText.alerts),
        actions: [
          IconButton(
            tooltip: AppText.refreshList,
            icon: const Icon(Icons.refresh),
            onPressed: canRefresh ? _refresh : null,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            // Scrollable even when short, so the list can always be pulled
            // down to refresh.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              for (final child in [
                _StatusSwitch(
                  selected: _status,
                  onSelected: (status) => setState(() => _status = status),
                ),
                const SizedBox(height: AppSizes.spaceM),
                ..._body(state),
              ])
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

  List<Widget> _body(AlertsListState state) => switch (state) {
    AlertsLoading() => const [_Loading()],
    AlertsNeedPassword() => [
      AlertStateMessage(
        icon: Icons.key,
        text: AppText.alertsNeedPassword,
        action: FilledButton(
          onPressed: () async {
            final controller = _controller;
            if (await showPasswordPrompt(context)) await controller.refresh();
          },
          child: const Text(AppText.enterYourPassword),
        ),
      ),
    ],
    AlertsFailed(:final failure) => [
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
    AlertsLoaded(alerts: []) => [
      AlertStateMessage(icon: Icons.inbox, text: _emptyText(_status)),
    ],
    final AlertsLoaded loaded => [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
        child: Text(
          AppText.alertsCount(
            status: _statusWord(_status),
            shown: loaded.alerts.length,
            total: loaded.total,
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      for (final alert in loaded.alerts)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
          child: AlertCard(
            key: ValueKey(alert.id),
            alert: alert,
            onTap: () => _open(alert),
          ),
        ),
      if (loaded.hasMore)
        OutlinedButton.icon(
          onPressed: loaded.loadingMore
              ? null
              : () async {
                  final failure = await _controller.loadMore();
                  if (failure != null && mounted) {
                    _say(context, failureText(failure));
                  }
                },
          icon: loaded.loadingMore
              ? const SmallSpinner()
              : const Icon(Icons.expand_more),
          label: const Text(AppText.showMore),
        ),
    ],
  };
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String _statusWord(AlertStatus status) => switch (status) {
  AlertStatus.open => AppText.statusOpen,
  AlertStatus.reviewed => AppText.statusConfirmed,
  AlertStatus.dismissed => AppText.statusCleared,
};

String _emptyText(AlertStatus status) => switch (status) {
  AlertStatus.open => AppText.noOpenAlerts,
  AlertStatus.reviewed => AppText.noConfirmedAlerts,
  AlertStatus.dismissed => AppText.noClearedAlerts,
};

/// Q1: "Open", "Confirmed", "Cleared". Chips in a Wrap, not a segmented
/// button: at large text they go onto a second line instead of being cut.
class _StatusSwitch extends StatelessWidget {
  const _StatusSwitch({required this.selected, required this.onSelected});

  final AlertStatus selected;
  final ValueChanged<AlertStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppText.alertsShowing,
      child: Wrap(
        spacing: AppSizes.spaceS,
        runSpacing: AppSizes.spaceS,
        children: [
          for (final (status, label) in const [
            (AlertStatus.open, AppText.alertsOpen),
            (AlertStatus.reviewed, AppText.alertsConfirmed),
            (AlertStatus.dismissed, AppText.alertsCleared),
          ])
            ChoiceChip(
              label: Text(label),
              selected: status == selected,
              onSelected: (_) => onSelected(status),
            ),
        ],
      ),
    );
  }
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
          Text(AppText.loadingAlerts, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
