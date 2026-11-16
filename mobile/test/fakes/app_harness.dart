// TEST ONLY: the whole app (real router, real screens) with a stand-in auth
// controller and server status, at a chosen screen size and text scale. No
// network, no secure storage.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/main.dart';

import 'fake_controllers.dart';

class AppHarness {
  AppHarness._(this.container, this.auth);

  final ProviderContainer container;
  final FakeAuthController auth;

  /// The top-most screen's path. `router.state` reads the last match, so it
  /// sees a pushed screen (currentConfiguration.uri would not).
  String get path => container.read(appRouterProvider).state.uri.path;

  /// Starts the app with [auth] in place and lets it settle on its first
  /// screen.
  static Future<AppHarness> pump(
    WidgetTester tester,
    FakeAuthController auth, {
    Size size = const Size(360, 640),
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = size * 3.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // A fake, reserved address: never the real one.
    final config = (AppConfig.check('https://api.example.test') as ConfigOk)
        .config;
    final container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        appConfigProvider.overrideWithValue(config),
        ...fakeOverrides(auth),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MineChainApp(),
      ),
    );
    await tester.pumpAndSettle();
    return AppHarness._(container, auth);
  }
}

/// Scrolls [finder] into view, then taps it: on a small screen or at large
/// text, much of a form is below the fold.
///
/// It settles FIRST. A text field that was just typed into has asked, for
/// the next frame, to scroll its caret back into view (EditableText's
/// _scheduleShowCaretOnScreen). ensureVisible itself only jumps the scroll
/// position and draws no frame, so without this the caret's scroll would run
/// during the settle below and undo the jump, leaving [finder] off screen
/// when tapped. typeInto settles for the same reason; this covers a test that
/// calls enterText directly.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Scrolls the text field [finder] into view and types [text] into it.
///
/// Settles at the end: typing makes the field scroll its caret into view on
/// the next frame (see tapVisible). Letting that finish here means it cannot
/// move the page under whatever the test does next.
Future<void> typeInto(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}
