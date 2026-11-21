// One zone's page (GPS zones plan §4.2 and §4.4, T3 and T4): its name,
// licence number, status and dates, a sketch of its shape, its corners, and
// the actions its status allows (zone_actions.dart).
//
// Opened from the "GPS zones" list, which puts the zone in
// openedZoneProvider first: there is no GET /admin/zones/{id}, so a page
// opened without one sends the administrator back to the list.
//
// Each action asks first: the name (rename), a reason (deactivate), or a
// confirmation (reactivate). The dialogs that send keep what was typed when
// the server refuses and say why. After a 200 the page shows the zone from
// the answer and a one-line message; a deactivation that left no zone
// active also shows the server's warning in a dialog that must be closed
// (Q4), so it cannot be missed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage, SmallSpinner;
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/corner_input.dart';
import '../domain/gps_zone.dart';
import '../domain/zone_actions.dart';
import 'reason_dialog.dart';
import 'zone_page_controller.dart';
import 'zone_shape_view.dart';
import 'zone_words.dart';
import 'zones_list_controller.dart';

class ZonePageScreen extends ConsumerWidget {
  const ZonePageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final start = ref.watch(openedZoneProvider);
    if (start == null) return const _NoZone();

    final state = ref.watch(zonePageControllerProvider(start));
    final busy = state.busy != null;

    return PopScope(
      // Not while an action is on its way: its answer needs this page.
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: busy
                ? null
                : () => backOrHome(context, AppRoutes.adminZones),
          ),
          title: const Text(AppText.zoneTitle),
        ),
        body: SafeArea(
          child: ListView(
            key: const ValueKey('zone-page'),
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _Details(state: state, start: start),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoZone extends StatelessWidget {
  const _NoZone();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go(AppRoutes.adminZones)),
        title: const Text(AppText.zoneTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          children: [
            AlertStateMessage(
              icon: Icons.search_off,
              text: AppText.zonePageGone,
              action: FilledButton(
                onPressed: () => context.go(AppRoutes.adminZones),
                child: const Text(AppText.backToZones),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- The details and the buttons ---------------------------------------------

class _Details extends ConsumerWidget {
  const _Details({required this.state, required this.start});

  final ZonePageState state;

  /// The provider's key: the row the list passed.
  final GpsZone start;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = state.zone;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(zone.name, style: text.headlineSmall),
        const SizedBox(height: AppSizes.spaceS),
        AlertInfoLine(
          icon: zoneStatusIcon(zone.status),
          text: zone.isActive ? AppText.zoneIsActive : AppText.zoneIsInactive,
        ),
        AlertInfoLine(
          icon: Icons.verified,
          text: zone.licenceNumber ?? AppText.noLicenceNumber,
        ),
        AlertInfoLine(
          icon: Icons.event,
          text: AppText.zoneCreatedAt(zone.createdAt.toLocal()),
        ),
        if (zone.updatedAt != zone.createdAt)
          AlertInfoLine(
            icon: Icons.update,
            text: AppText.zoneChangedAt(zone.updatedAt.toLocal()),
          ),
        const SizedBox(height: AppSizes.spaceM),
        Text(AppText.zoneShape, style: text.titleMedium),
        const SizedBox(height: AppSizes.spaceS),
        ZoneShapeView(corners: zone.boundary),
        const SizedBox(height: AppSizes.spaceXs),
        Text(AppText.zoneSketchNote, style: text.bodySmall),
        const SizedBox(height: AppSizes.spaceM),
        Text(AppText.zoneCornersHeading, style: text.titleMedium),
        const SizedBox(height: AppSizes.spaceS),
        for (var i = 0; i < zone.boundary.length; i++)
          CornerRow(number: i + 1, corner: zone.boundary[i]),
        const _Hint(AppText.zoneFixedBoundary),
        const SizedBox(height: AppSizes.spaceM),
        for (final action in zoneActionsFor(zone))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
            child: _ActionButton(
              action: action,
              busy: state.busy == action,
              enabled: state.busy == null,
              onPressed: () => _run(context, ref, action, start),
            ),
          ),
      ],
    );
  }
}

/// "Corner 1   -15.418327, 28.289494". Shared with "Create zone", where
/// [trailing] holds the remove button and [error] the server's message.
class CornerRow extends StatelessWidget {
  const CornerRow({
    required this.number,
    required this.corner,
    this.trailing,
    this.error,
    super.key,
  });

  final int number;
  final ZoneCorner corner;
  final Widget? trailing;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // With a button beside it, the line is at least the button's
                // 48 dp touch height, with the text centred in it, so the
                // text and the icon sit on one line (T6b, seen on the A57:
                // the icon sat lower). An error goes below that line, so the
                // button stays level with the corner, not with the error.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: trailing == null ? 0 : kMinInteractiveDimension,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    // Wrap: at large text the number and the coordinates go
                    // onto two lines instead of being cut.
                    child: Wrap(
                      spacing: AppSizes.spaceM,
                      children: [
                        Text(
                          AppText.cornerNumber(number),
                          style: theme.textTheme.labelLarge,
                        ),
                        Text(
                          cornerText(corner),
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSizes.spaceM),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(child: Icon(Icons.info_outline)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });

  final ZoneAction action;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (action) {
      ZoneAction.rename => (Icons.edit, AppText.renameZone),
      ZoneAction.deactivate => (Icons.pause_circle, AppText.deactivateZone),
      ZoneAction.reactivate => (Icons.play_circle, AppText.reactivateZone),
    };
    final shownIcon = busy ? const SmallSpinner() : Icon(icon);
    final pressed = enabled ? onPressed : null;
    return action == ZoneAction.reactivate
        ? FilledButton.icon(
            onPressed: pressed,
            icon: shownIcon,
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: pressed,
            icon: shownIcon,
            label: Text(label),
          );
  }
}

// ---- Running an action -----------------------------------------------------------

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Makes sure the token is usable before an action: asks for the password
/// if it has expired. False if the user cancelled.
Future<bool> _signedInFirst(BuildContext context, WidgetRef ref) async {
  return switch (ref.read(authControllerProvider)) {
    SignedIn() => true,
    SignedInNeedsPassword() => await showPasswordPrompt(context),
    SignedOut() || AuthUnknown() => false,
  };
}

/// Sends with [send]; if the session ran out on the way, asks for the
/// password on top of whatever is open, then sends once more. As
/// account_page_screen.dart's `_withPassword` (Admin accounts T6b); kept
/// separate because that one is typed to the account outcomes. The first send
/// was refused (401) before anything changed, so sending again cannot do the
/// action twice.
Future<ZoneActionOutcome> _withPassword(
  BuildContext context,
  Future<ZoneActionOutcome> Function() send,
) async {
  final outcome = await send();
  if (outcome is! ZoneActionNeedsPassword || !context.mounted) return outcome;
  if (!await showPasswordPrompt(context)) return outcome;
  return send();
}

/// What keeps a sending dialog open: a refusal about what was typed, any
/// other refusal (shown under the dialog), or a session that ran out and
/// whose password prompt was cancelled. Null closes the dialog: success, or
/// the zone being out of date (another administrator acted first; the page
/// then goes back to the list, which is read again).
ReasonProblem? _problem(ZoneActionOutcome outcome, String field) =>
    switch (outcome) {
      ZoneActionFailed(outOfDate: true) => null,
      ZoneActionFailed(:final failure, :final fieldErrors) =>
        fieldErrors[field] != null
            ? ReasonProblem(underField: fieldErrors[field])
            : failure is ServerRefused &&
                  failure.code == ApiCodes.zoneNameTaken &&
                  field == _nameField
            ? ReasonProblem(underField: failureText(failure))
            : ReasonProblem(underDialog: failureText(failure)),
      ZoneActionNeedsPassword() => const ReasonProblem(
        underDialog: AppText.sessionExpired,
      ),
      _ => null,
    };

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  ZoneAction action,
  GpsZone start,
) async {
  // Read before any await: the page keeps the controller alive meanwhile.
  final controller = ref.read(zonePageControllerProvider(start).notifier);
  if (!await _signedInFirst(context, ref) || !context.mounted) return;
  final zone = ref.read(zonePageControllerProvider(start)).zone;
  final name = zone.name;

  final ZoneActionOutcome? outcome;
  switch (action) {
    case ZoneAction.rename:
      outcome = await showDialog<ZoneActionOutcome>(
        context: context,
        builder: (_) => _RenameDialog(
          current: name,
          send: (typed) =>
              _withPassword(context, () => controller.rename(typed)),
        ),
      );
    case ZoneAction.deactivate:
      // Q4: warn first when the active list last read held only this zone.
      final onlyOne = ref.read(knownActiveZonesProvider) == 1;
      outcome = await showDialog<ZoneActionOutcome>(
        context: context,
        builder: (_) => ReasonDialog<ZoneActionOutcome>(
          title: AppText.deactivateZoneQuestion,
          explanation: [
            AppText.deactivateZoneExplanation(name),
            if (onlyOne) AppText.onlyActiveZone,
          ].join(' '),
          actionLabel: AppText.deactivateZone,
          hint: AppText.deactivateZoneHint,
          send: (reason) =>
              _withPassword(context, () => controller.deactivate(reason)),
          problemOf: (outcome) => _problem(outcome, 'reason'),
        ),
      );
    case ZoneAction.reactivate:
      final yes = await _confirm(
        context,
        title: AppText.reactivateZoneQuestion,
        explanation: AppText.reactivateZoneExplanation(name),
        actionLabel: AppText.reactivateZone,
      );
      outcome = yes && context.mounted
          ? await _withPassword(context, controller.reactivate)
          : null;
  }
  if (outcome == null || !context.mounted) return;

  switch (outcome) {
    case ZoneActionDone(zone: final changed, :final warning):
      _say(context, switch (action) {
        ZoneAction.rename => AppText.zoneRenamedDone(changed.name),
        ZoneAction.deactivate => AppText.zoneDeactivatedDone(name),
        ZoneAction.reactivate => AppText.zoneReactivatedDone(name),
      });
      if (action == ZoneAction.deactivate) {
        if (warning != null) {
          ref.read(knownActiveZonesProvider.notifier).set(0);
          await _showNoActiveZone(context, warning);
        }
      }
    case ZoneActionFailed(outOfDate: true, :final failure):
      // Another administrator acted first: the server's sentence names the
      // zone's real status, and the list, read again, shows it.
      _say(context, failureText(failure));
      backOrHome(context, AppRoutes.adminZones);
    case ZoneActionFailed(:final failure):
      _say(context, failureText(failure));
    case ZoneActionNeedsPassword():
      _say(context, AppText.sessionExpired);
    case ZoneActionIgnored():
      break;
  }
}

/// The NO_ACTIVE_ZONES warning: the server's sentence (or ours, if it sent
/// none), and one button. Not dismissed by tapping outside, so it is read.
Future<void> _showNoActiveZone(BuildContext context, ZoneWarning warning) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber),
        title: const Text(AppText.noActiveZoneTitle),
        content: Text(warning.message ?? AppText.noActiveZone),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(AppText.iUnderstand),
          ),
        ],
      ),
    );

/// A one-sentence question with Cancel and [actionLabel]. True to go on.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String explanation,
  required String actionLabel,
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(explanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(AppText.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
  return yes == true;
}

/// The API's field name, as in its `details`.
const _nameField = 'name';

/// "Rename zone": the name filled in, 3–100 characters. It sends the request
/// itself and closes with the outcome, or with null when nothing changed
/// (the same name after trimming is not sent at all).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current, required this.send});

  final String current;
  final Future<ZoneActionOutcome> Function(String name) send;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog>
    with FieldErrorsMixin<_RenameDialog> {
  late final _name = TextEditingController(text: widget.current);
  bool _sending = false;
  String? _failure;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_sending) return;
    final typed = _name.text.trim();
    if (typed.length < zoneNameMin) {
      setState(() {
        setFieldErrors({_nameField: AppText.zoneNameTooShort});
        _failure = null;
      });
      return;
    }
    // Exactly the same text: nothing to write. A change of letter case only
    // is a change, and is sent (api.md).
    if (typed == widget.current.trim()) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _sending = true;
      setFieldErrors(const {});
      _failure = null;
    });
    final outcome = await widget.send(_name.text);
    if (!mounted) return;
    final problem = _problem(outcome, _nameField);
    if (problem == null) {
      Navigator.of(context).pop(outcome);
      return;
    }
    setState(() {
      _sending = false;
      if (problem.underField case final underField?) {
        setFieldErrors({_nameField: underField});
      } else {
        _failure = problem.underDialog;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        scrollable: true,
        title: const Text(AppText.renameZoneTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppText.renameZoneExplanation),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _name,
              enabled: !_sending,
              autofocus: true,
              maxLength: zoneNameMax,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              onChanged: (_) => clearFieldError(_nameField),
              decoration: InputDecoration(
                labelText: AppText.zoneName,
                errorText: fieldError(_nameField),
                errorMaxLines: 4,
              ),
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
            onPressed: _sending ? null : _save,
            child: _sending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SmallSpinner(),
                      SizedBox(width: AppSizes.spaceS),
                      Flexible(child: Text(AppText.sending)),
                    ],
                  )
                : const Text(AppText.save),
          ),
        ],
      ),
    );
  }
}
