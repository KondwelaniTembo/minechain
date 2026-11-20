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
import '../../../core/database/database_failure.dart';
import '../../../core/database/local_settings.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/presentation/location_tracker.dart';
import '../../sync/data/sync_service.dart';
import '../../sync/domain/sync_report.dart';
import '../data/location_source.dart';
import '../data/register_consignment.dart';
import '../domain/custody_record.dart';
import '../domain/mineral.dart';
import '../domain/weight.dart';

// The location statuses and the timings are shared with "Take custody"
// (Transporter handoff T4); exported so this file's users see them as before.
export '../../steps/presentation/location_tracker.dart'
    show
        LocationStatus,
        LocationStarting,
        LocationBlocked,
        LocationSearching,
        LocationMocked,
        LocationFailed,
        LocationFound,
        stillLookingAfter,
        locationStartTimeout;

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
  late final LocationTracker _location = LocationTracker(
    source: () => ref.read(locationSourceProvider),
    clock: () => ref.read(clockProvider),
    isAlive: () => ref.mounted,
    onStatus: (status) => state = state.copyWith(location: status),
    // The camera asks for its own permission as soon as it is shown, and
    // Android shows one permission dialog at a time.
    onSettled: () => state = state.copyWith(cameraMayStart: true),
  );

  /// Saves since the screen opened, for "2 saved this time." (T5b). Not in
  /// the state: "Register another" starts a fresh state. autoDispose resets
  /// it when the screen is left.
  int get savesThisVisit => _savesThisVisit;
  int _savesThisVisit = 0;

  @override
  RegistrationState build() {
    ref.onDispose(_location.stop);
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

  // ---- Location (the shared tracker) ---------------------------------------

  /// On open, and for "Allow location" and "Try again"; with [ask] false
  /// (back from the settings page) it never shows a dialog.
  Future<void> startLocation({bool ask = true}) => _location.start(ask: ask);

  /// Whether startLocation is worth running again by itself (after the user
  /// came back from the settings page).
  bool get locationBlocked => _location.blocked;

  Future<void> openLocationSettings() => _location.openLocationSettings();
  Future<void> openAppSettings() => _location.openAppSettings();

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
    final weight = form.weight! as WeightOk;

    // The fix may have aged since it was found: check again at the moment
    // of saving (plan §5, fresh within 30 s). An aged one goes back to
    // searching.
    final fix = _location.freshFix();
    if (fix == null) return;

    state = form.copyWith(saving: true, result: () => null);

    // The duplicate check once more, just before saving: another account
    // may have registered this record on this phone since the scan.
    final steps = await _stepsOrNull();
    final DateTime? earlier;
    try {
      earlier = await steps?.registeredOn(form.qrCode!);
    } on Object catch (error) {
      // Before, this escaped save() and left the screen saving. Nothing is
      // signed or stored yet. A busy moment says "try Save again"; any
      // other failure is the storage problem.
      if (!ref.mounted) return;
      state = state.copyWith(
        saving: false,
        result: () => isBusyMoment(error)
            ? const SaveBusy()
            : SaveStorageFailed(error is DatabaseFailure ? error : null),
      );
      return;
    }
    if (!ref.mounted) return;
    if (earlier case final DateTime first) {
      state = state.copyWith(
        saving: false,
        qrCode: () => null,
        qrNotice: () => QrAlreadyRegistered(first),
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
          latitude: fix.latitude,
          longitude: fix.longitude,
          gpsAccuracyM: fix.accuracyM,
        );
    stopwatch.stop();
    if (!ref.mounted) return;

    if (result is SaveDone) _savesThisVisit++;
    state = state.copyWith(
      saving: false,
      result: () => result,
      saveDuration: () => stopwatch.elapsed,
    );
    if (result is SaveDone) {
      // Not awaited: the miner sees "Saved on this phone" whatever happens,
      // and a failed send leaves the step safely queued.
      unawaited(_afterSave(form.mineral!));
    }
  }

  /// After a committed save: remember the mineral (Q5), THEN send (M6,
  /// approved point 7). One after the other, not side by side: started
  /// together, the two opened the database at the same moment on the API
  /// 26 emulator, and the send met the other's lock. The database now also
  /// queues its calls (local_database.dart); this keeps the order plain.
  Future<void> _afterSave(Mineral mineral) async {
    // The sync service lives on after this screen; read it before any await,
    // while this controller's ref is certainly usable.
    final sync = ref.read(syncServiceProvider.notifier);
    await _rememberMineral(mineral);
    await sync.syncNow(SyncTrigger.afterSave);
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
