// The shared layout of the five role home screens: a top bar with the title and
// an account button, then a grid of big tiles with the role's main action first.
//
// Why shared: every role's home looks and behaves the same way, so a user who
// learns one has learned them all, and a layout fix is made once.

import 'package:flutter/material.dart';

import '../text/app_text.dart';
import '../theme/sizes.dart';
import 'action_tile.dart';

/// One tile on a home screen, described as data. The home screen lists its
/// actions; HomeScaffold decides how to lay them out.
class HomeAction {
  const HomeAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// The role's main action. At most one per home.
  final bool primary;
}

/// The layout every role's home uses.
class HomeScaffold extends StatelessWidget {
  HomeScaffold({
    super.key,
    required this.title,
    required this.actions,
    required this.onAccountPressed,
    this.header,
  }) : assert(
         actions.where((a) => a.primary).length <= 1,
         'A home screen has at most one primary action.',
       );

  final String title;
  final List<HomeAction> actions;
  final VoidCallback onAccountPressed;

  /// Optional content above the tiles, such as the server status banner. It
  /// scrolls with the tiles, so it never pushes them off a small screen.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    // The primary action always goes first, whatever order it was listed in.
    final primary = actions.where((a) => a.primary).toList();
    final others = actions.where((a) => !a.primary).toList();

    // Scaffold is the frame of one screen, with named slots: appBar at the top,
    // body for the rest.
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        // `actions` here are AppBar's buttons on the right (not our tiles).
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle),
            iconSize: AppSizes.appBarIcon,
            // The tooltip shows on a long press, and is also what TalkBack
            // reads, so an icon-only button still has a name.
            tooltip: AppText.myAccount,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(AppSizes.tapTargetMin),
            ),
            onPressed: onAccountPressed,
          ),
          const SizedBox(width: AppSizes.spaceS),
        ],
      ),
      // SafeArea keeps content out of the phone's notch, rounded corners and
      // system bars, which matters most in landscape.
      body: SafeArea(
        // LayoutBuilder tells us how much space we really have, so we can pick
        // the number of columns from the width (sizes.dart explains the
        // breakpoints). It rebuilds when the phone is rotated.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = AppSizes.columnsForWidth(constraints.maxWidth);

            final children = <Widget>[
              for (final action in primary) _tileFor(action),
              for (final row in _rowsOf(others, columns))
                _TileRow(actions: row, columns: columns),
            ];

            // SingleChildScrollView lets the content scroll when it is taller
            // than the screen: in landscape, or with large text. Nothing is
            // ever cut off.
            //
            // Why not GridView: GridView gives every cell the same fixed shape,
            // so a label that wraps onto three lines at large text would not
            // fit and would overflow. Rows that grow with their content cannot.
            return SingleChildScrollView(
              padding: const EdgeInsets.all(AppSizes.spaceM),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                // The header is outside the gaps: it may be empty (a banner
                // with nothing to say), and an empty header must not leave a
                // gap. A header that shows something adds its own spacing.
                // `?header` adds it only if it is not null.
                children: [?header, ..._withGaps(children)],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Splits [items] into rows of [columns]: 5 items in 2 columns become rows of
  /// 2, 2 and 1.
  static List<List<HomeAction>> _rowsOf(List<HomeAction> items, int columns) {
    return [
      for (var start = 0; start < items.length; start += columns)
        items.sublist(start, (start + columns).clamp(0, items.length)),
    ];
  }

  /// Puts the same vertical gap between children, but not after the last one.
  static List<Widget> _withGaps(List<Widget> children) {
    return [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: AppSizes.spaceM),
        children[i],
      ],
    ];
  }
}

Widget _tileFor(HomeAction action) => ActionTile(
  icon: action.icon,
  label: action.label,
  onTap: action.onTap,
  primary: action.primary,
);

/// One row of equal-width tiles, all as tall as the tallest one.
class _TileRow extends StatelessWidget {
  const _TileRow({required this.actions, required this.columns});

  final List<HomeAction> actions;
  final int columns;

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight measures the tallest tile first, then gives every tile
    // in the row that height (with crossAxisAlignment.stretch), so a row with
    // one long label still looks even. It costs an extra measuring pass, which
    // is fine for a handful of tiles.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < columns; i++) ...[
            if (i > 0) const SizedBox(width: AppSizes.spaceM),
            // Expanded shares the row's width equally. A last row with fewer
            // tiles keeps empty slots, so its tiles stay the same width as the
            // ones above instead of stretching across.
            Expanded(
              child: i < actions.length
                  ? _tileFor(actions[i])
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }
}
