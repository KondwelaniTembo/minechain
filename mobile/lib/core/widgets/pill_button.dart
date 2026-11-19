// The button used on a copper notice ("Enter password", "Try again"). It looks
// like the role pill in the top bar: the light copper container with dark text.
//
// Why not a normal button: a notice is drawn in the main copper (decision
// Mobile (36)), so a filled copper button would vanish into it and a text
// button would be thin copper-on-copper. The pill is the one colour pair that
// stands out on the notice (4.98:1 in light, 5.36:1 in dark, tested in
// app_theme_test.dart).

import 'package:flutter/material.dart';

import '../theme/sizes.dart';

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      // Full height, any width: the label may grow with the phone's text size.
      minimumSize: const Size(0, AppSizes.tapTargetMin),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
      ),
    );

    final icon = this.icon;
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: Text(label))
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon),
            label: Text(label),
          );
  }
}
