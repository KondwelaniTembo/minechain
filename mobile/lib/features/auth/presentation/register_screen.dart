// Request an account (FR-12, plan section 4.1, /register).
//
// A miner, transporter or buyer fills this in; an administrator approves the
// request later. Sending it does NOT sign anyone in: the account is pending,
// and the answer has no token (api.md, POST /auth/register).
//
// What the app checks itself, and what it leaves to the server:
//   - here: every required field is filled, a role is chosen, and the two
//     passwords are the same (only the person typing can know they mistyped);
//   - the server: username characters and length, whether it is taken, the
//     password policy, lengths of everything. Its answers go under the
//     fields they are about.
//
// SECURITY: the password is never logged, saved or put into an error. Both
// password fields are cleared after every attempt and when the screen closes.

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
import '../domain/user.dart';
import 'auth_controller.dart';

/// Field keys for the error map. The first five are the API's own field
/// names, so server details land under the right field with no translation.
abstract final class _Field {
  static const fullName = 'fullName';
  static const username = 'username';
  static const role = 'role';
  static const licenceNumber = 'licenceNumber';
  static const password = 'password';

  /// Ours only: the API has no "confirm" field.
  static const confirm = 'confirm';
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  final _licence = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// Nothing is chosen at first: guessing "miner" would let someone send the
  /// wrong role without noticing.
  Role? _role;

  bool _sending = false;

  /// True once the server accepted the request: the confirmation shows.
  bool _sent = false;

  /// One sentence under the whole form, or null.
  String? _formError;

  /// Sentences under single fields, keyed by [_Field].
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _password.clear();
    _confirm.clear();
    for (final controller in [
      _fullName,
      _username,
      _licence,
      _password,
      _confirm,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The checks only the app can make. Returns the problems, empty if none.
  Map<String, String> _checkLocally() {
    return {
      // trim(): a name of only spaces counts as empty (the server trims
      // these two fields too).
      if (_fullName.text.trim().isEmpty) _Field.fullName: AppText.enterFullName,
      if (_username.text.trim().isEmpty)
        _Field.username: AppText.enterNewUsername,
      if (_role == null) _Field.role: AppText.chooseRole,
      // Passwords are never trimmed: spaces may be part of them.
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
        // Two different passwords: nobody can see which one is wrong, so
        // both are typed again.
        if (problems[_Field.confirm] == AppText.passwordsDoNotMatch) {
          _password.clear();
          _confirm.clear();
        }
      });
      return; // nothing is sent
    }

    // Take the password out and clear both fields straight away, so they are
    // cleared after every attempt whatever happens next.
    final password = _password.text;
    _password.clear();
    _confirm.clear();
    setState(() {
      _sending = true;
      _fieldErrors = const {};
      _formError = null;
    });

    // Sent as typed: the server trims the text fields itself, and an empty
    // licence is left out by the repository.
    final outcome = await ref
        .read(authControllerProvider.notifier)
        .register(
          username: _username.text,
          fullName: _fullName.text,
          password: password,
          role: _role!,
          licenceNumber: _licence.text,
        );

    if (!mounted) return;
    setState(() {
      _sending = false;
      switch (outcome) {
        case RegisterSent():
          _sent = true;
        case RegisterFailed(:final failure):
          _showFailure(failure);
        case RegisterIgnored():
          break;
      }
    });
  }

  /// Puts each part of a failure where it belongs. Called inside setState.
  void _showFailure(AppFailure failure) {
    if (failure is ServerRefused) {
      if (failure.code == ApiCodes.usernameTaken) {
        // Only the username is wrong; say so right under it.
        _fieldErrors = {_Field.username: AppText.usernameTaken};
        return;
      }
      _fieldErrors = fieldErrorsFrom(failure.details);
      // A weak password with its reasons is fully explained under the
      // password field; a second sentence below the form would only repeat it.
      if (failure.code == ApiCodes.weakPassword &&
          _fieldErrors.containsKey(_Field.password)) {
        return;
      }
    }
    _formError = failureText(failure);
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return const FormPage(
        title: AppText.registerTitle,
        children: [_RequestSent()],
      );
    }

    return FormPage(
      title: AppText.registerTitle,
      children: [
        TextField(
          controller: _fullName,
          enabled: !_sending,
          autofillHints: const [AutofillHints.name],
          // Capital letter at the start of each word: "Mutale Banda".
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: AppText.fullName,
            prefixIcon: const Icon(Icons.person),
            errorText: _fieldErrors[_Field.fullName],
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        TextField(
          controller: _username,
          enabled: !_sending,
          autofillHints: const [AutofillHints.newUsername],
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
        const SizedBox(height: AppSizes.spaceL),
        _RoleChooser(
          selected: _role,
          enabled: !_sending,
          errorText: _fieldErrors[_Field.role],
          onChanged: (role) => setState(() => _role = role),
        ),
        const SizedBox(height: AppSizes.spaceM),
        // Optional for all three roles (api.md lists licenceNumber as
        // "Required: no", with no rule per role), so it is always shown and
        // never required.
        TextField(
          controller: _licence,
          enabled: !_sending,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: AppText.licenceNumberOptional,
            prefixIcon: const Icon(Icons.verified),
            helperText: AppText.licenceNumberHint,
            helperMaxLines: 3,
            errorText: _fieldErrors[_Field.licenceNumber],
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        PasswordField(
          controller: _password,
          label: AppText.password,
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
          label: AppText.sendRequest,
          busy: _sending,
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// The three roles as big choices: an icon, the word, and what it means.
///
/// Not a dropdown: a dropdown hides the choices until it is opened, and its
/// small text is hard to read and tap. Three large rows show everything at
/// once.
class _RoleChooser extends StatelessWidget {
  const _RoleChooser({
    required this.selected,
    required this.enabled,
    required this.errorText,
    required this.onChanged,
  });

  final Role? selected;
  final bool enabled;
  final String? errorText;
  final ValueChanged<Role> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppText.chooseRoleLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSizes.spaceS),
        for (final role in registrableRoles) ...[
          _RoleOption(
            role: role,
            selected: role == selected,
            onTap: enabled ? () => onChanged(role) : null,
          ),
          const SizedBox(height: AppSizes.spaceS),
        ],
        if (errorText != null) FormMessage(errorText!),
      ],
    );
  }
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final Role role;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final (icon, word, hint) = switch (role) {
      Role.miner => (Icons.landscape, AppText.minerTitle, AppText.minerRoleHint),
      Role.transporter => (
        Icons.local_shipping,
        AppText.transporterTitle,
        AppText.transporterRoleHint,
      ),
      Role.buyer => (
        Icons.storefront,
        AppText.buyerTitle,
        AppText.buyerRoleHint,
      ),
      // registrableRoles never contains these; the switch must still be
      // complete, so they get a plain look.
      Role.officer || Role.admin => (Icons.person, role.name, ''),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSizes.tileRadius),
      // A thicker border AND a tick for the chosen one: never colour alone.
      side: BorderSide(
        color: selected ? scheme.primary : scheme.outline,
        width: selected ? 3 : 1,
      ),
    );

    // Semantics tells TalkBack this is one choice of a group and whether it
    // is chosen: "Miner, selected" or "Transporter, not selected".
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.tapTargetMin),
            child: Padding(
              padding: const EdgeInsets.all(AppSizes.spaceM),
              child: Row(
                children: [
                  Icon(icon, size: AppSizes.tileIcon),
                  const SizedBox(width: AppSizes.spaceM),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(word, style: text.titleMedium),
                        if (hint.isNotEmpty) Text(hint, style: text.bodyMedium),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSizes.spaceS),
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Request sent", with the way back to the login screen.
class _RequestSent extends StatelessWidget {
  const _RequestSent();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.check_circle, size: 72, color: scheme.primary),
          const SizedBox(height: AppSizes.spaceM),
          Text(
            AppText.requestSentTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: AppSizes.spaceS),
          const Text(AppText.requestSentBody, textAlign: TextAlign.center),
          const SizedBox(height: AppSizes.spaceL),
          FilledButton(
            onPressed: () => backToLogin(context),
            child: const Text(AppText.backToLogin),
          ),
        ],
      ),
    );
  }
}
