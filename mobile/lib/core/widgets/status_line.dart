// An icon and a sentence, never colour alone (plan section 7): "Location
// found, 6 m", "Under review". Shared by the screens that sign a custody
// step (since Transporter handoff T4), so each says its states the same way.

import 'package:flutter/material.dart';

import '../theme/sizes.dart';

class StatusLine extends StatelessWidget {
  const StatusLine({
    required this.icon,
    required this.text,
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? Theme.of(context).colorScheme.error : null;
    // A live region: TalkBack reads a change out when it appears.
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: color)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
