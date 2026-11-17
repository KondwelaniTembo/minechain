// The state behind the registration screen (plan M5, §5, §6): the scanned
// code, the GPS fix as it improves, the mineral, the typed weight, and the
// save.
//
// The screen only draws this state and passes taps in. Every rule (the GPS
// policy, the QR grammar, the duplicate check, when Save is allowed) lives
// here or in the domain files, so the widget tests can drive it with fakes.
//
// Nothing here is logged: a QR code, a place and a weight are evidence.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/database/local_settings.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../data/location_source.dart';
import '../data/register_consignment.dart';
import '../domain/custody_record.dart';
import '../domain/gps_fix.dart';
import '../domain/mineral.dart';
import '../domain/weight.dart';

/// After this long without a usable fix, the screen suggests open sky.
const Duration stillLookingAfter = Duration(seconds: 60);

/// The longest "Starting the location…" may last (the permission dialog
/// included). After it the screen shows "could not be read" with "Try
/// again", so it can never hang for ever. A slower answer still counts if
/// it arrives later.
const Duration locationStartTimeout = Duration(seconds: 30);

// ---- Location ---------------------------------------------------------------

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

// ---- The scanned code -------------------------------------------------------

sealed class QrNotice {
  const QrNotice();
}

/// Not a MineChain custody record (breaks the server's grammar).
final class QrNotOurs extends QrNotice {
  const QrNotOurs();
}

/// Already registered on this phone, by any account, on [on].
final class QrAlreadyRegistered extends QrNotice {
  const QrAlreadyRegistered(this.on);
  final DateTime on;
}

// ---- The whole form ---------------------------------------------------------

class RegistrationState {
  const RegistrationState({
    this.qrCode,
    this.qrNotice,
    this.location = const LocationStarting(),
    this.mineral,
    this.weightText = '',
    this.saving = false,
    this.result,
    this.saveDuration,
    this.cameraMayStart = false,
  });

  /// False until the first location question is settled (answered, refused,
  /// failed or timed out). The camera asks for its own permission as soon
  /// as it is shown, and Android shows one permission dialog at a time, so
  /// the scanner is not shown before this.
  final bool cameraMayStart;

  /// The accepted code, exactly as scanned; null until one is accepted.
  final String? qrCode;
  final QrNotice? qrNotice;
  final LocationStatus location;
  final Mineral? mineral;
  final String weightText;
  final bool saving;

  /// The last save's outcome, if any.
  final SaveResult? result;

  /// How long that save took (shown in debug builds only).
  final Duration? saveDuration;

  /// The weight as milligrams, or why not. Null while no mineral is chosen,
  /// because the unit follows the mineral (Q2).
  WeightParse? get weight =>
      mineral == null ? null : parseWeightToMg(weightText, mineral!.unit);

  /// Every condition for Save (plan M5): a code, a usable fix, a mineral and
  /// a valid weight, and nothing already running or done.
  bool get canSave =>
      qrCode != null &&
      location is LocationFound &&
      mineral != null &&
      weight is WeightOk &&
      !saving &&
      result is! SaveDone;

  RegistrationState copyWith({
    String? Function()? qrCode,
    QrNotice? Function()? qrNotice,
    LocationStatus? location,
    Mineral? mineral,
    String? weightText,
    bool? saving,
    SaveResult? Function()? result,
    Duration? Function()? saveDuration,
    bool? cameraMayStart,
  }) => RegistrationState(
    qrCode: qrCode == null ? this.qrCode : qrCode(),
    qrNotice: qrNotice == null ? this.qrNotice : qrNotice(),
    location: location ?? this.location,
    mineral: mineral ?? this.mineral,
    weightText: weightText ?? this.weightText,
    saving: saving ?? this.saving,
    result: result == null ? this.result : result(),
    saveDuration: saveDuration == null ? this.saveDuration : saveDuration(),
    cameraMayStart: cameraMayStart ?? this.cameraMayStart,
  );

  // No code, place or weight in logs.
  @override
  String toString() =>
      'RegistrationState(hasCode: ${qrCode != null}, '
      'location: ${location.runtimeType}, canSave: $canSave)';
}

class RegistrationController extends Notifier<RegistrationState> {
  StreamSubscription<GpsReading>? _readings;

  /// When the current search began. "Still looking" is worked out from it on
  /// each reading (they come every second), rather than with a Timer: no
  /// timer is left running when the screen closes.
  DateTime? _searchStarted;

  LocationSource get _source => ref.read(locationSourceProvider);
  Clock get _now => ref.read(clockProvider);

  @override
  RegistrationState build() {
    ref.onDispose(_stopLocation);
    // After build returns: a Notifier may not change its state while it is
    // being built.
    Future.microtask(_start);
    return const RegistrationState();
  }

  Future<void> _start() async {
    if (!ref.mounted) return;
    unawaited(_loadLastMineral());
    await startLocation();
  }

  Future<void> _loadLastMineral() async {
    try {
      final settings = await ref.read(localSettingsProvider.future);
      final saved = await settings.read(SettingKeys.lastMineral);
      final mineral = saved == null ? null : Mineral.fromApiName(saved);
      // Only if the miner has not chosen one meanwhile.
      if (ref.mounted && mineral != null && state.mineral == null) {
        state = state.copyWith(mineral: mineral);
      }
    } on Object {
      // A lost preference only means nothing is preselected.
    }
  }

  // ---- Location -------------------------------------------------------------

  /// Counts the starts, so the answer to an older one (a late permission
  /// answer, say) never overwrites a newer one.
  int _attempt = 0;

  /// Asks for access and starts the readings: on open, and for "Allow
  /// location" and "Try again". With [ask] false (coming back from the
  /// settings page), only looks and never shows a dialog.
  ///
  /// Every outcome ends in a visible state: blocked, failed (with "Try
  /// again"), or searching. A throw, or no answer within
  /// [locationStartTimeout], is "failed".
  Future<void> startLocation({bool ask = true}) async {
    _stopLocation();
    final attempt = ++_attempt;
    state = state.copyWith(location: const LocationStarting());

    final Future<LocationAccess> asking;
    try {
      asking = _source.ensureAccess(ask: ask);
    } on Object {
      _accessFailed(attempt);
      return;
    }
    try {
      _afterAccess(attempt, await asking.timeout(locationStartTimeout));
    } on TimeoutException {
      _accessFailed(attempt);
      // The miner may simply have been slow with the dialog: a late answer
      // still counts, unless something else has started since.
      unawaited(
        asking.then(
          (access) {
            if (_isCurrent(attempt) && state.location is LocationFailed) {
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

  bool _isCurrent(int attempt) => ref.mounted && attempt == _attempt;

  void _accessFailed(int attempt) {
    if (!_isCurrent(attempt)) return;
    state = state.copyWith(
      location: const LocationFailed(),
      cameraMayStart: true,
    );
  }

  void _afterAccess(int attempt, LocationAccess access) {
    if (!_isCurrent(attempt)) return;
    if (access != LocationAccess.granted) {
      state = state.copyWith(
        location: LocationBlocked(access),
        cameraMayStart: true,
      );
      return;
    }
    state = state.copyWith(
      location: const LocationSearching(),
      cameraMayStart: true,
    );
    _searchStarted = _now();
    try {
      _readings = _source.readings().listen(
        _onReading,
        onError: (Object error) => _onStreamError(error),
      );
    } on Object {
      _stopLocation();
      state = state.copyWith(location: const LocationFailed());
    }
  }

  /// Whether startLocation is worth running again by itself (after the user
  /// came back from the settings page).
  bool get locationBlocked =>
      state.location is LocationBlocked || state.location is LocationFailed;

  void _onReading(GpsReading reading) {
    final now = _now();
    final problem = fixProblem(reading, now);
    if (problem == null) {
      // Usable: the newest usable one always replaces the last.
      state = state.copyWith(location: LocationFound(reading));
      return;
    }
    if (problem == FixProblem.mocked) {
      state = state.copyWith(location: const LocationMocked());
      return;
    }
    // Not usable. Keep a found fix while it is still fresh; once it is too
    // old, go back to searching.
    final current = state.location;
    if (current is LocationFound && fixProblem(current.fix, now) == null) {
      return;
    }
    final started = _searchStarted ?? now;
    state = state.copyWith(
      location: LocationSearching(
        accuracyM: reading.hasAccuracy ? reading.accuracyM : null,
        stillLooking: now.difference(started) >= stillLookingAfter,
      ),
    );
  }

  void _onStreamError(Object error) {
    _stopLocation();
    final problem = error is LocationStreamError ? error.problem : null;
    state = state.copyWith(
      location: switch (problem) {
        LocationStreamProblem.serviceOff => const LocationBlocked(
          LocationAccess.serviceOff,
        ),
        LocationStreamProblem.permissionDenied => const LocationBlocked(
          LocationAccess.deniedOnce,
        ),
        _ => const LocationFailed(),
      },
    );
  }

  void _stopLocation() {
    _searchStarted = null;
    unawaited(_readings?.cancel());
    _readings = null;
  }

  Future<void> openLocationSettings() => _source.openLocationSettings();
  Future<void> openAppSettings() => _source.openAppSettings();

  // ---- The code, the mineral, the weight -----------------------------------

  /// A code from the camera. Ignored once one is accepted, so a code held in
  /// view is not handled again and again.
  Future<void> onScanned(String raw) async {
    if (state.qrCode != null || state.result is SaveDone) return;
    // The custody record ID format, not just the server's wide grammar:
    // a website link must never fill section 1. The camera keeps scanning.
    if (!isCustodyRecordId(raw)) {
      state = state.copyWith(qrNotice: () => const QrNotOurs());
      return;
    }
    final DateTime? earlier;
    try {
      final steps = await ref.read(localStepsRepositoryProvider.future);
      earlier = await steps.registeredOn(raw);
    } on Object {
      // The database problem is shown by the screen itself; nothing to add.
      return;
    }
    if (!ref.mounted || state.qrCode != null) return;
    state = earlier != null
        ? state.copyWith(qrNotice: () => QrAlreadyRegistered(earlier!))
        : state.copyWith(qrCode: () => raw, qrNotice: () => null);
  }

  /// "Scan another record": forget the accepted code.
  void scanAgain() {
    if (state.saving) return;
    state = state.copyWith(qrCode: () => null, qrNotice: () => null);
  }

  void chooseMineral(Mineral mineral) {
    if (state.saving || state.result is SaveDone) return;
    state = state.copyWith(mineral: mineral);
  }

  void weightChanged(String text) {
    if (state.saving || state.result is SaveDone) return;
    state = state.copyWith(weightText: text, result: () => null);
  }

  // ---- Save -----------------------------------------------------------------

  /// Saves the registration. The screen only enables Save when [canSave].
  Future<void> save() async {
    final form = state;
    final user = switch (ref.read(authControllerProvider)) {
      SignedIn(:final user) || SignedInNeedsPassword(:final user) => user,
      _ => null,
    };
    if (!form.canSave || user == null) return;
    final location = form.location as LocationFound;
    final weight = form.weight! as WeightOk;

    // The fix may have aged since it was found: check again at the moment
    // of saving (plan §5, fresh within 30 s).
    if (fixProblem(location.fix, _now()) != null) {
      state = form.copyWith(location: const LocationSearching());
      return;
    }

    state = form.copyWith(saving: true, result: () => null);

    // The duplicate check once more, just before saving: another account
    // may have registered this record on this phone since the scan.
    final steps = await _stepsOrNull();
    final earlier = await steps?.registeredOn(form.qrCode!);
    if (!ref.mounted) return;
    if (earlier != null) {
      state = state.copyWith(
        saving: false,
        qrCode: () => null,
        qrNotice: () => QrAlreadyRegistered(earlier),
      );
      return;
    }

    final stopwatch = Stopwatch()..start();
    final result = await ref
        .read(registerConsignmentProvider)
        .save(
          user: user,
          qrCode: form.qrCode!,
          mineral: form.mineral!,
          weightMg: weight.milligrams,
          latitude: location.fix.latitude,
          longitude: location.fix.longitude,
          gpsAccuracyM: location.fix.accuracyM,
        );
    stopwatch.stop();
    if (!ref.mounted) return;

    state = state.copyWith(
      saving: false,
      result: () => result,
      saveDuration: () => stopwatch.elapsed,
    );
    if (result is SaveDone) {
      // Remembered for the next registration (Q5).
      unawaited(_rememberMineral(form.mineral!));
    }
  }

  /// "Register another": a fresh form, keeping the mineral and the GPS.
  void registerAnother() {
    state = RegistrationState(
      location: state.location,
      mineral: state.mineral,
      cameraMayStart: true,
    );
  }

  Future<LocalStepsRepository?> _stepsOrNull() async {
    try {
      return await ref.read(localStepsRepositoryProvider.future);
    } on Object {
      return null; // save() reports the database failure itself
    }
  }

  Future<void> _rememberMineral(Mineral mineral) async {
    try {
      final settings = await ref.read(localSettingsProvider.future);
      await settings.write(SettingKeys.lastMineral, mineral.name);
    } on Object {
      // A convenience only.
    }
  }
}

/// autoDispose: leaving the screen stops the GPS and forgets the form.
final registrationControllerProvider =
    NotifierProvider.autoDispose<RegistrationController, RegistrationState>(
      RegistrationController.new,
    );
