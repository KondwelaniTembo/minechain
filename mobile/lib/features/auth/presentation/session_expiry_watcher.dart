// Checks whether the token has run out each time the app comes back to the
// screen (plan section 6.2, decision Q2).
//
// The "app lifecycle" is Android telling the app what is happening to it:
//
//   resumed   on screen and in use
//   inactive  still visible but not receiving touches (a call coming in,
//             the notification shade pulled down)
//   hidden    no longer visible
//   paused    in the background (the user pressed Home or switched apps)
//   detached  the Flutter engine is shutting down
//
// While paused, the app's Dart code mostly does not run: no timer fires, so a
// token can run out unnoticed. Coming back is the moment to look at the clock.
//
// Nothing here is logged.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Wraps the whole app (see MineChainApp in main.dart) and calls
/// AuthController.checkExpiry() whenever the app returns to the foreground.
///
/// It draws nothing of its own: build() returns [child] unchanged.
class SessionExpiryWatcher extends ConsumerStatefulWidget {
  const SessionExpiryWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SessionExpiryWatcher> createState() =>
      _SessionExpiryWatcherState();
}

class _SessionExpiryWatcherState extends ConsumerState<SessionExpiryWatcher> {
  // AppLifecycleListener is Flutter's small helper for lifecycle changes: we
  // give it the callbacks we care about, and it calls them at the right
  // moment. (The older way is to mix WidgetsBindingObserver into the State
  // and override didChangeAppLifecycleState; this does the same with less to
  // get wrong.) It must be disposed, or it keeps listening after the widget
  // is gone.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // onResume fires on the step from inactive back to resumed, which is the
    // last step of every "came back to the app" journey.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  void _onResume() {
    // Not awaited: the callback cannot wait, and nothing here depends on the
    // result. The controller changes its state, and the screens follow.
    unawaited(ref.read(authControllerProvider.notifier).checkExpiry());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
