// The GPS part of every screen that signs a custody step (registration plan
// M5, §5; shared since Transporter handoff T4): ask for access, follow the
// readings, apply the fix policy, and say in one status what the screen
// should show.
//
// A plain class, not a provider: each screen's controller owns one and puts
// its status into its own state, so a screen still has one state to draw.
// The controller passes in how to read the source and the clock, whether it
// is still alive, and where a new status goes.
//
// Nothing here is logged: a place is evidence.

import 'dart:async';

import '../../../core/clock.dart';
import '../../registration/data/location_source.dart';
import '../../registration/domain/gps_fix.dart';

/// After this long without a usable fix, the screen suggests open sky.
const Duration stillLookingAfter = Duration(seconds: 60);

/// The longest "Starting the location…" may last (the permission dialog
/// included). After it the screen shows "could not be read" with "Try
/// again", so it can never hang for ever. A slower answer still counts if
/// it arrives later.
const Duration locationStartTimeout = Duration(seconds: 30);

sealed class LocationStatus {
  const LocationStatus();
}

final class LocationStarting extends LocationStatus {
  const LocationStarting();
}

final class LocationBlocked extends LocationStatus {
  const LocationBlocked(this.access);

  /// Never [LocationAccess.granted].
  final LocationAccess access;
}

/// Readings are coming, none usable yet. [accuracyM] is the latest one's,
/// for "Finding your location… 40 m".
final class LocationSearching extends LocationStatus {
  const LocationSearching({this.accuracyM, this.stillLooking = false});
  final double? accuracyM;
  final bool stillLooking;
}

/// The latest reading came from a fake-location app.
final class LocationMocked extends LocationStatus {
  const LocationMocked();
}

/// The stream failed for another reason; "Try again" restarts it.
final class LocationFailed extends LocationStatus {
  const LocationFailed();
}

/// A reading that passes the policy.
final class LocationFound extends LocationStatus {
  const LocationFound(this.fix);
  final GpsReading fix;
}

class LocationTracker {
  LocationTracker({
    required this._source,
    required this._clock,
    required this._isAlive,
    required this._onStatus,
    this._onSettled,
  });

  final LocationSource Function() _source;
  final Clock Function() _clock;
  final bool Function() _isAlive;
  final void Function(LocationStatus status) _onStatus;

  /// Called once the access question is settled (answered, refused, failed
  /// or timed out): from then on no location dialog can be on screen, so a
  /// camera may ask for its own permission.
  final void Function()? _onSettled;

  StreamSubscription<GpsReading>? _readings;

  /// When the current search began. "Still looking" is worked out from it on
  /// each reading (they come every second), rather than with a Timer: no
  /// timer is left running when the screen closes.
  DateTime? _searchStarted;

  /// Counts the starts, so the answer to an older one (a late permission
  /// answer, say) never overwrites a newer one.
  int _attempt = 0;

  LocationStatus _status = const LocationStarting();
  LocationStatus get status => _status;

  /// Whether [start] has run at least once.
  bool get started => _attempt > 0;

  /// Whether start is worth running again by itself (after the user came
  /// back from the settings page).
  bool get blocked => _status is LocationBlocked || _status is LocationFailed;

  void _set(LocationStatus status) {
    _status = status;
    _onStatus(status);
  }

  /// Asks for access and starts the readings: on open, and for "Allow
  /// location" and "Try again". With [ask] false (coming back from the
  /// settings page), only looks and never shows a dialog.
  ///
  /// Every outcome ends in a visible status: blocked, failed (with "Try
  /// again"), or searching. A throw, or no answer within
  /// [locationStartTimeout], is "failed".
  Future<void> start({bool ask = true}) async {
    stop();
    final attempt = ++_attempt;
    _set(const LocationStarting());

    final Future<LocationAccess> asking;
    try {
      asking = _source().ensureAccess(ask: ask);
    } on Object {
      _accessFailed(attempt);
      return;
    }
    try {
      _afterAccess(attempt, await asking.timeout(locationStartTimeout));
    } on TimeoutException {
      _accessFailed(attempt);
      // The user may simply have been slow with the dialog: a late answer
      // still counts, unless something else has started since.
      unawaited(
        asking.then(
          (access) {
            if (_isCurrent(attempt) && _status is LocationFailed) {
              _afterAccess(attempt, access);
            }
          },
          onError: (Object _) {}, // already shown as failed
        ),
      );
    } on Object {
      _accessFailed(attempt);
    }
  }

  bool _isCurrent(int attempt) => _isAlive() && attempt == _attempt;

  void _accessFailed(int attempt) {
    if (!_isCurrent(attempt)) return;
    _set(const LocationFailed());
    _onSettled?.call();
  }

  void _afterAccess(int attempt, LocationAccess access) {
    if (!_isCurrent(attempt)) return;
    if (access != LocationAccess.granted) {
      _set(LocationBlocked(access));
      _onSettled?.call();
      return;
    }
    _set(const LocationSearching());
    _onSettled?.call();
    _searchStarted = _clock()();
    try {
      _readings = _source().readings().listen(
        _onReading,
        onError: (Object error) => _onStreamError(error),
      );
    } on Object {
      stop();
      _set(const LocationFailed());
    }
  }

  void _onReading(GpsReading reading) {
    if (!_isAlive()) return;
    final now = _clock()();
    final problem = fixProblem(reading, now);
    if (problem == null) {
      // Usable: the newest usable one always replaces the last.
      _set(LocationFound(reading));
      return;
    }
    if (problem == FixProblem.mocked) {
      _set(const LocationMocked());
      return;
    }
    // Not usable. Keep a found fix while it is still fresh; once it is too
    // old, go back to searching.
    final current = _status;
    if (current is LocationFound && fixProblem(current.fix, now) == null) {
      return;
    }
    final started = _searchStarted ?? now;
    _set(
      LocationSearching(
        accuracyM: reading.hasAccuracy ? reading.accuracyM : null,
        stillLooking: now.difference(started) >= stillLookingAfter,
      ),
    );
  }

  void _onStreamError(Object error) {
    if (!_isAlive()) return;
    stop();
    final problem = error is LocationStreamError ? error.problem : null;
    _set(switch (problem) {
      LocationStreamProblem.serviceOff => const LocationBlocked(
        LocationAccess.serviceOff,
      ),
      LocationStreamProblem.permissionDenied => const LocationBlocked(
        LocationAccess.deniedOnce,
      ),
      _ => const LocationFailed(),
    });
  }

  /// The fix to sign, checked again at this moment (plan §5, fresh within
  /// 30 s). A fix that has aged since it was found is dropped: the status
  /// goes back to searching and null is returned.
  GpsReading? freshFix() {
    final current = _status;
    if (current is! LocationFound) return null;
    if (fixProblem(current.fix, _clock()()) != null) {
      _set(const LocationSearching());
      return null;
    }
    return current.fix;
  }

  /// Stops the readings; the status stays as it was.
  void stop() {
    _searchStarted = null;
    unawaited(_readings?.cancel());
    _readings = null;
  }

  Future<void> openLocationSettings() => _source().openLocationSettings();
  Future<void> openAppSettings() => _source().openAppSettings();
}
