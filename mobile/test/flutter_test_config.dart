// Settings for every test under test/. `flutter test` finds this file by its
// name and runs testExecutable around each test file's main().

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A tap (or drag) aimed at a widget that would not receive it, because it
  // is off screen or covered, normally only prints a warning and the test
  // carries on as if nothing was pressed. That once hid a Send button pushed
  // off screen by a text field's caret scroll. Fatal makes such a test fail
  // at the tap itself, with the reason, instead of later at an unrelated
  // expect, or worse, passing because "nothing happened" was expected.
  //
  // A test that really means to tap something it may miss must say so with
  // warnIfMissed: false. None does today.
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}
