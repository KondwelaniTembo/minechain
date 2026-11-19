// A big tile with an icon and a short word or two under it: the building block
// of every home screen.
//
// Why icon AND label: an icon alone is a guess for someone who has not seen it
// before, and a word alone is harder for users with limited reading. Together
// each helps the other (plan section 7).

import 'package:flutter/material.dart';

import '../text/text_width.dart';
import '../theme/app_theme.dart';
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
    this.labelRoom,
  });

  /// How high the tiles sit above the page (Mobile (36), T9): the main tile
  /// higher than the others, the same in light and dark.
  static const double elevation = 5;
  static const double primaryElevation = 8;

  /// The space between the tile's edge and its icon and label.
  static const double padding = AppSizes.spaceM;

  /// The width a label has inside a tile [tileWidth] wide.
  static double labelRoomFor(double tileWidth) => tileWidth - 2 * padding;

  /// The label's text style before any shrinking: larger on the main tile.
  static TextStyle? labelStyleFor(
    BuildContext context, {
    required bool primary,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final foreground = primary ? scheme.onPrimary : scheme.onSecondaryContainer;
    return (primary ? textTheme.titleLarge : textTheme.titleMedium)?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
    );
  }

  /// How wide the widest single word of [label] is drawn at the phone's text
  /// size. A line can only break between words, so this is the narrowest the
  /// label can be laid out without a word broken in the middle.
  static double widestWord(
    BuildContext context,
    String label, {
    required bool primary,
    TextStyle? style,
    TextScaler? textScaler,
  }) {
    final wordStyle = style ?? labelStyleFor(context, primary: primary);
    var widest = 0.0;
    for (final word in label.split(' ')) {
      if (word.isEmpty) continue;
      final width = drawnTextWidth(
        context,
        word,
        wordStyle,
        textScaler: textScaler,
      );
      if (width > widest) widest = width;
    }
    return widest;
  }

  final IconData icon;
  final String label;

  /// What happens on a tap. The tile only reports the tap; deciding what it
  /// means (open a screen, show a message) belongs to whoever builds the tile.
  final VoidCallback onTap;

  final bool primary;

  /// The width the label is laid out in, when the caller knows it (the home
  /// layout does). A word wider than this would be broken in the middle
  /// ("consig / nments"), so the label is drawn smaller instead, just enough
  /// for that word to fit. Without it the label is never shrunk.
  final double? labelRoom;

  @override
  Widget build(BuildContext context) {
    // Theme.of(context) finds the nearest theme above this widget (the one
    // MaterialApp provides), so the tile follows light and dark mode by itself.
    final scheme = Theme.of(context).colorScheme;

    // Each background colour is paired with the colour Material designed to be
    // read on top of it ("on..."), which is what keeps the contrast right.
    final background = primary ? scheme.primary : scheme.secondaryContainer;
    final foreground = primary ? scheme.onPrimary : scheme.onSecondaryContainer;

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
        // The soft shadow is what lifts a tile off the page: in light mode a
        // sand tile and the page are only about 1.2:1 apart in colour. The
        // main tile sits higher than the others, so it is the first thing seen.
        elevation: primary ? primaryElevation : elevation,
        shadowColor: AppTheme.shadow,
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
              padding: const EdgeInsets.all(padding),
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
                    // Copper icon on the sand tiles: the icon is the first
                    // thing the eye finds, and the label stays dark for
                    // reading. The main tile keeps one colour for both.
                    color: primary ? foreground : scheme.primary,
                  ),
                  const SizedBox(height: AppSizes.spaceS),
                  // No maxLines and no overflow cut-off: with large text the
                  // label wraps onto more lines and the tile grows taller. The
                  // phone's text size is only reduced for a word that could
                  // not fit at all (see [labelRoom]).
                  _TileLabel(label: label, primary: primary, room: labelRoom),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tile's label, shrunk only as far as its widest word needs.
///
/// Its own widget so the measuring happens below the tile's Material, with the
/// same default text style the Text is drawn in.
///
/// Why not a FittedBox: a FittedBox lays the whole label out on one line and
/// shrinks that, so "Register consignment" would become tiny. Here the label
/// still wraps between words, at the largest size where every word fits.
class _TileLabel extends StatelessWidget {
  const _TileLabel({
    required this.label,
    required this.primary,
    required this.room,
  });

  final String label;
  final bool primary;
  final double? room;

  @override
  Widget build(BuildContext context) {
    final style = ActionTile.labelStyleFor(context, primary: primary);
    final room = this.room;

    Widget text(TextStyle? style, {TextScaler? textScaler}) => Text(
      label,
      textAlign: TextAlign.center,
      style: style,
      textScaler: textScaler,
    );

    if (room == null || room <= 0) return text(style);
    final widest = ActionTile.widestWord(context, label, primary: primary);
    if (widest <= room) return text(style);

    // The size the phone's setting would give, then reduced by how much too
    // wide the word is. The size is set directly and the phone's scaling is
    // switched off for this label, so it is not applied twice.
    final baseSize =
        style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    var fontSize =
        MediaQuery.textScalerOf(context).scale(baseSize) * room / widest;

    // Letter spacing does not shrink with the font size, so the first guess
    // can still be a hair too wide. Measure again and step down until it fits.
    double widestAt(double size) => ActionTile.widestWord(
      context,
      label,
      primary: primary,
      style: style?.copyWith(fontSize: size),
      textScaler: TextScaler.noScaling,
    );
    for (var i = 0; i < 20 && widestAt(fontSize) > room; i++) {
      fontSize *= 0.98;
    }

    return text(
      style?.copyWith(fontSize: fontSize),
      textScaler: TextScaler.noScaling,
    );
  }
}
