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
    this.username,
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

  /// The signed-in user's username, shown in the role pill. Optional so this
  /// shared layout does not depend on the auth feature; the homes pass it.
  final String? username;

  @override
  Widget build(BuildContext context) {
    // The primary action always goes first, whatever order it was listed in.
    final primary = actions.where((a) => a.primary).toList();
    final others = actions.where((a) => !a.primary).toList();

    // Scaffold is the frame of one screen, with named slots: appBar at the top,
    // body for the rest.
    return Scaffold(
      appBar: AppBar(
        // The app's name first, then the role and username as a small label,
        // so the user always sees which account type and whose account this is.
        title: _AppBarTitle(role: title, username: username),
        // `actions` here are AppBar's buttons on the right (not our tiles).
        actions: [
          // filledTonal draws a round, filled button: the account button
          // reads as a button, not as a stray icon in the corner.
          IconButton.filledTonal(
            icon: const Icon(Icons.person),
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

/// "MineChain" in bold, then a small rounded pill with the role and the
/// username: "Miner · mutale_banda".
///
/// One line, not two stacked: an app bar has a fixed height, and two lines
/// would overflow it at the largest text size.
///
/// What gives way first when space is short (a 5-inch phone with the largest
/// text), from most to least important:
/// 1. the role is never cut to "Admini…": it tells the user which kind of
///    account they are in;
/// 2. the username shrinks and ends in "…", and is left out when fewer than
///    [_minUsernameChars] characters would show (never "m…");
/// 3. "MineChain" is shown only if it fits whole beside the full pill, never
///    as "Mine…";
/// 4. if even the role alone is too wide, it is scaled down to fit rather than
///    cut. The phone's text size is never clamped anywhere else.
class _AppBarTitle extends StatelessWidget {
  const _AppBarTitle({required this.role, this.username});

  final String role;
  final String? username;

  static const _minUsernameChars = 3;

  static const _pillPadding = EdgeInsets.symmetric(
    horizontal: AppSizes.spaceS + AppSizes.spaceXs,
    vertical: AppSizes.spaceXs,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final nameStyle = text.titleLarge?.copyWith(
      fontWeight: FontWeight.w800,
      color: scheme.primary,
    );
    final roleStyle = text.labelLarge?.copyWith(
      color: scheme.onPrimaryContainer,
      fontWeight: FontWeight.w600,
    );
    // Lighter than the role, so the role is read first.
    final userStyle = roleStyle?.copyWith(fontWeight: FontWeight.w400);

    // The pill is a different colour pair from the buttons on purpose: it is
    // information about the account, not something to tap.
    Widget pill(List<Widget> children) => DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
      ),
      child: Padding(
        padding: _pillPadding,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );

    final roleText = Text(role, style: roleStyle, maxLines: 1, softWrap: false);

    // LayoutBuilder gives the width the app bar has left for its title (after
    // the account button), so the choices below follow the real space: the
    // screen width, the orientation and the phone's text size.
    final title = LayoutBuilder(
      builder: (context, constraints) {
        double width(String value, TextStyle? style) =>
            _textWidth(context, value, style);

        final user = username;
        final roleOnly = width(role, roleStyle) + _pillPadding.horizontal;
        final withUser = user == null
            ? roleOnly
            : roleOnly +
                  width(AppText.pillSeparator, userStyle) +
                  width(user, userStyle);
        final nameWidth = width(AppText.appTitle, nameStyle);
        final showName =
            nameWidth + AppSizes.spaceS + withUser <= constraints.maxWidth;
        final room =
            constraints.maxWidth - (showName ? nameWidth + AppSizes.spaceS : 0);

        // The narrowest pill that still shows some of the username: the role,
        // the separator and the first few characters with "…".
        final showUser =
            user != null &&
            (user.length <= _minUsernameChars
                ? withUser <= room
                : roleOnly +
                          width(AppText.pillSeparator, userStyle) +
                          width(
                            '${user.substring(0, _minUsernameChars)}…',
                            userStyle,
                          ) <=
                      room);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showName) ...[
              Text(
                AppText.appTitle,
                style: nameStyle,
                maxLines: 1,
                softWrap: false,
              ),
              const SizedBox(width: AppSizes.spaceS),
            ],
            if (showUser)
              // Flexible hands the pill the width that is left; inside it,
              // only the username is Flexible, so it is the part that ends
              // in "…" while the role keeps its full width.
              Flexible(
                child: pill([
                  roleText,
                  Text(AppText.pillSeparator, style: userStyle),
                  Flexible(
                    child: Text(
                      user,
                      style: userStyle,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              )
            else
              // FittedBox lets the pill take its full natural width, then
              // shrinks the drawing only if that width is more than there
              // is. scaleDown never makes it bigger. Unlike "…", the role
              // stays whole and readable.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: pill([roleText]),
                ),
              ),
          ],
        );
      },
    );

    // TalkBack reads the pill as one sentence, with the whole username even
    // when the screen shows it shortened or not at all.
    final user = username;
    if (user == null) return title;
    return Semantics(
      container: true,
      label: AppText.signedInAs(role, user),
      excludeSemantics: true,
      child: title,
    );
  }

  /// How wide [value] is drawn in [style] here, the same way a Text widget
  /// would draw it.
  ///
  /// Text merges its style with the surrounding default style (the app bar
  /// sets one) and applies the phone's text size and "bold text" settings, so
  /// the measurement does the same; otherwise it could say "fits" for a word
  /// that is then drawn wider.
  static double _textWidth(
    BuildContext context,
    String value,
    TextStyle? style,
  ) {
    var effective = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: value, style: effective),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    // A TextPainter holds native resources until disposed.
    painter.dispose();
    return width;
  }
}

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
