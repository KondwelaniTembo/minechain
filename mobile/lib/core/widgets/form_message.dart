// A problem sentence under a form: "Wrong username or password.", "No internet
// connection. ..." Used by the login screen and the password prompt, so both
// look and sound the same.

import 'package:flutter/material.dart';

import '../theme/sizes.dart';

/// An icon and words, never colour alone (plan section 7).
class FormMessage extends StatelessWidget {
  const FormMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // liveRegion: TalkBack reads it out when it appears, so a blind user
    // hears why the attempt failed without hunting for it.
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: AppSizes.spaceS),
          // Expanded lets a long sentence wrap instead of running off the
          // edge, which matters at large text sizes.
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
  }
}
