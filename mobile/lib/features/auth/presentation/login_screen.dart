// The login screen (plan sections 4.1, 5.5 and 6).
//
// The screen only collects two values and shows what happened. Logging in,
// saving the session and choosing the next screen are done elsewhere: the
// AuthController logs in, and the router moves to the role's home by itself
// when the sign-in state changes.
//
// SECURITY: the username and password are never logged and never put into an
// error. The password exists only inside its TextEditingController, which is
// cleared after every attempt and when the screen closes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/network/server_status.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/server_status_banner.dart';
import '../domain/auth_state.dart';
import 'auth_controller.dart';

/// The sentence for a SignedOut reason: an API code, or one of [AuthReasons].
String signOutReasonText(String reason) => switch (reason) {
  ApiCodes.tokenInvalid || ApiCodes.tokenMissing => AppText.sessionNotValid,
  ApiCodes.tokenExpired => AppText.sessionExpired,
  ApiCodes.accountPending => AppText.accountPending,
  ApiCodes.accountSuspended => AppText.accountSuspended,
  ApiCodes.accountRejected => AppText.accountRejected,
  ApiCodes.accountNotActive => AppText.accountNotActive,
  AuthReasons.unsupportedRole => AppText.unsupportedApp,
  AuthReasons.accountChanged => AppText.accountChanged,
  _ => AppText.loggedOut,
};

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  // A TextEditingController holds what is typed in a text field. The State
  // creates it once and must dispose of it when the screen closes, or it stays
  // in memory.
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _sending = false;
  bool _passwordHidden = true;

  /// The sentence under the form after a failed attempt, or null.
  String? _formError;

  /// Per-field sentences: "enter your username", or the server's details.
  String? _usernameError;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    // Start waking the server while the user types (plan section 5.5). After
    // the first frame, because Riverpod state must not change during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(serverStatusControllerProvider.notifier).check();
    });
  }

  @override
  void dispose() {
    // Clear first, then dispose: the typed password should not outlive the
    // screen in any object.
    _password.clear();
    _password.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;

    // Only "are both filled?" here. Everything else is the server's job, and
    // the server checks it anyway.
    final usernameMissing = _username.text.trim().isEmpty;
    final passwordMissing = _password.text.isEmpty;
    setState(() {
      _formError = null;
      _usernameError = usernameMissing ? AppText.enterUsername : null;
      _passwordError = passwordMissing ? AppText.enterPassword : null;
    });
    if (usernameMissing || passwordMissing) return;

    setState(() => _sending = true);
    // Sent as typed: the server trims the username itself, and a password is
    // never trimmed (spaces may be part of it).
    final outcome = await ref
        .read(authControllerProvider.notifier)
        .logIn(_username.text, _password.text);

    // The screen may have closed while waiting (after a success the router
    // replaces it). A State that is gone must not call setState.
    if (!mounted) return;
    setState(() {
      _sending = false;
      switch (outcome) {
        case LoginSucceeded():
          // The router is already moving to the home.
          break;
        case LoginFailed(:final failure):
          _formError = failureText(failure);
          _showFieldDetails(failure);
        case LoginNotPossible(:final reason):
          _formError = signOutReasonText(reason);
        case LoginIgnored():
          break;
      }
      // The username stays, so only the password has to be typed again.
      _password.clear();
    });
  }

  /// For VALIDATION_FAILED, the server's message for each field goes under
  /// that field.
  void _showFieldDetails(AppFailure failure) {
    if (failure is! ServerRefused) return;
    for (final detail in failure.details) {
      if (detail.field == 'username') _usernameError = detail.message;
      if (detail.field == 'password') _passwordError = detail.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Why the user was signed out, if it was not their own choice. Shown
    // until they try again, then replaced by that attempt's result.
    final auth = ref.watch(authControllerProvider);
    final reason = auth is SignedOut ? auth.reason : null;
    final message =
        _formError ?? (reason != null ? signOutReasonText(reason) : null);

    return Scaffold(
      body: SafeArea(
        // Center + SingleChildScrollView: centred on a tall screen, and
        // scrollable when it is not (landscape, keyboard open, large text).
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSizes.spaceL),
            child: ConstrainedBox(
              // On a wide screen the form stays a comfortable width.
              constraints: const BoxConstraints(maxWidth: 480),
              // AutofillGroup lets a password manager fill both fields
              // together.
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      AppText.appTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: AppSizes.spaceL),
                    const ServerStatusBanner(),
                    TextField(
                      controller: _username,
                      enabled: !_sending,
                      autofillHints: const [AutofillHints.username],
                      // "Next" on the keyboard moves to the password field.
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: AppText.username,
                        prefixIcon: const Icon(Icons.person),
                        errorText: _usernameError,
                        errorMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: AppSizes.spaceM),
                    TextField(
                      controller: _password,
                      enabled: !_sending,
                      obscureText: _passwordHidden,
                      autofillHints: const [AutofillHints.password],
                      // "Done" on the keyboard logs in.
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: AppText.password,
                        prefixIcon: const Icon(Icons.lock),
                        errorText: _passwordError,
                        errorMaxLines: 3,
                        suffixIcon: IconButton(
                          tooltip: _passwordHidden
                              ? AppText.showPassword
                              : AppText.hidePassword,
                          icon: Icon(
                            _passwordHidden
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () => setState(
                            () => _passwordHidden = !_passwordHidden,
                          ),
                        ),
                      ),
                    ),
                    if (message != null) ...[
                      const SizedBox(height: AppSizes.spaceM),
                      FormMessage(message),
                    ],
                    const SizedBox(height: AppSizes.spaceL),
                    FilledButton(
                      // null disables the button while a login is running,
                      // so it cannot be sent twice.
                      onPressed: _sending ? null : _submit,
                      child: _sending
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: AppSizes.spaceM),
                                Flexible(child: Text(AppText.loggingIn)),
                              ],
                            )
                          : const Text(AppText.logIn),
                    ),
                    const SizedBox(height: AppSizes.spaceM),
                    // The two ways in for someone who cannot log in yet.
                    // push (not go) keeps this screen underneath, so the
                    // back arrow and Android's back button return here.
                    // Disabled while a login runs, so the screen does not
                    // change under it.
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSizes.tapTargetMin),
                      ),
                      onPressed: _sending
                          ? null
                          : () => context.push(AppRoutes.register),
                      child: const Text(
                        AppText.requestAccountLink,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSizes.tapTargetMin),
                      ),
                      onPressed: _sending
                          ? null
                          : () => context.push(AppRoutes.activate),
                      child: const Text(
                        AppText.haveActivationCodeLink,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
