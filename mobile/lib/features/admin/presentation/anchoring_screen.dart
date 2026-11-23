// "Anchoring": the administrator's read-only view of how steps are reaching
// the blockchain (anchoring status plan §3, T3; Scope (11)), from
// GET /admin/anchoring.
//
// Top to bottom: the worker's state, problems, the four counts, the last
// activity, then (only when there is something in them) the waiting steps,
// the sent ones, the failed ones and the held consignments, and last the
// recorder wallet and the contract, each with Copy. "Run now" and "Retry"
// stay in the API (Scope (11)); a failed step that a retry may fix says so.
//
// The server checks the role on every request; the router only keeps other
// roles from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage;
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/anchoring_status.dart';
import 'anchoring_status_controller.dart';
import 'anchoring_words.dart';

class AnchoringScreen extends ConsumerStatefulWidget {
  const AnchoringScreen({super.key});

  @override
  ConsumerState<AnchoringScreen> createState() => _AnchoringScreenState();
}

class _AnchoringScreenState extends ConsumerState<AnchoringScreen> {
  AnchoringStatusController get _controller =>
      ref.read(anchoringStatusControllerProvider.notifier);

  Future<void> _refresh() async {
    final failure = await _controller.refresh();
    if (failure != null && mounted) _say(context, failureText(failure));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(anchoringStatusControllerProvider);
    final canRefresh = switch (state) {
      AnchoringLoading() => false,
      AnchoringLoaded(:final refreshing) => !refreshing,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.admin),
        ),
        title: const Text(AppText.anchoring),
        actions: [
          IconButton(
            tooltip: AppText.refreshStatus,
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
              for (final child in _body(state))
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

  List<Widget> _body(AnchoringScreenState state) => switch (state) {
    AnchoringLoading() => const [_Loading()],
    AnchoringNeedsPassword() => [
      AlertStateMessage(
        icon: Icons.key,
        text: AppText.anchoringNeedsPassword,
        action: FilledButton(
          onPressed: () async {
            final controller = _controller;
            if (await showPasswordPrompt(context)) await controller.refresh();
          },
          child: const Text(AppText.enterYourPassword),
        ),
      ),
    ],
    AnchoringFailed(:final failure) => [
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
    AnchoringLoaded(:final status, :final readAt) => [
      Text(
        AppText.updatedAt(readAt.toLocal()),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: AppSizes.spaceS),
      _StateCard(state: status.state),
      ..._sections(status),
    ],
  };

  List<Widget> _sections(AnchoringStatus status) {
    final waiting = status.waiting;
    return [
      _Section(
        title: AppText.anchoringProblems,
        children: [
          if (status.problems.isEmpty)
            const AlertInfoLine(
              icon: Icons.check_circle_outline,
              text: AppText.noProblems,
            ),
          for (final problem in status.problems)
            AlertInfoLine(icon: Icons.report_problem, text: problem.message),
        ],
      ),
      _Section(
        title: AppText.anchoringSteps,
        children: [
          AlertInfoLine(
            icon: Icons.hourglass_top,
            text: AppText.countLine(
              AppText.chainWaiting,
              status.counts.pending,
            ),
          ),
          AlertInfoLine(
            icon: Icons.send,
            text: AppText.countLine(AppText.countSent, status.counts.submitted),
          ),
          AlertInfoLine(
            icon: Icons.link,
            text: AppText.countLine(
              AppText.countConfirmed,
              status.counts.confirmed,
            ),
          ),
          AlertInfoLine(
            icon: Icons.error_outline,
            text: AppText.countLine(AppText.chainFailed, status.counts.failed),
          ),
          const SizedBox(height: AppSizes.spaceXs),
          Text(
            AppText.anchoringStepsNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      _Section(
        title: AppText.lastActivity,
        children: [
          AlertInfoLine(
            icon: Icons.verified,
            text: switch (status.lastConfirmedAt) {
              null => AppText.nothingAnchoredYet,
              final at => AppText.lastAnchoredAt(at.toLocal()),
            },
          ),
          AlertInfoLine(
            icon: Icons.schedule,
            text: switch (status.lastTick) {
              null => AppText.workerNotRunYet,
              final tick => AppText.workerLastRan(
                tick.at.toLocal(),
                tickOutcomeWords(tick.outcome),
              ),
            },
          ),
        ],
      ),
      if (status.counts.pending > 0 || waiting.oldestAgeSeconds != null)
        _Section(
          title: AppText.waitingHeading,
          children: [
            if (waiting.oldestAgeSeconds case final age?)
              AlertInfoLine(
                icon: Icons.hourglass_bottom,
                text: AppText.oldestWaiting(AppText.age(age)),
              ),
            if (waiting.onHeldConsignments > 0)
              AlertInfoLine(
                icon: Icons.pause_circle,
                text: AppText.onHeldConsignments(waiting.onHeldConsignments),
              ),
            if (waiting.behindFailedStep > 0)
              AlertInfoLine(
                icon: Icons.block,
                text: AppText.behindFailedSteps(waiting.behindFailedStep),
              ),
          ],
        ),
      if (status.inFlight.isNotEmpty)
        _Section(
          title: AppText.countSent,
          children: [
            for (final step in status.inFlight)
              _Row(
                key: ValueKey('sent-${step.stepId}'),
                title: stepName(step.type, step.stepId),
                children: [
                  AlertInfoLine(
                    icon: Icons.send,
                    text: AppText.sentAgo(AppText.age(step.ageSeconds)),
                  ),
                  if (step.stuck)
                    const AlertInfoLine(
                      icon: Icons.warning_amber,
                      text: AppText.sentStepStuck,
                    ),
                  if (step.refusalCode case final code?)
                    AlertInfoLine(
                      icon: Icons.block,
                      text: AppText.lastResendRefused(code),
                    ),
                  _CopyableValue(
                    key: ValueKey('copy-${step.stepId}'),
                    value: step.chainTxHash,
                  ),
                ],
              ),
          ],
        ),
      if (status.failed.isNotEmpty)
        _Section(
          title: AppText.chainFailed,
          children: [
            for (final step in status.failed)
              _Row(
                key: ValueKey('failed-${step.stepId}'),
                title: stepName(step.type, step.stepId),
                children: [
                  AlertInfoLine(
                    icon: Icons.error_outline,
                    text: AppText.failedReason(step.code),
                  ),
                  AlertInfoLine(
                    icon: Icons.replay,
                    text: AppText.attempts(step.attempts),
                  ),
                  AlertInfoLine(
                    icon: Icons.event,
                    text: AppText.lastChangedAt(step.updatedAt.toLocal()),
                  ),
                  if (step.retryable)
                    const AlertInfoLine(
                      icon: Icons.restart_alt,
                      text: AppText.canBeRetried,
                    ),
                ],
              ),
            if (status.counts.failed > status.failed.length)
              Text(
                AppText.newestFailed(
                  status.failed.length,
                  status.counts.failed,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      if (status.held.isNotEmpty)
        _Section(
          title: AppText.heldHeading,
          children: [
            for (final held in status.held)
              _Row(
                key: ValueKey('held-${held.qrCode}'),
                title: held.qrCode,
                children: [
                  AlertInfoLine(
                    icon: Icons.pause_circle,
                    text: AppText.heldWaiting(
                      held.pendingSteps,
                      held.openAlerts,
                    ),
                  ),
                ],
              ),
          ],
        ),
      if (status.recorderAddress != null || status.contractAddress != null)
        _Section(
          title: AppText.walletHeading,
          children: [
            if (status.recorderAddress case final address?)
              _Row(
                title: AppText.recorderWallet,
                children: [
                  Text(AppText.recorderWalletNote),
                  _CopyableValue(
                    key: const ValueKey('copy-recorder'),
                    value: address,
                  ),
                ],
              ),
            if (status.contractAddress case final address?)
              _Row(
                title: AppText.mineChainContract,
                children: [
                  _CopyableValue(
                    key: const ValueKey('copy-contract'),
                    value: address,
                  ),
                ],
              ),
          ],
        ),
    ];
  }
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// The worker's state in one line, its colour from the theme's pairs (as the
/// consignment check's verdict), and an icon so it is never told by colour
/// alone.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.state});

  final WorkerState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = workerStateTone(state);
    final (background, foreground) = switch (tone) {
      StateTone.good => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      StateTone.warning => (scheme.primaryContainer, scheme.onPrimaryContainer),
      StateTone.bad => (scheme.errorContainer, scheme.onErrorContainer),
      StateTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    final icon = switch (tone) {
      StateTone.good => Icons.check_circle,
      StateTone.warning => Icons.sync_problem,
      StateTone.bad => Icons.error,
      StateTone.neutral => Icons.info_outline,
    };
    return Card(
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, color: foreground)),
            const SizedBox(width: AppSizes.spaceS),
            Expanded(
              child: Text(
                workerStateWords(state),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A card with a heading.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSizes.spaceM),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: AppSizes.spaceS),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One step, consignment or address inside a section.
class _Row extends StatelessWidget {
  const _Row({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          ...children,
        ],
      ),
    );
  }
}

/// A hash or address in full (selectable), with a Copy button: they are
/// pasted into Etherscan or a wallet, and a mistyped one is useless.
class _CopyableValue extends StatelessWidget {
  const _CopyableValue({required this.value, super.key});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSizes.spaceXs),
        SelectableText(value, style: const TextStyle(fontFamily: 'monospace')),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) _say(context, AppText.copied);
          },
          icon: const Icon(Icons.copy),
          label: const Text(AppText.copy),
        ),
      ],
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
          Text(AppText.loadingAnchoring, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
