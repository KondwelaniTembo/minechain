// A form's main button that is disabled, with a small spinner and "Sending…",
// while its request runs, so it cannot be sent twice.

import 'package:flutter/material.dart';

import '../text/app_text.dart';
import '../theme/sizes.dart';

class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.busyLabel = AppText.sending,
  });

  final String label;
  final String busyLabel;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      // A null onPressed is how Flutter disables a button.
      onPressed: busy ? null : onPressed,
      child: busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSizes.spaceM),
                // Flexible: at large text the words wrap instead of pushing
                // the row past the button's edge.
                Flexible(child: Text(busyLabel)),
              ],
            )
          : Text(label),
    );
  }
}
