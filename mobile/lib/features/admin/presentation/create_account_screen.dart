// "Create account" (admin accounts plan §4.3–4.4, T5; FR-10): a new officer
// or administrator account, then its activation code, shown once.
//
// What the app checks itself, and what it leaves to the server, as on the
// register screen: here, that each field is filled and a role is chosen
// (there is no default role, so it is always chosen on purpose); the server, the
// username's characters and length and whether it is taken. Its answers go
// under the fields they are about.
//
// After a 201 the screen shows the code (ActivationCodeView). "Done" closes
// it and tells the list an account was created, so the list shows
// "Invited", where the new account now is.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/errors/field_errors.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart' show Role;
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../data/admin_users_repository.dart';
import '../domain/admin_account.dart';
import 'account_words.dart';
import 'activation_code_view.dart';

/// Field keys: the API's own names, so server details land under the right
/// field with no translation.
abstract final class _Field {
  static const username = 'username';
  static const fullName = 'fullName';
  static const role = 'role';
}

/// The two roles an administrator creates (api.md: "officer or admin").
const List<Role> creatableRoles = [Role.officer, Role.admin];

class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  ConsumerState<CreateAccountScreen> createState() =>
      _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen>
    with FieldErrorsMixin<CreateAccountScreen> {
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  Role? _role;
  bool _sending = false;
  String? _formError;

  /// The created account and its code, once the server has answered 201.
  /// Held only here: gone when the screen closes.
  InvitedAccount? _created;

  @override
  void dispose() {
    _fullName.dispose();
    _username.dispose();
    super.dispose();
  }

  Map<String, String> _checkLocally() => {
    if (_fullName.text.trim().isEmpty)
      _Field.fullName: AppText.enterAccountFullName,
    if (_username.text.trim().isEmpty)
      _Field.username: AppText.enterAccountUsername,
    if (_role == null) _Field.role: AppText.chooseNewAccountRole,
  };

  Future<void> _submit() async {
    if (_sending) return;
    final problems = _checkLocally();
    if (problems.isNotEmpty) {
      setState(() {
        setFieldErrors(problems);
        _formError = null;
      });
      return; // nothing is sent
    }

    // The token first: an expired one asks for the password.
    final ok = switch (ref.read(authControllerProvider)) {
      SignedIn() => true,
      SignedInNeedsPassword() => await showPasswordPrompt(context),
      SignedOut() || AuthUnknown() => false,
    };
    if (!ok || !mounted) return;
    final auth = ref.read(authControllerProvider);
    if (auth is! SignedIn) return;

    setState(() {
      _sending = true;
      setFieldErrors(const {});
      _formError = null;
    });
    try {
      final created = await ref
          .read(adminUsersRepositoryProvider)
          .create(
            token: auth.token,
            username: _username.text,
            fullName: _fullName.text,
            role: _role!,
          );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _created = created;
      });
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _showFailure(failure);
      });
    }
  }

  /// Puts each part of a failure where it belongs. Called inside setState.
  void _showFailure(AppFailure failure) {
    if (failure is ServerRefused) {
      if (failure.code == ApiCodes.usernameTaken) {
        setFieldErrors({_Field.username: AppText.usernameTaken});
        return;
      }
      final byField = fieldErrorsFrom(failure.details);
      setFieldErrors(byField);
      // Every problem is under its field: a sentence below would only
      // repeat it.
      if (byField.isNotEmpty &&
          byField.keys.every(
            (k) =>
                k == _Field.username ||
                k == _Field.fullName ||
                k == _Field.role,
          )) {
        return;
      }
    }
    _formError = failureText(failure);
  }

  Future<void> _back() async {
    if (_created != null) {
      // The code can never be shown again: ask first.
      if (!await confirmLeaveCode(context) || !mounted) return;
      context.pop(true);
      return;
    }
    backOrHome(context, AppRoutes.adminAccounts);
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    return PopScope(
      canPop: !_sending && created == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_sending) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _sending ? null : _back),
          title: Text(
            created == null
                ? AppText.createAccount
                : AppText.activationCodeTitle,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              key: const ValueKey('create-account-page'),
              padding: const EdgeInsets.all(AppSizes.spaceL),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: created != null
                    ? ActivationCodeView(
                        account: created.account,
                        code: created.activation,
                        onDone: () => context.pop(true),
                      )
                    : _form(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(AppText.createAccountIntro),
        const SizedBox(height: AppSizes.spaceL),
        TextField(
          controller: _fullName,
          enabled: !_sending,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          maxLength: 100,
          onChanged: (_) => clearFieldError(_Field.fullName),
          decoration: InputDecoration(
            labelText: AppText.fullName,
            prefixIcon: const Icon(Icons.person),
            errorText: fieldError(_Field.fullName),
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceS),
        TextField(
          controller: _username,
          enabled: !_sending,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 32,
          onChanged: (_) => clearFieldError(_Field.username),
          decoration: InputDecoration(
            labelText: AppText.username,
            prefixIcon: const Icon(Icons.badge),
            helperText: AppText.usernameRulesHint,
            helperMaxLines: 3,
            errorText: fieldError(_Field.username),
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: AppSizes.spaceL),
        Text(
          AppText.newAccountRole,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSizes.spaceS),
        for (final role in creatableRoles) ...[
          _RoleChoice(
            role: role,
            selected: role == _role,
            onTap: _sending
                ? null
                : () {
                    setState(() => _role = role);
                    clearFieldError(_Field.role);
                  },
          ),
          const SizedBox(height: AppSizes.spaceS),
        ],
        if (fieldError(_Field.role) case final roleError?)
          FormMessage(roleError),
        if (_formError != null) ...[
          const SizedBox(height: AppSizes.spaceM),
          FormMessage(_formError!),
        ],
        const SizedBox(height: AppSizes.spaceL),
        BusyButton(
          label: AppText.createAccount,
          busy: _sending,
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// One role as a large choice, like the register screen's: an icon, the
/// word, what it means, and a tick when chosen (never colour alone).
class _RoleChoice extends StatelessWidget {
  const _RoleChoice({
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
    final hint = role == Role.officer
        ? AppText.officerRoleHint
        : AppText.adminRoleHint;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSizes.tileRadius),
      side: BorderSide(
        color: selected ? scheme.primary : scheme.outline,
        width: selected ? 3 : 1,
      ),
    );
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
                  Icon(roleIcon(role), size: AppSizes.tileIcon),
                  const SizedBox(width: AppSizes.spaceM),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(roleLabel(role), style: text.titleMedium),
                        Text(hint, style: text.bodyMedium),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSizes.spaceS),
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
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
