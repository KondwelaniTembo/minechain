// TEST ONLY: Android's back button, sent the way the system sends it.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Presses Android's back button: the "popRoute" message on the navigation
/// channel, which the app answers by popping a page, or by leaving the app
/// when there is nothing left to pop. Then settles.
Future<void> pressAndroidBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// Counts the times the app asks Android to close it (SystemNavigator.pop),
/// which happens when back is pressed with nothing left to pop. The test
/// ends the watch by itself.
class AppExitWatch {
  AppExitWatch(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  int exits = 0;
}
