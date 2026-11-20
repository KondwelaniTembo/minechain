// The state behind "Take custody" (transporter handoff plan, T3): scan the
// bag's custody record, refuse a second handoff of it by this account on
// this phone (Q4), ask the server what it knows (Q1, Q2), and settle the
// mineral, from the server or from the transporter's choice.
//
// T4 adds the transporter's own weight, the GPS fix and Save on
// [CustodyReady]. The GPS starts only once a code is accepted: by then the
// camera's permission question is answered, so the two dialogs can never
// be on screen together (one permission request at a time). It then keeps
// running for the next bag until the screen closes.
//
// One request per scan, as on "Check a consignment": the camera reads the
// same code many times a second, so any code that arrives after one is
// accepted is ignored until "Scan another record".
//
// Never a dead end (Q2): offline, a slow answer, a server error or an ended
// session all lead to "could not be checked, you can still record it".
//
// Nothing here is logged; the states' toString() print no QR code, place or
// weight.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/database/database_failure.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../registration/data/location_source.dart';
import '../../registration/domain/custody_record.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/presentation/location_tracker.dart';
import '../../sync/data/sync_service.dart';
import '../../sync/domain/sync_report.dart';
import '../../verification/data/consignment_check_repository.dart';
import '../data/record_handoff.dart';
import '../domain/custody_check.dart';

sealed class CustodyState {
  const CustodyState();
}

/// Why the camera is still on after a code was read.
sealed class ScanNotice {
  const ScanNotice();
}

/// Not a MineChain custody record.
final class ScanNotOurs extends ScanNotice {
  const ScanNotOurs();
}

/// This account already recorded taking custody of it on this phone, first
/// on [on] (UTC). Q4.
final class ScanAlreadyTaken extends ScanNotice {
  const ScanAlreadyTaken(this.on);
  final DateTime on;
}

/// The phone's database was busy for a moment; scanning again works.
final class ScanPhoneBusy extends ScanNotice {
  const ScanPhoneBusy();
}

/// The camera is on.
final class CustodyScanning extends CustodyState {
  const CustodyScanning([this.notice]);
  final ScanNotice? notice;

  @override
  String toString() => 'CustodyScanning(${notice.runtimeType})';
}

/// A code is accepted; the phone and the server are being asked about it.
final class CustodyChecking extends CustodyState {
  const CustodyChecking(this.qrCode);
  final String qrCode;

  @override
  String toString() => 'CustodyChecking()';
}

/// What is known about the bag; the transporter can go on, weigh it and
/// save.
final class CustodyReady extends CustodyState {
  const CustodyReady({
    required this.qrCode,
    required this.check,
    this.chosenMineral,
    this.recordAnyway = false,
    this.location = const LocationStarting(),
    this.weightText = '',
    this.saving = false,
    this.result,
    this.saveDuration,
  });

  final String qrCode;
  final CustodyCheck check;

  /// The transporter's choice from the chips, when the server did not say.
  final Mineral? chosenMineral;

  /// "Record anyway" was tapped (Q2).
  final bool recordAnyway;

  final LocationStatus location;

  /// What the transporter typed from their own scale, in [mineral]'s unit.
  final String weightText;
  final bool saving;

  /// The last save's outcome, if any.
  final SaveResult? result;

  /// How long that save took (shown in debug builds only).
  final Duration? saveDuration;

  /// The server's mineral wins: it was signed by the miner, and the chips
  /// are not shown then.
  Mineral? get mineral => check.knownMineral ?? chosenMineral;

  /// Whether the transporter must choose the mineral (Q1).
  bool get choosesMineral => check.knownMineral == null;

  List<CustodyWarning> get warnings => custodyWarnings(check);

  /// A held or mismatching consignment, not yet confirmed (Q2).
  bool get waitingForRecordAnyway =>
      !recordAnyway && warnings.any(needsRecordAnyway);

  /// The mineral is settled and no "Record anyway" is waiting: the weight
  /// and Save may be shown.
  bool get mayContinue => mineral != null && !waitingForRecordAnyway;

  /// The weight as milligrams, or why not. Null while no mineral is
  /// settled, because the unit follows the mineral (Q1).
  WeightParse? get weight =>
      mineral == null ? null : parseWeightToMg(weightText, mineral!.unit);

  /// Whether a save has been committed.
  bool get saved => result is SaveDone;

  /// Whether a tap may change the form: not while saving, nor once saved.
  bool get editable => !saving && !saved;

  /// Every condition for Save: the part above settled, a usable fix and a
  /// valid weight, and nothing already running or done.
  bool get canSave =>
      mayContinue &&
      location is LocationFound &&
      weight is WeightOk &&
      editable;

  CustodyReady copyWith({
    Mineral? chosenMineral,
    bool? recordAnyway,
    LocationStatus? location,
    String? weightText,
    bool? saving,
    SaveResult? Function()? result,
    Duration? Function()? saveDuration,
  }) => CustodyReady(
    qrCode: qrCode,
    check: check,
    chosenMineral: chosenMineral ?? this.chosenMineral,
    recordAnyway: recordAnyway ?? this.recordAnyway,
    location: location ?? this.location,
    weightText: weightText ?? this.weightText,
    saving: saving ?? this.saving,
    result: result == null ? this.result : result(),
    saveDuration: saveDuration == null ? this.saveDuration : saveDuration(),
  );

  @override
  String toString() =>
      'CustodyReady($check, mayContinue: $mayContinue, '
      'location: ${location.runtimeType}, canSave: $canSave)';
}

class CustodyController extends Notifier<CustodyState> {
  late final LocationTracker _location = LocationTracker(
    source: () => ref.read(locationSourceProvider),
    clock: () => ref.read(clockProvider),
    isAlive: () => ref.mounted,
    onStatus: (status) {
      final current = state;
      if (current is CustodyReady) state = current.copyWith(location: status);
    },
  );

  @override
  CustodyState build() {
    ref.onDispose(_location.stop);
    return const CustodyScanning();
  }

  /// A code from the camera, exactly as read.
  Future<void> onScanned(String raw) async {
    if (state is! CustodyScanning) return;
    // The custody record ID format, so a website link never reaches the
    // database or the server.
    if (!isCustodyRecordId(raw)) {
      state = const CustodyScanning(ScanNotOurs());
      return;
    }
    final user = _user();
    if (user == null) return;
    // From here on, further reads of the code are ignored.
    state = CustodyChecking(raw);

    // Q4 first, on the phone: a refused scan costs no network request.
    final DateTime? earlier;
    try {
      final steps = await ref.read(localStepsRepositoryProvider.future);
      earlier = await steps.handedOffOn(raw, user.id);
    } on Object {
      // Busy, or a database problem the screen's gate shows by itself.
      if (ref.mounted) state = const CustodyScanning(ScanPhoneBusy());
      return;
    }
    if (!ref.mounted) return;
    if (earlier != null) {
      state = CustodyScanning(ScanAlreadyTaken(earlier));
      return;
    }

    // The code is accepted, so the camera has its permission: the location
    // may now ask for its own. Started once; it keeps going for the next bag.
    if (!_location.started) unawaited(_location.start());

    final check = await _askServer(raw);
    if (!ref.mounted || state is! CustodyChecking) return;
    state = CustodyReady(qrCode: raw, check: check, location: _location.status);
  }

  Future<CustodyCheck> _askServer(String qrCode) async {
    final token = _token();
    if (token == null) {
      return const CustodyUnchecked(UncheckedReason.needsPassword);
    }
    try {
      final view = await ref
          .read(consignmentCheckRepositoryProvider)
          .check(token: token, qrCode: qrCode);
      return CustodyChecked(view);
    } on AppFailure catch (failure) {
      return switch (failure) {
        ServerRefused(status: 404, code: ApiCodes.consignmentNotFound) =>
          const CustodyNotOnServer(),
        NoConnection() => const CustodyUnchecked(UncheckedReason.offline),
        // A TOKEN_EXPIRED on this very request has already moved the
        // session to "needs password".
        _ when _token() == null => const CustodyUnchecked(
          UncheckedReason.needsPassword,
        ),
        _ => const CustodyUnchecked(UncheckedReason.failed),
      };
    }
  }

  /// A mineral chip, when the server did not say (Q1).
  void chooseMineral(Mineral mineral) {
    final current = state;
    if (current is! CustodyReady ||
        !current.choosesMineral ||
        !current.editable) {
      return;
    }
    state = current.copyWith(chosenMineral: mineral);
  }

  /// "Record anyway" under a mismatch or a hold (Q2).
  void recordAnyway() {
    final current = state;
    if (current is! CustodyReady || !current.editable) return;
    state = current.copyWith(recordAnyway: true);
  }

  void weightChanged(String text) {
    final current = state;
    if (current is! CustodyReady || !current.editable) return;
    state = current.copyWith(weightText: text, result: () => null);
  }

  /// "Scan another record", and "Take custody of another" after a save:
  /// back to the camera. Not while asking or saving. The GPS keeps running.
  void scanAgain() {
    final current = state;
    if (current is CustodyChecking) return;
    if (current is CustodyReady && current.saving) return;
    state = const CustodyScanning();
  }

  // ---- Location (the shared tracker) ---------------------------------------

  /// "Allow location" and "Try again"; with [ask] false (back from the
  /// settings page) it never shows a dialog.
  Future<void> startLocation({bool ask = true}) => _location.start(ask: ask);

  /// Whether startLocation is worth running again by itself (after the user
  /// came back from the settings page). Never before a code is accepted.
  bool get locationBlocked => _location.started && _location.blocked;

  Future<void> openLocationSettings() => _location.openLocationSettings();
  Future<void> openAppSettings() => _location.openAppSettings();

  // ---- Save -----------------------------------------------------------------

  /// Saves the signed handoff. The screen only enables Save when canSave.
  Future<void> save() async {
    final form = state;
    final user = _user();
    if (form is! CustodyReady || !form.canSave || user == null) return;
    final weight = form.weight! as WeightOk;
    final mineral = form.mineral!;

    // The fix may have aged since it was found: check again at the moment
    // of saving (fresh within 30 s). An aged one goes back to searching.
    final fix = _location.freshFix();
    if (fix == null) return;

    state = form.copyWith(saving: true, result: () => null);

    // Q4 once more, just before saving, as registration checks its
    // duplicate again: this account may have recorded this bag since the
    // scan. Nothing is signed yet.
    final DateTime? earlier;
    try {
      final steps = await ref.read(localStepsRepositoryProvider.future);
      earlier = await steps.handedOffOn(form.qrCode, user.id);
    } on Object catch (error) {
      // A busy moment says "try Save again"; any other failure is the
      // storage problem.
      _finish(
        isBusyMoment(error)
            ? const SaveBusy()
            : SaveStorageFailed(error is DatabaseFailure ? error : null),
      );
      return;
    }
    if (!ref.mounted) return;
    if (earlier != null) {
      state = CustodyScanning(ScanAlreadyTaken(earlier));
      return;
    }

    final stopwatch = Stopwatch()..start();
    final result = await ref
        .read(recordHandoffProvider)
        .save(
          user: user,
          qrCode: form.qrCode,
          mineral: mineral,
          weightMg: weight.milligrams,
          latitude: fix.latitude,
          longitude: fix.longitude,
          gpsAccuracyM: fix.accuracyM,
        );
    stopwatch.stop();
    _finish(result, stopwatch.elapsed);
    if (result is SaveDone && ref.mounted) {
      // Not awaited: "Saved on this phone" shows whatever happens, and a
      // failed send leaves the step safely queued (as registration does).
      unawaited(
        ref.read(syncServiceProvider.notifier).syncNow(SyncTrigger.afterSave),
      );
    }
  }

  void _finish(SaveResult result, [Duration? took]) {
    if (!ref.mounted) return;
    final current = state;
    if (current is! CustodyReady) return;
    state = current.copyWith(
      saving: false,
      result: () => result,
      saveDuration: () => took,
    );
  }

  /// The signed-in account: the custodian whose handoffs count for Q4, and
  /// who signs. An ended session still saves on the phone (FR-07).
  User? _user() => switch (ref.read(authControllerProvider)) {
    SignedIn(:final user) || SignedInNeedsPassword(:final user) => user,
    _ => null,
  };

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen stops the GPS and forgets the scan, the
/// answer and the form.
final custodyControllerProvider =
    NotifierProvider.autoDispose<CustodyController, CustodyState>(
      CustodyController.new,
    );
