// A big tile with an icon and a short word or two under it: the building block
// of every home screen.
//
// Why icon AND label: an icon alone is a guess for someone who has not seen it
// before, and a word alone is harder for users with limited reading. Together
// each helps the other (plan section 7).

import 'package:flutter/material.dart';

import '../theme/sizes.dart';

/// A large tappable tile: icon on top, label underneath.
///
/// Set [primary] for the role's main action. It is taller, has a bigger icon
/// and text, and uses the strongest colour, so it is the first thing seen.
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;

  /// What happens on a tap. The tile only reports the tap; deciding what it
  /// means (open a screen, show a message) belongs to whoever builds the tile.
  final VoidCallback onTap;

  final bool primary;

  @override
  Widget build(BuildContext context) {
    // Theme.of(context) finds the nearest theme above this widget (the one
    // MaterialApp provides), so the tile follows light and dark mode by itself.
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Each background colour is paired with the colour Material designed to be
    // read on top of it ("on..."), which is what keeps the contrast right.
    final background = primary ? scheme.primary : scheme.secondaryContainer;
    final foreground = primary ? scheme.onPrimary : scheme.onSecondaryContainer;

    final labelStyle = (primary ? textTheme.titleLarge : textTheme.titleMedium)
        ?.copyWith(color: foreground, fontWeight: FontWeight.w600);

    // Semantics is what a screen reader (TalkBack) announces. We describe the
    // whole tile as one button with the label as its name, and hide the parts
    // inside (excludeSemantics) so TalkBack does not read the icon and the text
    // as separate things. Because the parts are hidden, the tap action is given
    // here too, so TalkBack users can still activate the tile.
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      // Material gives the tile its colour and rounded shape, and is the
      // surface the InkWell's ripple is drawn on.
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        ),
        // Keeps the ripple inside the rounded corners.
        clipBehavior: Clip.antiAlias,
        // InkWell makes its child tappable and shows Material's ripple, so the
        // user sees that the tap was felt.
        child: InkWell(
          onTap: onTap,
          // ConstrainedBox sets a minimum size; the tile may grow beyond it
          // (large text), but never shrinks below it.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: AppSizes.tileMin,
              minHeight: primary ? AppSizes.primaryTileMin : AppSizes.tileMin,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSizes.spaceM),
              // Column stacks its children top to bottom. mainAxisSize.min
              // makes it only as tall as its content, and center places that
              // content in the middle when the tile is taller.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: primary
                        ? AppSizes.primaryTileIcon
                        : AppSizes.tileIcon,
                    color: foreground,
                  ),
                  const SizedBox(height: AppSizes.spaceS),
                  // No maxLines and no overflow cut-off: with large text the
                  // label wraps onto more lines and the tile grows taller. The
                  // phone's text size is never clamped (plan section 7).
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: labelStyle,
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
