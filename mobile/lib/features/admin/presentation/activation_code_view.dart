// The activation code, shown once (admin accounts plan §4.4, T5): after
// "Create account" and after "New activation code".
//
// Q3: large and plain, with no copy button. api.md says to hand the code
// over in person or by phone, and on Android the clipboard can be read by
// other apps; release builds already block screenshots (FLAG_SECURE,
// Hardening). The code is never logged or stored: it lives only in the
// page's state and is gone when the page closes.
//
// Leaving by Android back or the back arrow asks first, because the code can
// never be shown again; "Done" does not ask.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../domain/admin_account.dart';

class ActivationCodeView extends StatelessWidget {
  const ActivationCodeView({
    required this.account,
    required this.code,
    required this.onDone,
    super.key,
  });

  final AdminAccount account;
  final ActivationCode code;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExcludeSemantics(child: Icon(Icons.vpn_key, size: 48)),
        const SizedBox(height: AppSizes.spaceM),
        Text(
          AppText.activationCodeFor(account.username),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: AppSizes.spaceM),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSizes.spaceL),
            // Plain Text, not SelectableText: no copy (Q3). One line, made
            // smaller only when it would not fit (T6b): on the emulator it
            // broke after the first dash ("3NMG-" / "QR7W-6HE7"), which
            // reads like two codes when said over the phone.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                code.code,
                key: const ValueKey('activation-code'),
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        Text(
          AppText.codeValidFor(code.expiresAt.toLocal()),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSizes.spaceM),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExcludeSemantics(child: Icon(Icons.info_outline)),
            const SizedBox(width: AppSizes.spaceS),
            Expanded(child: Text(AppText.codeShownOnce(account.fullName))),
          ],
        ),
        const SizedBox(height: AppSizes.spaceL),
        FilledButton(onPressed: onDone, child: const Text(AppText.codeDone)),
      ],
    );
  }
}

/// "Leave without the code?" True to leave.
Future<bool> confirmLeaveCode(BuildContext context) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(AppText.leaveWithoutCodeQuestion),
      content: const Text(AppText.leaveWithoutCodeExplanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(AppText.leaveCode),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(AppText.stayOnCode),
        ),
      ],
    ),
  );
  return leave == true;
}
