// One alert (officer alerts plan §4.2–4.3, T3 and T4): what the check found,
// the step, the consignment, the other alerts on it, and, while it is open,
// the two decisions.
//
// A decision is made in a dialog with notes (3–500 characters, kept for ever
// in the audit log). Once the server has saved it, the page closes and hands
// the list a one-line message built from the server's answer, for example
// "Cleared. MC-2026-LSK-0008 is no longer held. Stage: On its way."

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../../verification/domain/consignment_view.dart'
    show ConsignmentStage, ReviewStatus;
import '../domain/alert.dart';
import 'alert_detail_controller.dart';
import 'alert_widgets.dart';
import 'alert_words.dart';

/// The notes' limits (api.md, POST /alerts/{id}/review: "3–500 characters"
/// after trimming).
const int decisionNotesMin = 3;
const int decisionNotesMax = 500;

class AlertDetailScreen extends ConsumerWidget {
  const AlertDetailScreen({required this.id, super.key});

  /// The alert's id, from the path.
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(alertDetailControllerProvider(id));
    final deciding = state is AlertDetailLoaded && state.deciding;

    return PopScope(
      // Not while a decision is on its way: its answer needs this page.
      canPop: !deciding,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: deciding
                ? null
                : () => backOrHome(context, AppRoutes.officerAlerts),
          ),
          title: const Text(AppText.alertTitle),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              for (final child in _body(context, ref, state))
                Center(
                  child: ConstrainedBox(
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

  List<Widget> _body(
    BuildContext context,
    WidgetRef ref,
    AlertDetailState state,
  ) {
    final controller = ref.read(alertDetailControllerProvider(id).notifier);
    return switch (state) {
      AlertDetailLoading() => const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: AppSizes.spaceM),
              Text(AppText.loadingAlert, textAlign: TextAlign.center),
            ],
          ),
        ),
      ],
      AlertDetailNeedsPassword() => [
        AlertStateMessage(
          icon: Icons.key,
          text: AppText.alertNeedsPassword,
          action: FilledButton(
            onPressed: () async {
              if (await showPasswordPrompt(context)) await controller.load();
            },
            child: const Text(AppText.enterYourPassword),
          ),
        ),
      ],
      AlertDetailNotFound() => [
        AlertStateMessage(
          icon: Icons.search_off,
          text: AppText.alertGone,
          action: FilledButton(
            onPressed: () => backOrHome(context, AppRoutes.officerAlerts),
            child: const Text(AppText.backToAlerts),
          ),
        ),
      ],
      AlertDetailFailed(:final failure) => [
        AlertStateMessage(
          icon: failure is NoConnection ? Icons.wifi_off : Icons.error_outline,
          text: failureText(failure),
          action: failure is InsecureConnection
              ? null
              : FilledButton(
                  onPressed: controller.load,
                  child: const Text(AppText.tryAgain),
                ),
        ),
      ],
      AlertDetailLoaded(:final alert, :final deciding) => _alert(
        context,
        ref,
        alert,
        deciding,
      ),
    };
  }

  List<Widget> _alert(
    BuildContext context,
    WidgetRef ref,
    Alert alert,
    bool deciding,
  ) {
    final text = Theme.of(context).textTheme;
    final review = alert.review;
    final others = alert.otherAlerts ?? const <OtherAlert>[];
    final anotherOpen = others.any((o) => o.status == AlertStatus.open);
    // Q2: only where it is certain from the alert alone.
    final canClear = alert.type != AlertType.handoffOrder;

    return [
      Semantics(
        header: true,
        child: Text(alertHeading(alert.type), style: text.headlineSmall),
      ),
      const SizedBox(height: AppSizes.spaceS),
      AlertInfoLine(
        icon: severityIcon(alert.severity),
        text: AppText.severityLine(severityWord(alert.severity)),
      ),
      AlertInfoLine(icon: _statusIcon(alert.status), text: _statusText(alert)),
      AlertInfoLine(
        icon: Icons.event,
        text: AppText.raisedAt(alert.createdAt.toLocal()),
      ),

      _Section(AppText.whatTheCheckFound),
      for (final line in alertFindings(alert))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXs),
          child: Text(line),
        ),

      _Section(AppText.theStep),
      AlertInfoLine(icon: Icons.person, text: stepByWhom(alert)),
      AlertInfoLine(
        icon: Icons.phone_android,
        text: AppText.phoneTime(alert.step.capturedAt.toLocal()),
      ),
      AlertInfoLine(
        icon: Icons.cloud_done,
        text: AppText.serverTime(alert.step.receivedAt.toLocal()),
      ),
      AlertInfoLine(
        icon: Icons.rule,
        text: _reviewText(alert.step.reviewStatus),
      ),

      _Section(AppText.theConsignment),
      AlertInfoLine(
        icon: Icons.qr_code,
        text: AppText.qrCodeLine(alert.consignment.qrCode),
      ),
      AlertInfoLine(
        icon: Icons.diamond,
        text: AppText.mineralLine(mineralName(alert.consignment.mineral)),
      ),
      AlertInfoLine(
        icon: Icons.route,
        text: AppText.stageLine(stageWord(alert.consignment.stage)),
      ),
      AlertInfoLine(
        icon: alert.consignment.held ? Icons.pause_circle : Icons.play_circle,
        text: alert.consignment.held
            ? AppText.consignmentHeld
            : AppText.consignmentNotHeld,
      ),

      _Section(AppText.otherAlerts),
      if (others.isEmpty) const Text(AppText.noOtherAlerts),
      for (final other in others)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(alertHeading(other.type), style: text.titleSmall),
              AlertInfoLine(
                icon: _statusIcon(other.status),
                text: AppText.otherAlertLine(
                  _otherStatusWord(other.status),
                  other.createdAt.toLocal(),
                ),
              ),
            ],
          ),
        ),
      if (anotherOpen && alert.isOpen) ...[
        const SizedBox(height: AppSizes.spaceS),
        const AlertInfoLine(
          icon: Icons.pause_circle,
          text: AppText.anotherAlertHolds,
        ),
      ],

      if (review != null) ...[
        _Section(AppText.theDecision),
        AlertInfoLine(icon: Icons.gavel, text: decisionLine(alert) ?? ''),
        AlertInfoLine(icon: Icons.notes, text: AppText.notesLine(review.notes)),
      ],

      if (alert.isOpen) ...[
        const SizedBox(height: AppSizes.spaceL),
        if (!canClear) ...[
          const AlertInfoLine(
            icon: Icons.info_outline,
            text: AppText.onlyConfirm,
          ),
          const SizedBox(height: AppSizes.spaceS),
        ],
        // Wrap, not Row: at large text the buttons go one under the other.
        Wrap(
          spacing: AppSizes.spaceS,
          runSpacing: AppSizes.spaceS,
          children: [
            FilledButton.icon(
              onPressed: deciding
                  ? null
                  : () => _decide(
                      context,
                      ref,
                      alert,
                      AlertDecision.confirmProblem,
                    ),
              icon: const Icon(Icons.report),
              label: const Text(AppText.confirmProblem),
            ),
            if (canClear)
              OutlinedButton.icon(
                onPressed: deciding
                    ? null
                    : () => _decide(context, ref, alert, AlertDecision.clear),
                icon: const Icon(Icons.check_circle),
                label: const Text(AppText.clearNoProblem),
              ),
          ],
        ),
      ],
    ];
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref,
    Alert alert,
    AlertDecision decision,
  ) async {
    // The token first: an expired session asks for the password before
    // the notes are typed, not after.
    final signedIn = switch (ref.read(authControllerProvider)) {
      SignedIn() => true,
      SignedInNeedsPassword() => await showPasswordPrompt(context),
      SignedOut() || AuthUnknown() => false,
    };
    if (!signedIn || !context.mounted) return;

    final outcome = await showDialog<DecisionOutcome>(
      context: context,
      builder: (_) => _DecisionDialog(id: id, decision: decision),
    );
    if (outcome == null || !context.mounted) return;

    switch (outcome) {
      case DecisionDone():
        // Back to the list, which reads itself again and shows the message.
        context.pop(decisionMessage(outcome));
      case DecisionAlreadyMade():
        _say(context, AppText.alertAlreadyDecided);
      case DecisionNeedsPassword():
        _say(context, AppText.sessionExpired);
      case DecisionFailed(:final failure):
        _say(context, _decisionFailureText(failure));
      case DecisionIgnored():
        break;
    }
  }
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Q3: decisions are never queued, so "no network" says so plainly.
String _decisionFailureText(AppFailure failure) =>
    failure is NoConnection ? AppText.decisionNotSent : failureText(failure);

/// The message after a decision, from the server's answer: "Cleared.
/// MC-2026-LSK-0008 is no longer held. Stage: On its way." Parts the answer
/// did not carry are left out.
String decisionMessage(DecisionDone done) {
  final result = done.result;
  final parts = [
    done.decision == AlertDecision.confirmProblem
        ? AppText.confirmedDone
        : AppText.clearedDone,
    if (result.stepStatus == ReviewStatus.rejected) AppText.stepNeverAnchored,
    if (result.held == false) AppText.noLongerHeld(done.qrCode),
    if (result.held == true) AppText.stillHeld(done.qrCode),
    if (result.stage case final ConsignmentStage stage)
      '${AppText.stageLine(stageWord(stage))}.',
  ];
  return parts.join(' ');
}

IconData _statusIcon(AlertStatus status) => switch (status) {
  AlertStatus.open => Icons.hourglass_top,
  AlertStatus.reviewed => Icons.report,
  AlertStatus.dismissed => Icons.check_circle,
};

String _statusText(Alert alert) => switch (alert.status) {
  AlertStatus.open => AppText.alertIsOpen,
  AlertStatus.reviewed => AppText.alertIsConfirmed,
  AlertStatus.dismissed => AppText.alertIsCleared,
};

String _otherStatusWord(AlertStatus status) => switch (status) {
  AlertStatus.open => AppText.otherStatusOpen,
  AlertStatus.reviewed => AppText.otherStatusConfirmed,
  AlertStatus.dismissed => AppText.otherStatusCleared,
};

/// The step's review status, in the consignment check's words.
String _reviewText(ReviewStatus status) => switch (status) {
  ReviewStatus.passed => AppText.reviewPassed,
  ReviewStatus.cleared => AppText.reviewCleared,
  ReviewStatus.flagged => AppText.reviewFlagged,
  ReviewStatus.rejected => AppText.reviewRejected,
};

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSizes.spaceL,
        bottom: AppSizes.spaceS,
      ),
      child: Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}

// ---- The decision dialog (T4) ------------------------------------------------------

/// The API's name for the one field, as in its `details`.
const _notesField = 'notes';

/// "Confirm the problem?" or "Clear this alert?", with the notes. It sends
/// the decision itself, so a refusal can be shown while the notes stay, and
/// closes with the outcome once there is nothing more to fix here.
class _DecisionDialog extends ConsumerStatefulWidget {
  const _DecisionDialog({required this.id, required this.decision});

  final String id;
  final AlertDecision decision;

  @override
  ConsumerState<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends ConsumerState<_DecisionDialog>
    with FieldErrorsMixin<_DecisionDialog> {
  final _notes = TextEditingController();
  bool _sending = false;

  /// A refusal that is not about the field, shown under it.
  String? _failure;

  bool get _confirm => widget.decision == AlertDecision.confirmProblem;

  /// Counted after trimming, as the server counts it.
  bool get _longEnough => _notes.text.trim().length >= decisionNotesMin;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || !_longEnough) return;
    setState(() {
      _sending = true;
      setFieldErrors(const {});
      _failure = null;
    });
    final outcome = await ref
        .read(alertDetailControllerProvider(widget.id).notifier)
        .decide(widget.decision, _notes.text);
    if (!mounted) return;

    switch (outcome) {
      case DecisionFailed(:final failure, :final fieldErrors):
        // Stay open with the notes: they can be fixed, or sending tried
        // again, or "Confirm problem" chosen instead.
        setState(() {
          _sending = false;
          final notesError = fieldErrors[_notesField];
          if (notesError != null) {
            setFieldErrors({_notesField: notesError});
          } else {
            _failure = _decisionFailureText(failure);
          }
        });
      case DecisionIgnored():
        setState(() => _sending = false);
      case DecisionDone() || DecisionAlreadyMade() || DecisionNeedsPassword():
        Navigator.of(context).pop(outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final action = _confirm ? AppText.confirmProblem : AppText.clearNoProblem;
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        scrollable: true,
        title: Text(_confirm ? AppText.confirmQuestion : AppText.clearQuestion),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_confirm ? AppText.confirmExplains : AppText.clearExplains),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _notes,
              enabled: !_sending,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              // The "12/500" counter, and typing stops at 500.
              maxLength: decisionNotesMax,
              textCapitalization: TextCapitalization.sentences,
              // setState as well: the button's state follows the length.
              onChanged: (_) {
                clearFieldError(_notesField);
                setState(() {});
              },
              decoration: InputDecoration(
                labelText: AppText.decisionNotes,
                hintText: AppText.decisionNotesHint,
                helperText: _longEnough ? null : AppText.decisionNotesTooShort,
                helperMaxLines: 2,
                errorText: fieldError(_notesField),
                errorMaxLines: 3,
                hintMaxLines: 3,
              ),
            ),
            const SizedBox(height: AppSizes.spaceS),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Icon(Icons.warning_amber)),
                SizedBox(width: AppSizes.spaceS),
                Expanded(child: Text(AppText.decisionNotesWarning)),
              ],
            ),
            if (_failure != null) ...[
              const SizedBox(height: AppSizes.spaceM),
              FormMessage(_failure!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(),
            child: const Text(AppText.cancel),
          ),
          FilledButton(
            onPressed: _sending || !_longEnough ? null : _send,
            child: _sending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SmallSpinner(),
                      SizedBox(width: AppSizes.spaceS),
                      Flexible(child: Text(AppText.sending)),
                    ],
                  )
                : Text(action),
          ),
        ],
      ),
    );
  }
}
