// Where GPS readings come from, behind a small interface so widget tests can
// put a fake in its place and the geolocator plugin never loads there.
//
// The real one uses geolocator 14.1.2. What its README and sources say, and
// this file relies on:
// - check `isLocationServiceEnabled()` first; then `checkPermission()`, and
//   `requestPermission()` if denied;
// - "Android can only return whileInUse, always or denied when checking
//   permissions ... the geolocator is only able to [tell deniedForever] as a
//   result of the requestPermission method";
// - since Android 12 the user may grant only the approximate location, which
//   `getLocationAccuracy()` reports as `LocationAccuracyStatus.reduced`;
// - `Position.isMocked` is true "when the location came from the mocked
//   provider", and `hasAccuracy` false means accuracy is a placeholder.
//
// Foreground only: the stream runs while the registration screen is open,
// and is cancelled when it closes. No background permission is asked for.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// geolocator re-exports AndroidSettings, so geolocator_android is not
// imported (or listed in pubspec) separately.
import 'package:geolocator/geolocator.dart';

import '../domain/gps_fix.dart';

/// What stands between the app and a reading.
enum LocationAccess {
  granted,

  /// Location is switched off in the phone's settings.
  serviceOff,

  /// Refused this time; asking again shows the dialog again.
  deniedOnce,

  /// Refused for good: only the app's settings page can change it.
  deniedForever,

  /// Only the approximate location was allowed (Android 12+), which can
  /// never reach 25 m.
  approximateOnly,
}

/// The location stream failed after it started.
enum LocationStreamProblem { serviceOff, permissionDenied, failed }

final class LocationStreamError implements Exception {
  const LocationStreamError(this.problem);
  final LocationStreamProblem problem;

  @override
  String toString() => 'LocationStreamError(${problem.name})';
}

abstract interface class LocationSource {
  /// Checks the service and the permission. With [ask], also shows Android's
  /// permission dialog when the permission is not granted yet; without it,
  /// only looks (used when the app comes back to the front, so that closing
  /// one dialog never opens another).
  ///
  /// May throw if the plugin fails, and may never finish (see the
  /// controller's timeout): callers must handle both.
  Future<LocationAccess> ensureAccess({bool ask = true});

  /// Readings as they come, best accuracy first. Errors arrive as
  /// [LocationStreamError]. Cancel the subscription to stop the GPS.
  Stream<GpsReading> readings();

  Future<void> openLocationSettings();
  Future<void> openAppSettings();
}

class GeolocatorLocationSource implements LocationSource {
  // Plugin faults are not caught here: calling one "refused" would offer
  // "Allow location", which cannot help. The controller shows them as
  // "could not be read" with "Try again".
  //
  // Why requestPermission can hang: Android allows one permission request
  // at a time, and answers a second one with empty arrays ("you will
  // receive empty permissions and results arrays which should be treated as
  // a cancellation", Activity.onRequestPermissionsResult). geolocator_android
  // 5.2.1 (PermissionManager.java, onRequestPermissionsResult) then only
  // logs "The grantResults array is empty" and returns false, without
  // answering Dart, so the Future never completes. The screen therefore
  // never asks while the camera may be asking.
  @override
  Future<LocationAccess> ensureAccess({bool ask = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && ask) {
      permission = await Geolocator.requestPermission();
    }
    switch (permission) {
      case LocationPermission.deniedForever:
        return LocationAccess.deniedForever;
      case LocationPermission.denied || LocationPermission.unableToDetermine:
        return LocationAccess.deniedOnce;
      case LocationPermission.whileInUse || LocationPermission.always:
        break;
    }
    final precision = await Geolocator.getLocationAccuracy();
    return precision == LocationAccuracyStatus.reduced
        ? LocationAccess.approximateOnly
        : LocationAccess.granted;
  }

  @override
  Stream<GpsReading> readings() {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      // Every reading, even standing still: accuracy improves over time.
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
      // No cached "historical" position at the start: only new fixes.
      maxUpdateAge: Duration.zero,
    );
    return Geolocator.getPositionStream(locationSettings: settings)
        .map(
          (p) => GpsReading(
            latitude: p.latitude,
            longitude: p.longitude,
            accuracyM: p.accuracy,
            hasAccuracy: p.hasAccuracy,
            isMocked: p.isMocked,
            timestamp: p.timestamp.toUtc(),
          ),
        )
        .handleError((Object error) {
          throw LocationStreamError(switch (error) {
            LocationServiceDisabledException() =>
              LocationStreamProblem.serviceOff,
            PermissionDeniedException() =>
              LocationStreamProblem.permissionDenied,
            _ => LocationStreamProblem.failed,
          });
        });
  }

  @override
  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  @override
  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }
}

final locationSourceProvider = Provider<LocationSource>(
  (ref) => GeolocatorLocationSource(),
);
