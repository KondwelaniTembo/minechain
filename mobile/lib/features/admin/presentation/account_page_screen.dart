// One account's page (admin accounts plan §4.2 and §4.5, T3 and T4): who it
// is, its status and why, its device key, and the actions its status allows
// (account_actions.dart). It also shows a new activation code once (T5).
//
// Opened from the "Accounts" list, which puts the account in
// openedAccountProvider first: there is no GET /admin/users/{id}, so a page
// opened without one (an app restored after Android closed it) sends the
// administrator back to the list.
//
// Each action asks first: a dialog with a reason (suspend, reset key,
// delete), a confirmation (reactivate, new code), or the name (edit name).
// The dialogs that send keep what was typed when the server refuses and say
// why. After a 200 the page shows the account from the answer and a one-line
// message.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/clock.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage, SmallSpinner;
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart' show AccountStatus;
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../device_key/domain/key_fingerprint.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/account_actions.dart';
import '../domain/admin_account.dart';
import 'account_page_controller.dart';
import 'account_words.dart';
import 'activation_code_view.dart';
import 'reason_dialog.dart';

/// The full name's limits (api.md, POST /admin/users/{id}/rename: "1–100
/// characters" after trimming).
const int fullNameMax = 100;

class AccountPageScreen extends ConsumerWidget {
  const AccountPageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row the list opened, or null if the page was opened without one.
    final start = ref.watch(openedAccountProvider);
    if (start == null) return const _NoAccount();

    final provider = accountPageControllerProvider(start);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final busy = state.busy != null;
    final code = state.code;

    Future<void> back() async {
      if (code != null) {
        // The code can never be shown again: ask, then go back to the
        // account's details (not off the page).
        if (await confirmLeaveCode(context)) controller.codeSeen();
        return;
      }
      if (context.mounted) backOrHome(context, AppRoutes.adminAccounts);
    }

    return PopScope(
      // Not while an action is on its way (its answer needs this page), and
      // not past a code without asking.
      canPop: !busy && code == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy) back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: busy ? null : back),
          title: Text(
            code != null ? AppText.activationCodeTitle : AppText.accountTitle,
          ),
        ),
        body: SafeArea(
          child: ListView(
            key: const ValueKey('account-page'),
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: code != null
                      ? ActivationCodeView(
                          account: state.account,
                          code: code,
                          onDone: controller.codeSeen,
                        )
                      : _Details(state: state, start: start),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoAccount extends StatelessWidget {
  const _NoAccount();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => context.go(AppRoutes.adminAccounts),
        ),
        title: const Text(AppText.accountTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          children: [
            AlertStateMessage(
              icon: Icons.search_off,
              text: AppText.accountPageGone,
              action: FilledButton(
                onPressed: () => context.go(AppRoutes.adminAccounts),
                child: const Text(AppText.backToAccounts),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- The details and the buttons -------------------------------------------------

class _Details extends ConsumerWidget {
  const _Details({required this.state, required this.start});

  final AccountPageState state;

  /// The provider's key: the row the list passed.
  final AdminAccount start;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = state.account;
    final text = Theme.of(context).textTheme;
    final ownId = switch (ref.watch(authControllerProvider)) {
      SignedIn(:final user) || SignedInNeedsPassword(:final user) => user.id,
      _ => null,
    };
    final own = account.id == ownId;
    final keyRole = keyHoldingRoles.contains(account.role);
    final codeLine = account.status == AccountStatus.invited
        ? statusDetail(account, ref.read(clockProvider)())
        : null;
    final fingerprint = account.publicKeyFingerprint;
    final actions = actionsFor(account, own: own);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(account.fullName, style: text.headlineSmall),
        const SizedBox(height: AppSizes.spaceS),
        AlertInfoLine(icon: Icons.badge, text: account.username),
        AlertInfoLine(
          icon: roleIcon(account.role),
          text: roleLabel(account.role),
        ),
        AlertInfoLine(
          icon: statusIcon(account.status),
          text: statusSentence(account.status),
        ),
        if (keyRole)
          AlertInfoLine(
            icon: Icons.verified,
            text: account.licenceNumber ?? AppText.noLicenceNumber,
          ),
        AlertInfoLine(
          icon: Icons.event,
          // Requested by the person for the three self-registering roles,
          // created by an administrator for officers and administrators.
          text: keyRole
              ? AppText.requestedOn(account.createdAt.toLocal())
              : AppText.createdOn(account.createdAt.toLocal()),
        ),
        if (account.approvedAt case final approved?)
          AlertInfoLine(
            icon: Icons.how_to_reg,
            text: AppText.approvedOn(approved.toLocal()),
          ),
        if (account.statusReason case final reason?)
          AlertInfoLine(icon: Icons.notes, text: AppText.reasonLine(reason)),
        if (codeLine != null) AlertInfoLine(icon: Icons.mail, text: codeLine),
        if (keyRole)
          AlertInfoLine(
            icon: Icons.key,
            // The same eight characters the person's "My account" shows.
            text: fingerprint == null
                ? AppText.accountNoDeviceKey
                : AppText.accountDeviceKey(shortFingerprint(fingerprint)),
          ),
        if (own) const _Hint(AppText.yourOwnAccount),
        if (!own &&
            account.status == AccountStatus.active &&
            keyRole &&
            account.hasDeviceKey)
          const _Hint(AppText.lostPhoneHint),
        if (account.status == AccountStatus.rejected ||
            account.status == AccountStatus.deleted)
          const _Hint(AppText.accountIsFinal),
        if (actions.isNotEmpty) const SizedBox(height: AppSizes.spaceM),
        for (final action in actions)
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

  final AccountAction action;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = switch (action) {
      AccountAction.rename => (Icons.edit, AppText.editName),
      AccountAction.suspend => (Icons.pause_circle, AppText.suspendAccount),
      AccountAction.resetKey => (Icons.key_off, AppText.resetDeviceKey),
      AccountAction.reactivate => (
        Icons.play_circle,
        AppText.reactivateAccount,
      ),
      AccountAction.newCode => (Icons.mail, AppText.newActivationCode),
      AccountAction.delete => (Icons.delete_forever, AppText.deleteAccount),
    };
    final shownIcon = busy ? const SmallSpinner() : Icon(icon);
    final pressed = enabled ? onPressed : null;
    final child = Text(label);

    return switch (action) {
      // The step the status is waiting for is the filled one.
      AccountAction.reactivate || AccountAction.newCode => FilledButton.icon(
        onPressed: pressed,
        icon: shownIcon,
        label: child,
      ),
      // Delete last and in the error colour: it cannot be undone.
      AccountAction.delete => FilledButton.icon(
        onPressed: pressed,
        icon: shownIcon,
        label: child,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
      ),
      _ => OutlinedButton.icon(
        onPressed: pressed,
        icon: shownIcon,
        label: child,
      ),
    };
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

/// What keeps a sending dialog open: a refusal, or a session that ran out
/// and whose password prompt was cancelled (T6b: the text typed is kept, and
/// pressing the button again asks for the password again).
ReasonProblem? _problem(AccountActionOutcome outcome, String field) =>
    switch (outcome) {
      AccountActionFailed(:final failure, :final fieldErrors) =>
        fieldErrors[field] != null
            ? ReasonProblem(underField: fieldErrors[field])
            : ReasonProblem(underDialog: failureText(failure)),
      AccountActionNeedsPassword() => const ReasonProblem(
        underDialog: AppText.sessionExpired,
      ),
      _ => null,
    };

/// Sends with [send]; if the session ran out on the way (the 60-minute
/// token), asks for the password on top of whatever is open, then sends
/// once more. Admin accounts T6b: in the phone check the "Edit full name"
/// dialog said the session had expired but offered no way to sign in again,
/// so the name had to be typed a second time.
///
/// The first send was refused (401) before anything changed, so sending
/// again cannot do the action twice.
Future<AccountActionOutcome> _withPassword(
  BuildContext context,
  Future<AccountActionOutcome> Function() send,
) async {
  final outcome = await send();
  if (outcome is! AccountActionNeedsPassword || !context.mounted) {
    return outcome;
  }
  if (!await showPasswordPrompt(context)) return outcome;
  return send();
}

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  AccountAction action,
  AdminAccount start,
) async {
  // Read before any await: the page keeps the controller alive meanwhile.
  final controller = ref.read(accountPageControllerProvider(start).notifier);
  if (!await _signedInFirst(context, ref) || !context.mounted) return;
  final account = ref.read(accountPageControllerProvider(start)).account;
  final name = account.fullName;

  final AccountActionOutcome? outcome;
  switch (action) {
    case AccountAction.rename:
      outcome = await showDialog<AccountActionOutcome>(
        context: context,
        builder: (_) => _EditNameDialog(
          current: name,
          send: (fullName) =>
              _withPassword(context, () => controller.rename(fullName)),
        ),
      );
    case AccountAction.suspend:
      outcome = await _reasonDialog(
        context,
        title: AppText.suspendQuestion,
        explanation: AppText.suspendExplanation(name),
        actionLabel: AppText.suspendAccount,
        hint: AppText.suspendHint,
        send: (reason) =>
            _withPassword(context, () => controller.suspend(reason)),
      );
    case AccountAction.resetKey:
      outcome = await _reasonDialog(
        context,
        title: AppText.resetKeyQuestion,
        explanation: AppText.resetKeyExplanation(name),
        actionLabel: AppText.resetKey,
        hint: AppText.resetKeyHint,
        send: (reason) =>
            _withPassword(context, () => controller.resetKey(reason)),
      );
    case AccountAction.delete:
      // Q4: the reason dialog, its "cannot be undone" sentence and a red
      // "Delete for good".
      outcome = await _reasonDialog(
        context,
        title: AppText.deleteQuestion,
        explanation: AppText.deleteExplanation(name),
        actionLabel: AppText.deleteForGood,
        hint: AppText.deleteHint,
        send: (reason) =>
            _withPassword(context, () => controller.delete(reason)),
        destructive: true,
      );
    case AccountAction.reactivate:
      final keyWasReset =
          keyHoldingRoles.contains(account.role) && !account.hasDeviceKey;
      final yes = await _confirm(
        context,
        title: AppText.reactivateQuestion,
        explanation: [
          AppText.reactivateExplanation(name),
          if (keyWasReset) AppText.reactivateAfterReset,
        ].join(' '),
        actionLabel: AppText.reactivateAccount,
      );
      outcome = yes && context.mounted
          ? await _withPassword(context, controller.reactivate)
          : null;
    case AccountAction.newCode:
      final yes = await _confirm(
        context,
        title: AppText.newCodeQuestion,
        explanation: AppText.newCodeExplanation,
        actionLabel: AppText.giveNewCode,
      );
      outcome = yes && context.mounted
          ? await _withPassword(context, controller.newCode)
          : null;
  }
  if (outcome == null || !context.mounted) return;

  final message = switch (outcome) {
    AccountActionDone(account: final renamed) => switch (action) {
      AccountAction.rename => AppText.renamedDone(renamed.fullName),
      AccountAction.suspend => AppText.suspendedDone(name),
      AccountAction.resetKey => AppText.resetKeyDone(name),
      AccountAction.reactivate => AppText.reactivatedDone(name),
      AccountAction.delete => AppText.deletedDone(name),
      // The code view says it all.
      AccountAction.newCode => null,
    },
    AccountActionFailed(:final failure) => failureText(failure),
    AccountActionNeedsPassword() => AppText.sessionExpired,
    AccountActionIgnored() => null,
  };
  if (message != null) _say(context, message);
}

Future<AccountActionOutcome?> _reasonDialog(
  BuildContext context, {
  required String title,
  required String explanation,
  required String actionLabel,
  required String hint,
  required Future<AccountActionOutcome> Function(String reason) send,
  bool destructive = false,
}) => showDialog<AccountActionOutcome>(
  context: context,
  builder: (_) => ReasonDialog<AccountActionOutcome>(
    title: title,
    explanation: explanation,
    actionLabel: actionLabel,
    hint: hint,
    send: send,
    problemOf: (outcome) => _problem(outcome, 'reason'),
    destructive: destructive,
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

/// "Edit full name": the name filled in, 1–100 characters. It sends the
/// request itself and closes with the outcome, or with null when nothing
/// changed (the same name after trimming is not sent at all).
class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.current, required this.send});

  final String current;
  final Future<AccountActionOutcome> Function(String fullName) send;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

/// The API's field name, as in its `details`.
const _fullNameField = 'fullName';

class _EditNameDialogState extends State<_EditNameDialog>
    with FieldErrorsMixin<_EditNameDialog> {
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
    if (typed.isEmpty) {
      setState(() {
        setFieldErrors({_fullNameField: AppText.enterAccountFullName});
        _failure = null;
      });
      return;
    }
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
    final problem = _problem(outcome, _fullNameField);
    if (problem == null) {
      Navigator.of(context).pop(outcome);
      return;
    }
    setState(() {
      _sending = false;
      if (problem.underField case final underField?) {
        setFieldErrors({_fullNameField: underField});
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
        title: const Text(AppText.editNameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppText.editNameExplanation),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _name,
              enabled: !_sending,
              autofocus: true,
              maxLength: fullNameMax,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              onChanged: (_) => clearFieldError(_fullNameField),
              decoration: InputDecoration(
                labelText: AppText.fullName,
                errorText: fieldError(_fullNameField),
                errorMaxLines: 3,
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
