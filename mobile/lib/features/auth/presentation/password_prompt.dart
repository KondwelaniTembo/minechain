// "Enter your password": the dialog shown when the token has expired and the
// user is still signed in (decision Q2).
//
// It is its own widget, opened through one function, so any screen can ask
// for the password before it talks to the server. A later module will do
// exactly that before "Send my work":
//
//   if (auth is SignedInNeedsPassword && !await showPasswordPrompt(context)) {
//     return; // cancelled: nothing is sent
//   }
//
// SECURITY: the password lives only in the TextEditingController, which is
// cleared as soon as an attempt is sent and again when the dialog closes. It
// is never logged, saved or put into an error. The username is not asked
// for: AuthController.reauthenticate uses the account already on this phone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure_text.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../domain/auth_state.dart';
import 'auth_controller.dart';

/// Opens the password prompt and waits until it closes.
///
/// Returns true if the password was accepted (the state is SignedIn again),
/// false if the user cancelled, or if they were signed out meanwhile (the
/// router then shows the login screen with the reason).
Future<bool> showPasswordPrompt(BuildContext context) async {
  // showDialog puts the dialog on top of the current screen and returns a
  // Future. That Future completes with whatever the dialog passes to
  // Navigator.pop(...), or with null if it was dismissed some other way.
  final accepted = await showDialog<bool>(
    context: context,
    builder: (_) => const PasswordPromptDialog(),
  );
  return accepted ?? false;
}

/// The dialog itself. Open it with [showPasswordPrompt], not directly.
class PasswordPromptDialog extends ConsumerStatefulWidget {
  const PasswordPromptDialog({super.key});

  @override
  ConsumerState<PasswordPromptDialog> createState() =>
      _PasswordPromptDialogState();
}

/// The one field's key for FieldErrorsMixin.
const _passwordField = 'password';

class _PasswordPromptDialogState extends ConsumerState<PasswordPromptDialog>
    with FieldErrorsMixin<PasswordPromptDialog> {
  final _password = TextEditingController();

  bool _sending = false;
  bool _hidden = true;

  /// The sentence for the last failed attempt, or null.
  String? _failure;

  @override
  void dispose() {
    // Clear, then dispose, as on the login screen.
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    if (_password.text.isEmpty) {
      // Nothing is sent for an empty field: it could only fail, and failed
      // logins count towards the server's limit.
      setState(() {
        setFieldErrors({_passwordField: AppText.enterPassword});
        _failure = null;
      });
      return;
    }

    // Take the password out of the field and clear the field at once, so it
    // is cleared after every attempt whatever the outcome, and even if the
    // dialog is closed while waiting.
    final password = _password.text;
    _password.clear();
    setState(() {
      _sending = true;
      setFieldErrors(const {});
      _failure = null;
    });

    final outcome = await ref
        .read(authControllerProvider.notifier)
        .reauthenticate(password);

    // The dialog may already be gone (for example the router replaced the
    // screen under it after a sign-out). A State that is gone must not call
    // setState or use its context.
    if (!mounted) return;

    // Decide from the state the controller is in now, not only from the
    // outcome: that covers every case with three rules.
    switch (ref.read(authControllerProvider)) {
      case SignedIn():
        // Accepted. pop(true) closes the dialog and becomes the value that
        // showPasswordPrompt's Future completes with.
        Navigator.of(context).pop(true);
      case SignedInNeedsPassword():
        // Still waiting for the right password: stay open, say why.
        setState(() {
          _sending = false;
          if (outcome is LoginFailed) _failure = failureText(outcome.failure);
        });
      case SignedOut() || AuthUnknown():
        // Signed out (a suspended account, a different account): close. The
        // login screen shows the reason.
        Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PopScope with canPop: false blocks the Android back button and a tap
    // outside the dialog while a check is running, so the answer always has
    // a dialog to come back to.
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        // scrollable: the title and content scroll when they do not fit (a
        // turned phone, the keyboard open, large text).
        scrollable: true,
        title: const Text(AppText.enterYourPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppText.passwordPromptExplanation),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _password,
              enabled: !_sending,
              // The keyboard opens straight away: typing the password is the
              // only thing to do here.
              autofocus: true,
              obscureText: _hidden,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              autocorrect: false,
              enableSuggestions: false,
              // Typing again takes "Enter your password." away.
              onChanged: (_) => clearFieldError(_passwordField),
              decoration: InputDecoration(
                labelText: AppText.password,
                prefixIcon: const Icon(Icons.lock),
                errorText: fieldError(_passwordField),
                errorMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _hidden ? AppText.showPassword : AppText.hidePassword,
                  icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
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
            // pop(false): "cancelled", as the Future's answer.
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: const Text(AppText.cancel),
          ),
          FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: AppSizes.spaceS),
                      Flexible(child: Text(AppText.checkingPassword)),
                    ],
                  )
                : const Text(AppText.continueLabel),
          ),
        ],
      ),
    );
  }
}
