// Activate an officer or administrator account (FR-10, plan section 4.1,
// /activate).
//
// An administrator created the account and was shown a one-time activation
// code, which they pass on to its owner. The owner types their username, the
// code and a password of their own here. The administrator never sees or
// chooses that password. The answer is the same as a login's, so a success
// signs in at once and the router moves to the role's home by itself.
//
// Checked here: every field filled and the two passwords the same. Checked
// by the server: the password policy (first, before the code is looked at),
// then the username and code together, with one answer for every way they
// can be wrong (ACTIVATION_INVALID).
//
// SECURITY: the password and the code are never logged or saved. Both
// password fields are cleared after every attempt; everything is cleared when
// the screen closes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/errors/field_errors.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/form_page.dart';
import '../../../core/widgets/password_field.dart';
import 'auth_controller.dart';
import 'login_screen.dart' show signOutReasonText;

/// Field keys: the API's field names, plus our own "confirm".
abstract final class _Field {
  static const username = 'username';
  static const code = 'code';
  static const password = 'password';
  static const confirm = 'confirm';
}

class ActivateScreen extends ConsumerStatefulWidget {
  const ActivateScreen({super.key});

  @override
  ConsumerState<ActivateScreen> createState() => _ActivateScreenState();
}

class _ActivateScreenState extends ConsumerState<ActivateScreen> {
  final _username = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _sending = false;
  String? _formError;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _password.clear();
    _confirm.clear();
    _code.clear();
    for (final controller in [_username, _code, _password, _confirm]) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, String> _checkLocally() {
    return {
      if (_username.text.trim().isEmpty) _Field.username: AppText.enterUsername,
      // Not trimmed for sending (api.md: "Not trimmed"), but a code of only
      // spaces is still empty.
      if (_code.text.trim().isEmpty) _Field.code: AppText.enterActivationCode,
      if (_password.text.isEmpty)
        _Field.password: AppText.choosePassword
      else if (_confirm.text.isEmpty)
        _Field.confirm: AppText.enterConfirmPassword
      else if (_password.text != _confirm.text)
        _Field.confirm: AppText.passwordsDoNotMatch,
    };
  }

  Future<void> _submit() async {
    if (_sending) return;

    final problems = _checkLocally();
    if (problems.isNotEmpty) {
      setState(() {
        _fieldErrors = problems;
        _formError = null;
        if (problems[_Field.confirm] == AppText.passwordsDoNotMatch) {
          _password.clear();
          _confirm.clear();
        }
      });
      return; // nothing is sent
    }

    final password = _password.text;
    _password.clear();
    _confirm.clear();
    setState(() {
      _sending = true;
      _fieldErrors = const {};
      _formError = null;
    });

    // The code is sent exactly as typed: the server accepts any letter case,
    // spaces and dashes, and reads O as 0 and I or L as 1.
    final outcome = await ref
        .read(authControllerProvider.notifier)
        .activate(
          username: _username.text,
          code: _code.text,
          password: password,
        );

    // After a success the router replaces this screen with the home, so it
    // may already be gone.
    if (!mounted) return;
    setState(() {
      _sending = false;
      switch (outcome) {
        case LoginSucceeded():
          break; // the router is already moving to the home
        case LoginFailed(:final failure):
          _showFailure(failure);
        case LoginNotPossible(:final reason):
          _formError = signOutReasonText(reason);
        case LoginIgnored():
          break;
      }
    });
    // The username and the code stay, so a typo in the code can be fixed
    // without typing everything again. Only the passwords were cleared.
  }

  void _showFailure(AppFailure failure) {
    if (failure is ServerRefused) {
      _fieldErrors = fieldErrorsFrom(failure.details);
      if (failure.code == ApiCodes.weakPassword &&
          _fieldErrors.containsKey(_Field.password)) {
        return; // fully explained under the password field
      }
    }
    // ACTIVATION_INVALID gets its plain sentence from failureText.
    _formError = failureText(failure);
  }

  @override
  Widget build(BuildContext context) {
    return FormPage(
      title: AppText.activateTitle,
      children: [
        const Text(AppText.activateExplanation),
        const SizedBox(height: AppSizes.spaceL),
        TextField(
          controller: _username,
          enabled: !_sending,
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: AppText.username,
            prefixIcon: const Icon(Icons.badge),
            errorText: _fieldErrors[_Field.username],
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        TextField(
          controller: _code,
          enabled: !_sending,
          textInputAction: TextInputAction.next,
          // Capitals as typed, as the administrator saw it (7KQ4-M2XD-9TNE),
          // though any case works.
          textCapitalization: TextCapitalization.characters,
          // visiblePassword: a keyboard with letters and digits and no word
          // suggestions, so the code is not "corrected" or remembered.
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: AppText.activationCode,
            prefixIcon: const Icon(Icons.pin),
            helperText: AppText.activationCodeHint,
            helperMaxLines: 3,
            errorText: _fieldErrors[_Field.code],
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        PasswordField(
          controller: _password,
          label: AppText.newPassword,
          enabled: !_sending,
          helperText: AppText.passwordPolicyHint,
          errorText: _fieldErrors[_Field.password],
        ),
        const SizedBox(height: AppSizes.spaceM),
        PasswordField(
          controller: _confirm,
          label: AppText.confirmPassword,
          enabled: !_sending,
          errorText: _fieldErrors[_Field.confirm],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        if (_formError != null) ...[
          const SizedBox(height: AppSizes.spaceM),
          FormMessage(_formError!),
        ],
        const SizedBox(height: AppSizes.spaceL),
        BusyButton(
          label: AppText.activateButton,
          busy: _sending,
          onPressed: _submit,
        ),
      ],
    );
  }
}
