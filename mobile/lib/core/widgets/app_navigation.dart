// The frame around the signed-in user's two places, Home and Account, with the
// navigation bar that moves between them (decision Mobile (37), from Mapalo
// Maseko's suggestion in docs/plans/bottom-navigation-suggestion.md).
//
// Why a frame (go_router's "shell"): the bar belongs to both places, so it is
// drawn once around them instead of by each screen. Task pages ("Register
// consignment", "Send my work", ...) are outside the frame, so they cover the
// whole screen and have no bar (Q11).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../text/app_text.dart';
import '../text/text_width.dart';
import '../theme/sizes.dart';

/// The frame: the current place, with the bar under it (portrait) or a rail
/// beside it (a phone on its side).
class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({super.key, required this.shell});

  /// go_router's handle on the two places ("branches"). It knows which one is
  /// shown, and keeps each one's own page stack, so the home keeps its scroll
  /// position while Account is open.
  final StatefulNavigationShell shell;

  /// The branches, in the order app_router.dart lists them.
  static const int homeBranch = 0;
  static const int accountBranch = 1;

  static const List<String> _words = [AppText.navHome, AppText.navAccount];

  /// Material 3's bar height at its own text size. The bar grows from here.
  static const double _barHeight = 80;

  /// The space kept free on each side of a word, so two words never touch.
  static const double _wordMargin = AppSizes.spaceS;

  /// The widest a rail may become for its words; past this a word shrinks
  /// rather than squeeze the page beside it.
  static const double _railMaxWord = 144;

  void _go(int index) =>
      // A tap on the place you are already in goes back to its start (the
      // home itself), as Android users expect from a bar.
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final onSide = MediaQuery.sizeOf(context).height < AppSizes.compactHeight;

    // Android's back button: on Account it goes to Home, on Home it leaves
    // the app as usual. PopScope stops the pop on Account and does the move
    // instead. A task page on top is not affected: it is popped first.
    return PopScope(
      canPop: shell.currentIndex == homeBranch,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(homeBranch);
      },
      child: onSide ? _withRail(context) : _withBar(context),
    );
  }

  /// Flutter's NavigationBar draws its words at most 1.3 times their size,
  /// whatever the phone's text setting, so the bar's words stay smaller than
  /// the page's (Material's choice, `_kMaxLabelTextScaleFactor` in
  /// navigation_bar.dart). The rail has no such limit. The measurements
  /// below follow what Flutter really draws.
  static const double barWordMaxScale = 1.3;

  Widget _withBar(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final fit = _WordsFit.of(
      context,
      room: width / _words.length,
      maxScale: barWordMaxScale,
    );

    return Scaffold(
      body: shell,
      bottomNavigationBar: fit.apply(
        context,
        NavigationBar(
          // Taller when the words are: the bar has a fixed height, so at a
          // large text size the words would otherwise be cut at the bottom.
          height: _barHeight + fit.extraHeight,
          selectedIndex: shell.currentIndex,
          onDestinationSelected: _go,
          destinations: const [
            // Outlined when not chosen, filled when chosen: the shape shows
            // where you are as well as the colour (Mobile (37), T10).
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: AppText.navHome,
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: AppText.navAccount,
            ),
          ],
        ),
      ),
    );
  }

  Widget _withRail(BuildContext context) {
    final fit = _WordsFit.of(context, room: _railMaxWord + 2 * _wordMargin);
    // Wide enough for the widest word, and never narrower than Material's
    // rail, so a short word does not make a thin strip.
    final railWidth = math.max(80.0, fit.widest + 2 * _wordMargin);

    return Scaffold(
      body: Row(
        children: [
          // The rail keeps out of a notch or rounded corner on the left; the
          // page on the right has its own SafeArea.
          SafeArea(
            right: false,
            child: fit.apply(
              context,
              NavigationRail(
                minWidth: railWidth,
                selectedIndex: shell.currentIndex,
                onDestinationSelected: _go,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: Text(AppText.navHome),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: Text(AppText.navAccount),
                  ),
                ],
              ),
            ),
          ),
          // A thin line between the rail and the page: the rail is the
          // screen's colour, like the page.
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: shell),
        ],
      ),
    );
  }
}

/// How the bar's words fit at the phone's text size.
///
/// The same rule as the home tiles (Mobile (36), Q6): a word is never broken
/// in the middle. If the widest word does not fit its space at the phone's
/// text size, the bar's words (only those) are drawn just small enough.
class _WordsFit {
  const _WordsFit({
    required this.widest,
    required this.extraHeight,
    this.scaler,
  });

  /// The widest word as it will be drawn.
  final double widest;

  /// How much taller a line of the words is than at Material's own size.
  final double extraHeight;

  /// The text size for the bar's words when the phone's would not fit, or
  /// null to keep the phone's.
  final TextScaler? scaler;

  /// Measures the words for a place [room] dp wide (half the bar, or the
  /// rail's widest). [maxScale] is a limit the widget itself puts on its
  /// words' text size, if any.
  static _WordsFit of(
    BuildContext context, {
    required double room,
    double? maxScale,
  }) {
    // The chosen word is bold, so it is the widest a word can be.
    final style = Theme.of(context).navigationBarTheme.labelTextStyle
        ?.resolve({WidgetState.selected});
    final ambient = MediaQuery.textScalerOf(context);
    final phone = maxScale == null
        ? ambient
        : ambient.clamp(maxScaleFactor: maxScale);
    final space = room - 2 * AppNavigationShell._wordMargin;

    double widestAt(TextScaler scaler) => AppNavigationShell._words
        .map((w) => drawnTextWidth(context, w, style, textScaler: scaler))
        .reduce(math.max);

    var scaler = phone;
    var widest = widestAt(phone);
    TextScaler? shrunk;
    if (widest > space) {
      final size = style?.fontSize ?? 14;
      // The phone's scale at this size, reduced by how much too wide the
      // word is. Step down a little more if letter spacing still leaves it
      // a hair too wide.
      var factor = phone.scale(size) / size * space / widest;
      for (var i = 0; i < 20; i++) {
        scaler = TextScaler.linear(factor);
        widest = widestAt(scaler);
        if (widest <= space) break;
        factor *= 0.98;
      }
      shrunk = scaler;
    }

    final word = AppNavigationShell._words.first;
    final lineNow = drawnTextSize(
      context,
      word,
      style,
      textScaler: scaler,
    ).height;
    final lineBase = drawnTextSize(
      context,
      word,
      style,
      textScaler: TextScaler.noScaling,
    ).height;

    return _WordsFit(
      widest: widest,
      extraHeight: math.max(0, lineNow - lineBase),
      scaler: shrunk,
    );
  }

  /// [child] with the shrunk text size, if one was needed. Only the bar is
  /// inside it, never the page.
  Widget apply(BuildContext context, Widget child) {
    final shrunk = scaler;
    if (shrunk == null) return child;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: shrunk),
      child: child,
    );
  }
}
