// Gives the checked settings to the rest of the app through Riverpod.
//
// Why a provider and not a global: code that needs the API address asks for
// `appConfigProvider`, and a test can hand it a different AppConfig with an
// override. Nothing outside main.dart ever reads String.fromEnvironment.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_config.dart';

/// The app's checked settings.
///
/// It has no value of its own: main.dart checks the build-time address and
/// supplies the result with `appConfigProvider.overrideWithValue(config)` on
/// the root ProviderScope. If someone forgets that, the error below says so
/// at once instead of the app running with no address.
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw StateError(
    'appConfigProvider was not given a value. main.dart (or the test) must '
    'override it with appConfigProvider.overrideWithValue(...).',
  ),
);
