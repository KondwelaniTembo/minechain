// A password text field with a show/hide button, for the forms that set a
// new password (register, activate). It owns only its "hidden" switch; the
// typed text stays in the controller the form gives it, so the form can clear
// it after every attempt.

import 'package:flutter/material.dart';

import '../text/app_text.dart';

class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.errorText,
    this.helperText,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.autofillHints = const [AutofillHints.newPassword],
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;

  /// Shown in red under the field (several lines allowed), or null.
  final String? errorText;

  /// A hint under the field while there is no error, for example the
  /// password policy.
  final String? helperText;

  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String> autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _hidden,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      // No autocorrect or suggestions: the keyboard must not learn or offer
      // the password.
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.lock),
        errorText: widget.errorText,
        // Room for several server messages joined together.
        errorMaxLines: 6,
        helperText: widget.helperText,
        // Without this the hint is cut to one line, and the policy is longer.
        helperMaxLines: 4,
        suffixIcon: IconButton(
          tooltip: _hidden ? AppText.showPassword : AppText.hidePassword,
          icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
      ),
    );
  }
}
