// Sizes used across the app, in one place, so every screen feels the same and
// a change (bigger tiles, more space) is made once.
//
// All values are in logical pixels ("dp" on Android): the same physical size on
// every phone, whatever its screen density. 1 dp is about 1/160 of an inch.

/// Shared sizes. `abstract final` means it holds constants only: nobody can
/// create one or extend it.
abstract final class AppSizes {
  // ---- Touch targets ----

  /// The smallest thing a finger can tap. Material's own minimum is 48 dp; we
  /// use more, because users may wear gloves, have dusty fingers, or be new to
  /// smartphones (plan section 7).
  static const double tapTargetMin = 56;

  /// The smallest home-screen tile, in both width and height.
  static const double tileMin = 96;

  /// The smallest height of a role's main tile, which is larger so the most
  /// important action is the easiest to find and hit.
  static const double primaryTileMin = 128;

  // ---- Icons ----

  static const double tileIcon = 40;
  static const double primaryTileIcon = 56;

  /// The icon in a status banner or notice: smaller than a tile's, so the
  /// sentence beside it is what is read first.
  static const double statusIcon = 28;
  static const double appBarIcon = 32;

  /// The MineChain logo below a home's tiles. The login and splash screens
  /// use [logoLarge].
  static const double logo = 72;
  static const double logoLarge = 96;

  // ---- Spacing ----
  // One small scale, so gaps line up across screens instead of being chosen
  // one by one.

  static const double spaceXs = 4;
  static const double spaceS = 8;
  static const double spaceM = 16;
  static const double spaceL = 24;
  static const double spaceXl = 32;

  /// How round the tile corners are.
  static const double tileRadius = 16;

  // ---- Width breakpoints for the home grid ----
  // These follow Material 3's window size classes: "compact" below 600 dp,
  // "medium" from 600 dp, "expanded" from 840 dp. We choose by the available
  // width, not by portrait or landscape, because width is what decides whether
  // tiles fit side by side. For example:
  //   360 dp wide (a small phone, portrait)  -> 2 columns
  //   640 dp wide (a small phone, landscape) -> 3 columns
  //   900 dp wide (a large phone, landscape) -> 4 columns

  static const double mediumWidth = 600;
  static const double expandedWidth = 840;

  /// How many tile columns fit in [width] dp.
  static int columnsForWidth(double width) {
    if (width >= expandedWidth) return 4;
    if (width >= mediumWidth) return 3;
    return 2;
  }
}
